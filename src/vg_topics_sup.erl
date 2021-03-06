%%%-------------------------------------------------------------------
%% @doc vonnegut topics supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(vg_topics_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_child/1,
         start_child/2,
         start_child/3,
         start_child/4,
         list_topics/1,
         stop_child/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_child(Topic) ->
    start_child(Topic, [0]).

start_child(Topic, Partitions) ->
    start_child(local, Topic, Partitions).

start_child(Server0, Topic, Partitions) ->
    %% since it's crucial to start remote children, block for a while
    start_child(Server0, Topic, Partitions, 300).

start_child(_, _, _, 0) ->
    {error, remote_node_down};
start_child(Server0, Topic, Partitions, Retries) ->
    Server = case Server0 of
                 local -> ?SERVER;
                 _ -> {?SERVER, Server0}
             end,
    lager:info("at=create_topic node=~p topic=~p partitions=~p target=~p",
               [node(), Topic, Partitions, Server0]),
    prometheus_gauge:inc(active_topics),
    try
        case supervisor:start_child(Server, [Topic, Partitions]) of
            {ok, Pid} ->
                {ok, Pid};
            {error, {already_started, Pid}} ->
                {ok, Pid};
            {error, {shutdown, {failed_to_start_child, _, Reason}}} ->
                {error, Reason}
        end
    catch _C:_E->
            lager:info("~p : ~p", [_C,_E]),
            timer:sleep(100),
            start_child(Server0, Topic, Partitions, Retries - 1)
    end.

stop_child(Server, Topic, Partitions) ->
    %% get a list of topic_sup supervisors
    Topics = supervisor:which_children({?MODULE, Server}),
    Topics1 = [{Pid, supervisor:which_children(Pid)}
               || {_, Pid, _, _} <- Topics],
    Res =
        [[case Topic =:= Top andalso lists:member(Part, Partitions) of
              true ->
                  supervisor:terminate_child({?MODULE, Server}, Pid);
              _ ->
                  ok
          end
          || {{active, Top, Part}, _, _, _} <- Children]
         || {Pid, Children} <- Topics1],
    lists:usort(lists:flatten(Res)).

list_topics(Server0) ->
    Server = case Server0 of
                 local -> ?SERVER;
                 _ -> {?SERVER, Server0}
             end,
    Topics = supervisor:which_children(Server),
    [{Topic, Partition} || {{active, Topic, Partition}, _, _, _} <-
               lists:flatten([supervisor:which_children(Pid)
                              || {_, Pid, _, _} <- Topics])].

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                intensity => 0,
                period => 1},
    ChildSpecs = [#{id => vg_topic_sup,
                    start => {vg_topic_sup, start_link, []},
                    restart => permanent,
                    type => supervisor,
                    shutdown => 5000}],
    {ok, {SupFlags, ChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================

