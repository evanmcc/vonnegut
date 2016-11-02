-module(vg_socket).

-behaviour(gen_server).

%% public api

-export([start_link/0]).

%% gen_server api

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

%% public api

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server api

init([]) ->
    Port = application:get_env(vonnegut, port, 5555),
    % Trapping exit so can close socket in terminate/2
    _ = process_flag(trap_exit, true),
    Opts = [{active, once}, {reuseaddr, true}, {buffer, 65535}, {nodelay, true}, {mode, binary}, {packet, 4}],
    case gen_tcp:listen(Port, Opts) of
        {ok, Socket} ->
            % acceptor could close the socket if there is a problem
            MRef = monitor(port, Socket),
            vg_pool:accept_socket(Socket, 1),
            {ok, {Socket, MRef}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(Req, _, State) ->
    {stop, {bad_call, Req}, State}.

handle_cast(Req, State) ->
    {stop, {bad_cast, Req}, State}.

handle_info({'DOWN', MRef, port, Socket, Reason}, {Socket, MRef} = State) ->
    {stop, Reason, State};
handle_info(_, State) ->
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, {Socket, MRef}) ->
    % Socket may already be down but need to ensure it is closed to avoid
    % eaddrinuse error on restart
    case demonitor(MRef, [flush, info]) of
        true  -> gen_tcp:close(Socket);
        false -> ok
    end.
