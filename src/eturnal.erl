%%% eturnal STUN/TURN server.
%%%
%%% Copyright (c) 2020 Holger Weiss <holger@zedat.fu-berlin.de>.
%%% Copyright (c) 2020 ProcessOne, SARL.
%%% All rights reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.

-module(eturnal).
-behaviour(gen_server).
-export([start_link/0,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         get_password/2]).

-include_lib("kernel/include/logger.hrl").
-define(PEM_FILE_NAME, "cert.pem").

-record(eturnal_state,
        {listeners :: [listener()]}).

-type config_changes() :: {[{atom(), term()}], [{atom(), term()}], [atom()]}.
-type transport() :: udp | tcp | tls.
-type port_num() :: 0..65535.
-type listener() :: {port_num(), transport()}.
-type state() :: #eturnal_state{}.

%% API.

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init(any()) -> {ok, state(), hibernate} | no_return().
init(_Opts) ->
    process_flag(trap_exit, true),
    case ensure_run_dir() of
        ok ->
            ok;
        error -> % Has been logged.
            abort()
    end,
    case {turn_enabled(), got_relay_addr()} of
        {true, true} ->
            ?LOG_DEBUG("Relay configuration seems fine");
        {false, _} ->
            ?LOG_DEBUG("TURN not enabled, ignoring relay configuration");
        {true, false} ->
            ?LOG_CRITICAL("Please specify your external 'relay_ipv4_addr'"),
            abort()
    end,
    case tls_enabled() of
        true ->
            case update_pem_file() of
                Result when Result =:= ok;
                            Result =:= unmodified ->
                    ?LOG_DEBUG("Certificate configuration seems fine");
                error -> % Has been logged.
                    abort()
            end;
        false ->
            ?LOG_DEBUG("TLS not enabled, ignoring certificate configuration")
    end,
    case start_listeners() of
        {ok, Listeners} ->
            ?LOG_DEBUG("Started up ~B listeners", [length(Listeners)]),
            {ok, #eturnal_state{listeners = Listeners}, hibernate};
        {error, Reason} ->
            ?LOG_DEBUG("Failed to start up listeners: ~p", [Reason]),
            abort()
    end.

-spec handle_call(reload | get_loglevel |
                  {set_loglevel, eturnal_logger:level()} | term(),
                  {pid(), term()}, state())
      -> {reply, ok | {ok, term()} | {error, term()}, state(), hibernate}.
handle_call(reload, _From, State) ->
    case conf:reload_file() of
        ok ->
            ?LOG_DEBUG("Reloaded configuration"),
            {reply, ok, State, hibernate};
        {error, Reason} ->
            ?LOG_ERROR("Cannot reload configuration: ~s",
                       [conf:format_error(Reason)]),
            {reply, {error, Reason}, State, hibernate}
    end;
handle_call(get_loglevel, _From, State) ->
    Level = eturnal_logger:get_level(),
    {reply, {ok, Level}, State, hibernate};
handle_call({set_loglevel, Level}, _From, State)
  when Level =:= critical;
       Level =:= error;
       Level =:= warning;
       Level =:= notice;
       Level =:= info;
       Level =:= debug ->
    ok = eturnal_logger:set_level(Level),
    {reply, ok, State, hibernate};
handle_call(Request, From, State) ->
    ?LOG_ERROR("Got unexpected request from ~p: ~p", [From, Request]),
    {reply, {error, badarg}, State, hibernate}.

-spec handle_cast({config_change, config_changes()} | term(), state())
      -> {noreply, state(), hibernate} | no_return().
handle_cast({config_change, Changes}, State) ->
    State1 = apply_config_changes(State, Changes),
    {noreply, State1, hibernate};
handle_cast(Msg, State) ->
    ?LOG_ERROR("Got unexpected message: ~p", [Msg]),
    {noreply, State, hibernate}.

-spec handle_info(term(), state()) -> {noreply, state(), hibernate}.
handle_info(Info, State) ->
    ?LOG_ERROR("Got unexpected info: ~p", [Info]),
    {noreply, State, hibernate}.

-spec terminate(normal | shutdown | {shutdown, term()} | term(), state()) -> ok.
terminate(Reason, State) ->
    ?LOG_DEBUG("Terminating eturnd (~p)", [Reason]),
    _ = stop_listeners(State),
    _ = clean_run_dir(),
    ok.

-spec code_change({down, term()} | term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    ?LOG_INFO("Got code change request"),
    {ok, State}.

-spec get_password(binary(), binary()) -> binary().
get_password(Username, _Realm) ->
    [Expiration | _Suffix] = binary:split(Username, <<$:>>),
    try binary_to_integer(Expiration) of
        ExpireTime ->
            case erlang:system_time(second) of
                Now when Now < ExpireTime ->
                    ?LOG_DEBUG("Looking up password for: ~ts", [Username]),
                    {ok, Secret} = application:get_env(eturnal, secret),
                    derive_password(Username, Secret);
                Now when Now >= ExpireTime ->
                    ?LOG_INFO("Credentials expired: ~ts", [Username]),
                    <<>>
            end
    catch _:badarg ->
            ?LOG_INFO("Non-numeric expiration field: ~ts", [Username]),
            <<>>
    end.

%% Internal functions.

-spec start_listeners() -> {ok, [listener()]} | {error, term()}.
start_listeners() ->
    Opts = lists:filtermap(
             fun({InKey, OutKey}) ->
                     {ok, Val} = application:get_env(InKey),
                     opt_filter({OutKey, Val})
             end, opt_map()) ++ [{auth_fun, fun ?MODULE:get_password/2}],
    {ok, Listen} = application:get_env(listen),
    ?LOG_DEBUG("Got listen option:~n~p", [Listen]),
    try lists:map(
          fun({IP, Port, Transport, EnableTURN}) ->
                  Opts1 = [{use_turn, EnableTURN} | Opts],
                  Opts2 = case Transport of
                              tls ->
                                  [{tls, true},
                                   {certfile, get_pem_file_path()} | Opts1];
                              _ ->
                                  Opts1
                          end,
                  ?LOG_DEBUG("Starting listener ~s:~B (~s) with options:~n~p",
                             [inet:ntoa(IP), Port, Transport, Opts2]),
                  case stun_listener:add_listener(IP, Port, Transport, Opts2) of
                      ok ->
                          Type = case EnableTURN of
                                     true ->
                                         <<"STUN/TURN">>;
                                     false ->
                                         <<"STUN only">>
                                 end,
                          ?LOG_INFO("Listening on ~s:~B (~s) (~s)",
                                    [inet:ntoa(IP), Port, Transport, Type]);
                      {error, Reason} = Err ->
                          ?LOG_ERROR("Cannot listen on ~s:~B (~s): ~p",
                                     [inet:ntoa(IP), Port, Transport, Reason]),
                          throw(Err)
                  end,
                  {IP, Port, Transport}
          end, Listen) of
        Listeners ->
            {ok, Listeners}
    catch throw:{error, Reason} ->
            {error, Reason}
    end.

-spec stop_listeners(state()) -> ok | {error, term()}.
stop_listeners(#eturnal_state{listeners = Listeners}) ->
    try lists:foreach(
          fun({IP, Port, Transport}) ->
                  case stun_listener:del_listener(IP, Port, Transport) of
                      ok ->
                          ?LOG_INFO("Stopped listening on ~s:~B (~s)",
                                    [inet:ntoa(IP), Port, Transport]);
                      {error, Reason} = Err ->
                          ?LOG_ERROR("Cannot stop listening on ~s:~B (~s): ~p",
                                     [inet:ntoa(IP), Port, Transport, Reason]),
                      throw(Err)
                  end
          end, Listeners)
    catch throw:{error, Reason} ->
            {error, Reason}
    end.

-spec tls_enabled() -> boolean().
tls_enabled() ->
    {ok, Listeners} = application:get_env(listen),
    lists:any(fun({_IP, _Port, Transport, _EnableTURN}) ->
                      Transport =:= tls
              end, Listeners).

-spec turn_enabled() -> boolean().
turn_enabled() ->
    {ok, Listeners} = application:get_env(listen),
    lists:any(fun({_IP, _Port, _Transport, EnableTURN}) ->
                      EnableTURN =:= true
              end, Listeners).

-spec got_relay_addr() -> boolean().
got_relay_addr() ->
    case application:get_env(relay_ipv4_addr) of
        {ok, undefined} ->
            false;
        {ok, {127, _, _, _}} ->
            false;
        {ok, {0, 0, 0, 0}} ->
            false;
        {ok, {_, _, _, _}} ->
            true
    end.

-spec logging_config_changed(config_changes()) -> boolean().
logging_config_changed({Changed, New, Removed}) ->
    ModifiedKeys = proplists:get_keys(Changed ++ New ++ Removed),
    LoggingKeys = [log_dir,
                   log_level,
                   log_rotate_size,
                   log_rotate_count],
    lists:any(fun(Key) -> lists:member(Key, ModifiedKeys) end, LoggingKeys).

-spec listener_config_changed(config_changes()) -> boolean().
listener_config_changed({Changed, New, Removed}) ->
    ModifiedKeys = proplists:get_keys(Changed ++ New ++ Removed),
    ListenerKeys = [listen,
                    relay_ipv4_addr,
                    relay_ipv6_addr,
                    relay_min_port,
                    relay_max_port,
                    max_allocations,
                    max_permissions,
                    max_bps,
                    blacklist,
                    realm,
                    software_name],
    lists:any(fun(Key) -> lists:member(Key, ModifiedKeys) end, ListenerKeys).

-spec apply_config_changes(state(), config_changes()) -> state() | no_return().
apply_config_changes(State, {Changed, New, Removed} = ConfigChanges) ->
    if length(Changed) > 0 ->
            ?LOG_DEBUG("Changed options: ~p", [Changed]);
       length(Changed) =:= 0 ->
            ?LOG_DEBUG("No changed options")
    end,
    if length(Removed) > 0 ->
            ?LOG_DEBUG("Removed options: ~p", [Removed]);
       length(Removed) =:= 0 ->
            ?LOG_DEBUG("No removed options")
    end,
    if length(New) > 0 ->
            ?LOG_DEBUG("New options: ~p", [New]);
       length(New) =:= 0 ->
            ?LOG_DEBUG("No new options")
    end,
    case logging_config_changed(ConfigChanges) of
        true ->
            ok = eturnal_logger:reconfigure(),
            ?LOG_INFO("Applied new logging configuration settings");
        false ->
            ?LOG_DEBUG("Logging configuration unchanged")
    end,
    case tls_enabled() of
        true ->
            case update_pem_file() of
                ok ->
                    ok = fast_tls:clear_cache(),
                    ?LOG_INFO("Using new TLS certificate");
                unmodified ->
                    ?LOG_DEBUG("TLS certificate unchanged");
                error -> % Has been logged.
                    abort()
            end;
        false ->
            ?LOG_DEBUG("TLS not enabled, ignoring certificate configuration")
    end,
    case listener_config_changed(ConfigChanges) of
        true ->
            case {stop_listeners(State), start_listeners()} of
                {ok, {ok, Listeners}} ->
                    ?LOG_INFO("Applied new listen configuration settings"),
                    State#eturnal_state{listeners = Listeners};
                {_, _} -> % Error has been logged.
                    abort()
            end;
        false ->
            ?LOG_DEBUG("Listen configuration unchanged"),
            State
    end.

-spec get_pem_file_path() -> file:filename_all().
get_pem_file_path() ->
    {ok, RunDir} = application:get_env(run_dir),
    filename:join(RunDir, <<?PEM_FILE_NAME>>).

-spec update_pem_file() -> ok | unmodified | error.
update_pem_file() ->
    {ok, Opt} = application:get_env(tls_crt_file),
    OutFile = get_pem_file_path(),
    case {Opt, filelib:last_modified(OutFile)} of
        {none, OutTime} when OutTime =/= 0 ->
            ?LOG_DEBUG("Using existing PEM file (~s)", [OutFile]),
            unmodified;
        {none, OutTime} when OutTime =:= 0 ->
            ?LOG_WARNING("TLS enabled without 'tls_crt_file', creating "
                         "self-signed certificate"),
            create_self_signed(OutFile);
        {CrtFile, OutTime} ->
            case filelib:last_modified(CrtFile) of
                CrtTime when CrtTime =< OutTime ->
                    ?LOG_DEBUG("Using existing PEM file (~s)", [OutFile]),
                    unmodified;
                CrtTime when CrtTime =/= 0 -> % Assert to be true.
                    ?LOG_DEBUG("Updating PEM file (~s)", [OutFile]),
                    import_cert(CrtFile, OutFile)
            end
    end.

-spec import_cert(binary(), file:filename_all()) -> ok | error.
import_cert(CrtFile, OutFile) ->
    try
        Read = [read, binary, raw],
        Write = [write, binary, raw],
        Append = [append, binary, raw],
        {ok, Fd} = file:open(OutFile, Write),
        ok = file:close(Fd),
        ok = file:change_mode(OutFile, 8#00600),
        {ok, KeyFile} = application:get_env(tls_key_file),
        if is_binary(KeyFile) ->
                {ok, _} = file:copy({KeyFile, Read}, {OutFile, Write}),
                ?LOG_DEBUG("Copied ~s into ~s", [KeyFile, OutFile]);
           KeyFile =:= undefined ->
                ?LOG_INFO("No 'tls_key_file' specified, assuming key in ~s",
                          [CrtFile])
        end,
        {ok, _} = file:copy({CrtFile, Read}, {OutFile, Append}),
        ?LOG_DEBUG("Copied ~s into ~s", [CrtFile, OutFile]),
        ok
    catch
        error:{badarg, {error, Reason}} ->
            ?LOG_CRITICAL("Cannot create ~s: ~s",
                          [OutFile, file:format_error(Reason)]),
            error
    end.

-spec create_self_signed(file:filename_all()) -> ok | error.
create_self_signed(OutFile) ->
    Cmd = io_lib:format("openssl req -x509 -batch -nodes -newkey rsa:4096 "
                        "-keyout ~s -subj /CN=eturnal.net -days 3650",
                        [OutFile]),
    Output = os:cmd(Cmd),
    case string:find(Output, "-----BEGIN CERTIFICATE-----") of
        Cert when is_list(Cert) ->
            case file:write_file(OutFile, Cert, [append, raw]) of
                ok ->
                    ?LOG_DEBUG("Created PEM file: ~s", [OutFile]),
                    ok;
                {error, Reason} ->
                    ?LOG_CRITICAL("Cannot store PEM file ~s: ~s",
                                  [OutFile, file:format_error(Reason)]),
                    error
            end;
        nomatch ->
            Err = string:trim(Output),
            Txt = if length(Err) > 0 ->
                          Err;
                     length(Err) =:= 0 ->
                          "openssl req -x509 [...] failed"
                  end,
            ?LOG_CRITICAL("Cannot create ~s: ~s", [OutFile, Txt]),
            error
    end.

-spec ensure_run_dir() -> ok | error.
ensure_run_dir() ->
    {ok, RunDir} = application:get_env(run_dir),
    case filelib:ensure_dir(filename:join(RunDir, <<"state.dat">>)) of
        ok ->
            ?LOG_DEBUG("Using run directory ~s", [RunDir]),
            ok;
        {error, Reason} ->
            ?LOG_CRITICAL("Cannot create run directory ~s: ~s",
                          [RunDir, file:format_error(Reason)]),
            error
    end.

-spec clean_run_dir() -> ok | {error, term()}.
clean_run_dir() ->
    PEMFile = get_pem_file_path(),
    case filelib:is_regular(PEMFile) of
        true ->
            case file:delete(PEMFile) of
                ok ->
                    ?LOG_DEBUG("Removed ~s", [PEMFile]),
                    ok;
                {error, Reason} = Err ->
                    ?LOG_WARNING("Cannot remove ~s: ~s",
                                 [PEMFile, file:format_error(Reason)]),
                    Err
            end;
        false ->
            ?LOG_DEBUG("PEM file doesn't exist: ~s", [PEMFile])
    end.

-spec derive_password(binary(), binary()) -> binary().
derive_password(Username, Secret) ->
    base64:encode(crypto:mac(hmac, sha, Secret, Username)).

-spec opt_map() -> [{atom(), atom()}].
opt_map() ->
    [{relay_ipv4_addr, turn_ipv4_address},
     {relay_ipv6_addr, turn_ipv6_address},
     {relay_min_port, turn_min_port},
     {relay_max_port, turn_max_port},
     {max_allocations, turn_max_allocations},
     {max_permissions, turn_max_permissions},
     {max_bps, shaper},
     {blacklist, turn_blacklist},
     {realm, auth_realm},
     {software_name, server_name}].

-spec opt_filter(Opt) -> {true, Opt} | false when Opt :: {atom(), term()}.
opt_filter({relay_ipv6_addr, undefined}) ->
    false; % The 'stun' application currently wouldn't accept 'undefined'.
opt_filter(Opt) ->
    {true, Opt}.

-spec abort() -> no_return().
abort() ->
    ?LOG_CRITICAL("Aborting eturnal STUN/TURN server"),
    eturnal_logger:flush(),
    halt(1).
