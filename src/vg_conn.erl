-module(vg_conn).

-behaviour(acceptor).
-behaviour(gen_server).

%% acceptor api

-export([acceptor_init/3,
         acceptor_continue/3,
         acceptor_terminate/2]).

%% gen_server api

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-include("vg.hrl").

-type topic_partition() :: {binary(), [partition()]}.
-type partition() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}.
-type limited_partition() :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}.

-record(state, {socket :: inets:socket(),
                role   :: head | tail | undefined, %% middle disconnects
                ref    :: reference(),
                buffer :: binary()}).

acceptor_init(_SockName, LSocket, [Role]) ->
    MRef = monitor(port, LSocket),
    {ok, {MRef, Role}}.

acceptor_continue(_PeerName, Socket, {MRef, Role}) ->
    lager:debug("new connection on ~p", [Socket]),
    prometheus_gauge:inc(open_connections),
    lager:debug("at=new_connection node=~p peer=~p role=~p",
                [node(), _PeerName, Role]),
    gen_server:enter_loop(?MODULE, [], #state{socket = Socket, ref = MRef,
                                              role = Role, buffer = <<>>}).

acceptor_terminate(Reason, _) ->
    % Something went wrong. Either the acceptor_pool is terminating or the
    % accept failed.
    prometheus_gauge:dec(open_connections),
    exit(Reason).

%% gen_server api

init(_) ->
    {stop, acceptor}.

handle_call(Req, _, State) ->
    {stop, {bad_call, Req}, State}.

handle_cast(Req, State) ->
    {stop, {bad_cast, Req}, State}.

handle_info({tcp, _Socket, _Data}, State=#state{role=undefined}) ->
    lager:info("request received while role undefined"),
    {stop, undefined_role, State};
handle_info({tcp, Socket, Data}, State=#state{socket=Socket,
                                              role=Role,
                                              buffer=Buffer}) ->
    case handle_data(<<Buffer/binary, Data/binary>>, Role, Socket) of
        {ok, NewBuffer} ->
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State#state{buffer=NewBuffer}};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_info({tcp_error, Socket, Reason}, State=#state{socket=Socket}) ->
    {stop, Reason, State};
handle_info({tcp_closed, Socket}, State=#state{socket=Socket}) ->
    {stop, normal, State};
handle_info({'DOWN', MRef, port, _, _}, State=#state{socket=Socket,
                                                     ref=MRef}) ->
    %% Listen socket closed, receive all pending data then stop. In more
    %% advanced protocols will likely be able to do better.
    lager:info("Gracefully closing ~p~n", [Socket]),
    {stop, flush_socket(Socket), State};
handle_info(_, State) ->
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, _) ->
    ok.

%% internal

%% If a record can be fully read from the data then handle the request
%% else return the data to be kept in the buffer
-spec handle_data(binary(), head | solo | tail, inets:socket()) ->
                         {ok, binary()} | {error, any()}.
handle_data(<<Size:32/signed-integer, Message:Size/binary, Rest/binary>>,
            Role, Socket) ->
    case handle_request(Message, Role, Socket) of
        {error, Reason} ->
            {error, Reason};
        _ ->
            handle_data(Rest, Role, Socket)
    end;
handle_data(Data, _Role, _Socket) ->
    {ok, Data}.

%% Parse out the type of request (apikey) and the request data
handle_request(<<ApiKey:16/signed-integer, _ApiVersion:16/signed-integer, CorrelationId:32/signed-integer,
                 ClientIdSize:16/signed-integer, _ClientId:ClientIdSize/binary, Request/binary>>,
               Role, Socket) ->
    prometheus_counter:inc(client_requests),
    handle_request(ApiKey, Role, Request, CorrelationId, Socket).

handle_request(?METADATA_REQUEST, _, Data, CorrelationId, Socket) ->
    Topics0 = vg_protocol:decode_metadata_request(Data),
    Topics = case Topics0 of
                 [] -> vg_topics:all();
                 _ -> Topics0
             end,
    lager:info("at=metadata_request topics=~p", [Topics]),
    %% need to return all nodes and start giving nodes an integer id
    {_, Chains, _} = vg_cluster_mgr:get_map(),
    {_, Nodes} = maps:fold(fun(_Name, #chain{head={HeadHost, HeadPort},
                                             tail={TailHost, TailPort}}, {Id, Acc}) ->
                               HeadNode = {Id, {HeadHost, HeadPort}},
                               case {TailHost, TailPort} of
                                   {HeadHost, HeadPort} ->
                                       %% same as head node
                                       TailNode = {Id, {TailHost, TailPort}},
                                       {Id+1, [HeadNode, TailNode | Acc]};
                                   _ ->
                                       TailNode = {Id+1, {TailHost, TailPort}},
                                       {Id+2, [HeadNode, TailNode | Acc]}
                               end
                        end, {0, []}, Chains),
    TopicMetadata =
        lists:flatten([try
                           #chain{head=Head,
                                  tail=Tail} = vg_topics:get_chain(Topic),
                           {HeadId, _} = lists:keyfind(Head, 2, Nodes),
                           {TailId, _} = lists:keyfind(Tail, 2, Nodes),
                           {0, Topic, [{0, HeadId, 0, [TailId], []}]}
                       catch _:_ ->
                               %% if the topic doesn't exist, omit it,
                               %% so we can check for non-existent topics.
                               []
                       end || Topic <- Topics]),
    Response = vg_protocol:encode_metadata_response(Nodes, TopicMetadata),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, Response]);
handle_request(?ENSURE_REQUEST, _, Data, CorrelationId, Socket) ->
    Topics0 = vg_protocol:decode_metadata_request(Data),
    Topics = case Topics0 of
                 [] -> vg_topics:all();
                 _ -> [vg:ensure_topic(T) || T <- Topics0], Topics0
             end,
    lager:info("at=metadata_request topics=~p", [Topics]),
    %% need to return all nodes and start giving nodes an integer id
    {_, Chains, _} = vg_cluster_mgr:get_map(),
    {_, Nodes} = maps:fold(fun(_Name, #chain{head={HeadHost, HeadPort},
                                             tail={TailHost, TailPort}}, {Id, Acc}) ->
                               HeadNode = {Id, {HeadHost, HeadPort}},
                               case {TailHost, TailPort} of
                                   {HeadHost, HeadPort} ->
                                       %% same as head node
                                       TailNode = {Id, {TailHost, TailPort}},
                                       {Id+1, [HeadNode, TailNode | Acc]};
                                   _ ->
                                       TailNode = {Id+1, {TailHost, TailPort}},
                                       {Id+2, [HeadNode, TailNode | Acc]}
                               end
                        end, {0, []}, Chains),
    TopicMetadata = [begin
                         #chain{head=Head,
                                tail=Tail} = vg_topics:get_chain(Topic),
                         {HeadId, _} = lists:keyfind(Head, 2, Nodes),
                         {TailId, _} = lists:keyfind(Tail, 2, Nodes),
                         {0, Topic, [{0, HeadId, 0, [TailId], []}]}
                     end || Topic <- Topics],
    Response = vg_protocol:encode_metadata_response(Nodes, TopicMetadata),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, Response]);
handle_request(FetchType, Role, <<_ReplicaId:32/signed-integer, _MaxWaitTime:32/signed-integer,
                                  _MinBytes:32/signed-integer, Rest/binary>>,
               CorrelationId, Socket) when (Role =:= tail orelse Role =:= solo) andalso
                                           (FetchType =:= ?FETCH_REQUEST orelse
                                            FetchType =:= ?FETCH2_REQUEST) ->
    DecodeFn = case FetchType of
                   ?FETCH_REQUEST -> fun decode_topic/1;
                   ?FETCH2_REQUEST -> fun decode_topic2/1
               end,
    {TopicPartitions, _} = vg_protocol:decode_array(DecodeFn, Rest),
    try
        {Size, FetchResults}
            = lists:foldl(fun({Topic, Partitions}, {SizeAcc, ResponseAcc}) ->
                                  {S, R} = fetch(Topic, Partitions),
                                  {S + SizeAcc, ResponseAcc ++ R}
                          end, {4, [<<(length(TopicPartitions)):32/signed-integer>>]}, TopicPartitions),
        gen_tcp:send(Socket, <<(Size+4):32/signed-integer, CorrelationId:32/signed-integer>>),
        do_send(FetchResults, Socket)
    catch
        throw:{topic_not_found, Topic, Partition} ->
            Response = vg_protocol:encode_array([[vg_protocol:encode_string(Topic),
                                                  vg_protocol:encode_array([vg_protocol:encode_fetch_topic_response(Partition,
                                                                                                                    ?UNKNOWN_TOPIC_OR_PARTITION,
                                                                                                                    0,
                                                                                                                    0)])]]),
            ResponseSize = erlang:iolist_size(Response) + 4,
            gen_tcp:send(Socket, [<<ResponseSize:32/signed, CorrelationId:32/signed>>, Response]),
            {error, topic_not_found}
    end;
handle_request(?FETCH_REQUEST, _ , <<_ReplicaId:32/signed, _MaxWaitTime:32/signed,
                                     _MinBytes:32/signed, Rest/binary>>,
               CorrelationId, Socket) ->
    {[{Topic, [{Partition, _Offset, _MaxBytes} | _]} | _], _} = vg_protocol:decode_array(fun decode_topic/1, Rest),
    lager:info("at=fetch_request error=request_disallowed topic=~s partition=~p", [Topic, Partition]),
    Response = vg_protocol:encode_array([[vg_protocol:encode_string(Topic),
                                          vg_protocol:encode_array([vg_protocol:encode_fetch_topic_response(Partition,
                                                                                                            ?FETCH_DISALLOWED_ERROR,
                                                                                                            0,
                                                                                                            0)])]]),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed, CorrelationId:32/signed>>, Response]),
    {error, request_disallowed};
handle_request(?FETCH2_REQUEST, _ , <<_ReplicaId:32/signed, _MaxWaitTime:32/signed,
                                      _MinBytes:32/signed, Rest/binary>>,
               CorrelationId, Socket) ->
    {[{Topic, [{Partition, _Offset, _MaxBytes, _Limit} | _]} | _], _} = vg_protocol:decode_array(fun decode_topic2/1, Rest),
    lager:info("at=fetch2_request error=request_disallowed topic=~s partition=~p", [Topic, Partition]),
    Response = vg_protocol:encode_array([[vg_protocol:encode_string(Topic),
                                          vg_protocol:encode_array([vg_protocol:encode_fetch_topic_response(Partition,
                                                                                                            ?FETCH_DISALLOWED_ERROR,
                                                                                                            0,
                                                                                                            0)])]]),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed, CorrelationId:32/signed>>, Response]),
    {error, request_disallowed};
handle_request(?REPLICATE_REQUEST, Role, _Data, CorrelationId, Socket) when Role =:= head orelse Role =:= solo ->
    lager:info("at=replicate_request error=replicate_disallowed", []),
    ReplicateResponse = vg_protocol:encode_replicate_response({0, ?REPLICATE_DISALLOWED_ERROR, -1}),
    Size = erlang:iolist_size(ReplicateResponse) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed, CorrelationId:32/signed>>, ReplicateResponse]),
    {error, request_disallowed};
handle_request(?REPLICATE_REQUEST, _Role, Data, CorrelationId, Socket) ->
    {_Acks, _Timeout, {Topic, Partition, ExpectedId, MessageSet}} = vg_protocol:decode_replicate_request(Data),

    Response = case vg:write(Topic, Partition, ExpectedId, MessageSet) of
                   {ok, Offset} ->
                       {Partition, ?NO_ERROR, Offset};
                   {write_repair, RepairSet} ->
                       {Partition, ?WRITE_REPAIR, RepairSet};
                   {error, socket_closed} ->
                       {Partition, ?TIMEOUT_ERROR, -1};
                   {error, pool_timeout} ->
                       {Partition, ?TIMEOUT_ERROR, -1};
                   {error, timeout} ->
                       {Partition, ?TIMEOUT_ERROR, -1}
               end,

    ReplicateResponse = vg_protocol:encode_replicate_response(Response),
    Size = erlang:iolist_size(ReplicateResponse) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, ReplicateResponse]);
handle_request(?DELETE_TOPIC_REQUEST, _Role, Data, CorrelationId, Socket) ->
    {Topic, <<>>} = vg_protocol:decode_string(Data),
    lager:info("received request to delete topic ~p", [Topic]),
    try vg:delete_topic(Topic) of
        ok ->
            ok;
        {error, Reason} ->
            lager:info("at=delete_topic error=~p", [Reason])
    catch
        _:R ->
            lager:info("at=delete_topic error=~p", [R])
    end,
    Response = vg_protocol:encode_string(<<"OK">>),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, Response]);
handle_request(?REPLICATE_DELETE_TOPIC_REQUEST, _Role, Data, CorrelationId, Socket) ->
    {Topic, <<>>} = vg_protocol:decode_string(Data),
    lager:info("received replicated request to delete topic ~p", [Topic]),
    try vg_topic_mgr:delete_topic(Topic, 0) of
        ok ->
            ok;
        {error, Reason} ->
            lager:info("at=delete_topic error=~p", [Reason])
    catch
        _:R ->
            lager:info("at=delete_topic error=~p", [R])
    end,
    Response = vg_protocol:encode_string(<<"OK">>),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, Response]);
handle_request(?PRODUCE_REQUEST, Role, Data, CorrelationId, Socket) when Role =:= head orelse Role =:= solo ->
    {_Acks, _Timeout, TopicData} = vg_protocol:decode_produce_request(Data),
    Results = [{Topic, [begin
                            case vg:write_record_batch(Topic, Partition, MessageSet) of
                                {ok, Offset} ->
                                    {Partition, ?NO_ERROR, Offset};
                                {error, socket_closed} ->
                                    {Partition, ?TIMEOUT_ERROR, -1};
                                {error, pool_timeout} ->
                                    {Partition, ?TIMEOUT_ERROR, -1};
                                {error, timeout} ->
                                    {Partition, ?TIMEOUT_ERROR, -1}
                            end
                        end || {Partition, MessageSet} <- PartitionData]}
              || {Topic, PartitionData} <- TopicData],
    ProduceResponse = vg_protocol:encode_produce_response(Results),
    Size = erlang:iolist_size(ProduceResponse) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, ProduceResponse]);
handle_request(?PRODUCE_REQUEST, _, Data, CorrelationId, Socket) ->
    {_Acks, _Timeout, TopicData} = vg_protocol:decode_produce_request(Data),
    Results = [{Topic, [{Partition, ?PRODUCE_DISALLOWED_ERROR, 0}
                        || {Partition, _MessageSet} <- PartitionData]}
              || {Topic, PartitionData} <- TopicData],
    lager:info("at=produce_request error=request_disallowed", []),
    ProduceResponse = vg_protocol:encode_produce_response(Results),
    Size = erlang:iolist_size(ProduceResponse) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed, CorrelationId:32/signed>>, ProduceResponse]),
    {error, request_disallowed};
handle_request(?TOPICS_REQUEST, _Role, Data, CorrelationId, Socket) ->
    lager:info("at=topics_request"),
    {FilterTopics, <<>>} = vg_protocol:decode_array(fun vg_protocol:decode_string/1, Data),
    TopicsCount =
        case FilterTopics of
            [] ->
                length(vg_topics:all());
            _ ->
                %% count the number of sent topics that exist, usually just 1
                lists:sum([case vg_log_segments:local(T, 0) of
                               true -> 1;
                               _ -> 0
                           end
                           || T <- FilterTopics])
        end,
    {_, Chains0, _} = vg_cluster_mgr:get_map(),
    {_, Chains} = lists:unzip(maps:to_list(Chains0)),
    Response = [<<TopicsCount:32/signed-integer>>, vg_protocol:encode_chains(Chains)],
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, Response]).

-spec decode_topic(binary()) -> {topic_partition(), binary()}.
decode_topic(<<Size:16/signed-integer, Topic:Size/binary, PartitionsRaw/binary>>) ->
    {Partitions, Rest} = vg_protocol:decode_array(fun decode_partition/1, PartitionsRaw),
    {{Topic, Partitions}, Rest}.

-spec decode_partition(binary()) -> {partition(), binary()}.
decode_partition(<<Partition:32/signed-integer, FetchOffset:64/signed-integer, MaxBytes:32/signed-integer, Rest/binary>>) ->
    {{Partition, FetchOffset, MaxBytes}, Rest}.

-spec decode_topic2(binary()) -> {topic_partition(), binary()}.
decode_topic2(<<Size:16/signed-integer, Topic:Size/binary, PartitionsRaw/binary>>) ->
    {Partitions, Rest} = vg_protocol:decode_array(fun decode_partition2/1, PartitionsRaw),
    {{Topic, Partitions}, Rest}.

-spec decode_partition2(binary()) -> {limited_partition(), binary()}.
decode_partition2(<<Partition:32/signed-integer, FetchOffset:64/signed-integer,
                   MaxBytes:32/signed-integer, Index:32/signed-integer, Rest/binary>>) ->
    {{Partition, FetchOffset, MaxBytes, Index}, Rest}.

%%

fetch(Topic, Partitions) ->
    TopicResponseHeader = [vg_protocol:encode_string(Topic), <<(length(Partitions)):32/signed-integer>>],
    HeaderSize = 4 + 2 + size(Topic),
    {Size, Response} =
        lists:foldl(fun({Partition, Offset, MaxBytes}, {Size, ResponseAcc}) ->
                            {S, R, F} = vg:fetch(Topic, Partition, Offset, MaxBytes, -1),
                            {Size + S, [R, F | ResponseAcc]};
                       ({Partition, Offset, MaxBytes, Limit}, {Size, ResponseAcc}) ->
                            {S, R, F} = vg:fetch(Topic, Partition, Offset, MaxBytes, Limit),
                            {Size + S, [R, F | ResponseAcc]}
                    end, {HeaderSize, []}, Partitions),
    {Size, [TopicResponseHeader | Response]}.

%% a fetch response is a list of iolists and tuples representing file chunks to send through sendfile
do_send(FetchResults, Socket) ->
    lists:foreach(fun({_File, _Position, 0}) ->
                          %% have to noop here, as we're already framed,
                          %% and 0 has special meaning for sendfile
                          noop;
                     ({File, Position, Bytes}) ->
                       sendfile(File, Position, Bytes, Socket);
                     (noop) ->
                       noop;
                     (IoList) ->
                       gen_tcp:send(Socket, IoList)
                  end, FetchResults).

sendfile(File, Position, Bytes, Socket) ->
    {ok, Fd} = file:open(File, [read, binary, raw]),
    try
        {ok, _} = file:sendfile(Fd, Socket, Position, Bytes, [])
        %% best to crash here rather than try to recover.
    after
        file:close(Fd)
    end.

flush_socket(Socket) ->
    receive
        {tcp, Socket, Data}         -> flush_send(Socket, Data);
        {tcp_error, Socket, Reason} -> Reason;
        {tcp_closed, Socket}        -> normal
    after
        0                           -> normal
    end.

flush_send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok              -> flush_recv(Socket);
        {error, closed} -> normal;
        {error, Reason} -> Reason
    end.

flush_recv(Socket) ->
    case gen_tcp:recv(Socket, 0, 0) of
        {ok, Data}       -> flush_send(Socket, Data);
        {error, timeout} -> normal;
        {error, closed}  -> normal;
        {error, Reason}  -> Reason
end.
