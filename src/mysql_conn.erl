%%%-------------------------------------------------------------------
%%% File    : mysql_conn.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: MySQL connection handler, handles de-framing of messages
%%%           received by the MySQL receiver process.
%%% Created :  5 Aug 2005 by Fredrik Thulin <ft@it.su.se>
%%% Modified: 11 Jan 2006 by Mickael Remond <mickael.remond@process-one.net>
%%%
%%% Note    : All MySQL code was written by Magnus Ahltorp, originally
%%%           in the file mysql.erl - I just moved it here.
%%%
%%% Modified: 12 Sep 2006 by Yariv Sadan <yarivvv@gmail.com>
%%% Added automatic type conversion between MySQL types and Erlang types
%%% and different logging style.
%%%
%%% Modified: 23 Sep 2006 by Yariv Sadan <yarivvv@gmail.com>
%%% Added transaction handling and prepared statement execution.
%%%
%%% Copyright (c) 2001-2004 Kungliga Tekniska Högskolan
%%% See the file COPYING

%% @type mysql_result = {list(), list(), integer(), integer(), integer(), integer(), string(), string()}
%% @type query_result = {data, mysql_result()} | {updated, mysql_result()} | {error, mysql_result()}
%% @type fieldinfo =  {term(), term(), term(), term()}
%% @todo Gut all of the transaction functionality.
%% @todo Enhance the data receive loops and protect against bad results.
%% @author Fredrik Thulin <ft@it.su.se>
%% @author Kungliga Tekniska Högskolan
%% @author Yariv Sadan <yarivvv@gmail.com>
%% @author Nick Gerakines <nick@gerakines.net>
%% @doc A module that directly creates and manages MySQL connections.
-module(mysql_conn).

-export([start_link/7, fetch/3, fetch/4, execute/6]).
-export([init/8, do_recv/2]).

-include("mysql.hrl").
-record(state, {mysql_version, recv_pid, socket, data, prepares = gb_trees:empty(), pool_id}).

-define(SECURE_CONNECTION, 32768).
-define(MYSQL_QUERY_OP, 3).
-define(DEFAULT_STANDALONE_TIMEOUT, 5000).
-define(MYSQL_4_0, 40). %% Support for MySQL 4.0.x
-define(MYSQL_4_1, 41). %% Support for MySQL 4.1.x et 5.0.x

%% Used by transactions to get the state variable for this connection
%% when bypassing the dispatcher.
-define(STATE_VAR, mysql_connection_state).

%% @spec start(Host, Port, User, Password, Database, Encoding, PoolId) -> Result
%%       Host = string()
%%       Port = integer()
%%       User = string()
%%       Password = string()
%%       Database = string()
%%       Encoding = atom()
%%       PoolId = atom()
%%       Result = {ok, pid()} | {error, any()}
start_link(Host, Port, User, Password, Database, Encoding, PoolId) ->
   proc_lib:start_link(?MODULE, init, [Host, Port, User, Password, Database, Encoding, PoolId, self()]).

%% @equiv fetch(Pid, Queries, From, ?DEFAULT_STANDALONE_TIMEOUT)
fetch(Pid, Queries, From) ->
    fetch(Pid, Queries, From, ?DEFAULT_STANDALONE_TIMEOUT).

%% @spec fetch(Pid, Queries, From, Timeout) -> Result
%%       Pid = pid()
%%       Queries = [binary()]
%%       From = pid()
%%       Timeout = integer()
%%       Result = ok | {data, any()} | {updated, any()} | {error, any()}
%% @doc Send a query or a list of queries and wait for the result if running
%% stand-alone (From = self()), but don't block the caller if we are not
%% running stand-alone.
%% @todo Update this description, it's wrong.
fetch(Pid, Queries, From, Timeout)  ->
    do_fetch(Pid, Queries, From, Timeout).

execute(Pid, Name, Version, Params, From, Stmt) ->
    send_msg(Pid, {execute, Name, Version, Params, From, Stmt}, From, ?DEFAULT_STANDALONE_TIMEOUT).

%% @private
init(Host, Port, User, Password, Database, Encoding, PoolId, Parent) ->
    case mysql_recv:start_link(Host, Port, self()) of
        {ok, RecvPid, Sock} ->
            %% (NKG) Does this socket need to be explicitly closed if auth fails?
            case mysql_init(Sock, RecvPid, User, Password) of
                {ok, Version} ->
                    case set_database(Sock, RecvPid, Version, Database) of
                        E = {error, _} -> proc_lib:init_ack(Parent, E);
                        ok ->
                            proc_lib:init_ack(Parent, {ok, self()}),
                            set_encoding(Sock, RecvPid, Version, Encoding),
                            loop(#state{
                                mysql_version = Version,
                                recv_pid = RecvPid,
                                socket   = Sock,
                                pool_id  = PoolId,
                                data     = <<>>
                            })
                    end;
                {error, _Reason} ->
                    proc_lib:init_ack(Parent, {error, login_failed})
            end;
        _E ->
            proc_lib:init_ack(Parent, {error, connect_failed})
    end.

set_database(_, _, _, undefined) -> ok;
set_database(Sock, RecvPid, Version, Database) ->
    Db = iolist_to_binary(Database),
    case do_query(Sock, RecvPid, <<"use ", Db/binary>>, Version) of
        {error, _MySQLRes} -> {error, failed_changing_database};
        _ -> ok
    end.

set_encoding(_, _, _, undefined) -> ok;
set_encoding(Sock, RecvPid, Version, Encoding) when is_atom(Encoding) ->
    EncodingBinary = erlang:atom_to_binary(Encoding, utf8),
    do_query(Sock, RecvPid, <<"set names '", EncodingBinary/binary, "'">>, Version);
set_encoding(_, _, _, _) -> ok.

%% @private
loop(State) ->
    RecvPid = State#state.recv_pid,
    NewState = receive
        {'$mysql_conn_loop', {From, Mref}, {fetch, Queries}} ->
            gen:reply({From, Mref}, do_queries(State, Queries)),
            State;
        {'$mysql_conn_loop', {From, Mref}, {execute, Name, Version, Params, _From1, Stmt}} ->
            case do_execute(State, Name, Params, Version, Stmt) of
                {error, _} = Err ->
                    gen:reply({From, Mref}, Err),
                    State;
                {ok, Result, OutState} ->
                    gen:reply({From, Mref}, Result),
                    OutState
            end;
        {'$mysql_conn_loop', {_From, _Mref}, {mysql_recv, RecvPid, data, Packet, Num}} ->
            error_logger:error_report([?MODULE, ?LINE, unexpected_packet, {num, Num}, {packet, Packet}]),
            State;
        {'$mysql_conn_loop', {_From, _Mref}, Unknown} ->
            error_logger:error_report([?MODULE, ?LINE, {unsuppoted_message, Unknown}]),
            %% exit(unhandled_message);
            State;
        Unknown ->
            error_logger:error_report([?MODULE, ?LINE, {unsuppoted_message, Unknown}]),
            State
            %% exit(unhandled_message)
    end,
    loop(NewState).

%% @private
do_query(State, Query) ->
    do_query(
        State#state.socket,
        State#state.recv_pid,
        Query,
        State#state.mysql_version
    ).

%% @private
do_query(Sock, RecvPid, Query, Version) ->
    Query1 = iolist_to_binary(Query),
    Packet =  <<?MYSQL_QUERY_OP, Query1/binary>>,
    case do_send(Sock, Packet, 0) of
        ok ->
            get_query_response(RecvPid, Version);
        {error, Reason} ->
            Msg = io_lib:format("Failed sending data on socket : ~p", [Reason]),
            {error, Msg}
    end.

%% @private
do_queries(State, Queries) when not is_list(Queries) ->
    do_query(State, Queries);
do_queries(State, Queries) ->
    do_queries(
        State#state.socket,
        State#state.recv_pid,
        Queries,
        State#state.mysql_version
    ).

%% @doc Execute a list of queries, returning the response for the last query.
%% If a query returns an error before the last query is executed, the
%% loop is aborted and the error is returned. 
%% @private
do_queries(Sock, RecvPid, Queries, Version) ->
    catch(
        lists:foldl(
            fun(Query, _LastResponse) ->
                case do_query(Sock, RecvPid, Query, Version) of
                    {error, _} = Err -> throw(Err);
                    Res -> Res
                end
            end,
            ok,
            Queries
        )
    ).

%% @private
do_execute(State, Name, Params, ExpectedVersion, Stmt) ->
    Res = case gb_trees:lookup(Name, State#state.prepares) of
        {value, Version} when Version == ExpectedVersion -> {ok, latest};
        {value, Version} -> {ok, {Stmt, Version}};
        none -> {ok, {Stmt, 1}}
    end,
    case Res of
        {ok, latest} -> {ok, do_execute1(State, Name, Params), State};
        {ok, {Stmt, NewVersion}} -> prepare_and_exec(State, Name, NewVersion, Stmt, Params);
        {error, _} = Err -> Err
    end.

%% @private
prepare_and_exec(State, Name, Version, Stmt, Params) ->
    NameBin = erlang:atom_to_binary(Name, utf8),
    StmtBin = <<"PREPARE ", NameBin/binary, " FROM '", Stmt/binary, "'">>,
    case do_query(State, StmtBin) of
        {updated, _} ->
            State1 = State#state{
                prepares = gb_trees:enter(Name, Version, State#state.prepares)
            },
            {ok, do_execute1(State1, Name, Params), State1};
        {error, _} = Err -> Err;
        Other ->
            {error, {unexpected_result, Other}}
    end.

%% @private
do_execute1(State, Name, Params) ->
    Stmts = make_statements_for_execute(Name, Params),
    do_queries(State, Stmts).

%% @private
make_statements_for_execute(Name, []) ->
    NameBin = erlang:atom_to_binary(Name, utf8),
    [<<"EXECUTE ", NameBin/binary>>];
make_statements_for_execute(Name, Params) ->
    NumParams = length(Params),
    ParamNums = lists:seq(1, NumParams),

    NameBin = erlang:atom_to_binary(Name, utf8),
    
    ParamNames = lists:foldl(
        fun(Num, Acc) ->
            ParamName = [$@ | integer_to_list(Num)],
            if
                Num == 1 -> ParamName ++ Acc;
                true -> [$, | ParamName] ++ Acc
            end
        end,
        [], lists:reverse(ParamNums)
    ),
    ParamNamesBin = list_to_binary(ParamNames),

    ExecStmt = <<"EXECUTE ", NameBin/binary, " USING ", ParamNamesBin/binary>>,

    ParamVals = lists:zip(ParamNums, Params),
    Stmts = lists:foldl(
        fun({Num, Val}, Acc) ->
            NumBin = mysql:encode(Num, true),
            ValBin = mysql:encode(Val, true),
            [<<"SET @", NumBin/binary, "=", ValBin/binary>> | Acc]
        end,
        [ExecStmt], lists:reverse(ParamVals)
    ),
    Stmts.

%% @private
do_recv(RecvPid, SeqNum)  when SeqNum == undefined ->
    receive
        {mysql_recv, RecvPid, data, Packet, Num} ->
            {ok, Packet, Num};
        {mysql_recv, RecvPid, closed, _E} ->
            {error, "mysql_recv: socket was closed"}
    end;
do_recv(RecvPid, SeqNum) when is_integer(SeqNum) ->
    ResponseNum = SeqNum + 1,
    receive
        {mysql_recv, RecvPid, data, Packet, ResponseNum} ->
            {ok, Packet, ResponseNum};
        {mysql_recv, RecvPid, closed, _E} ->
            {error, "mysql_recv: socket was closed"}
    end.

%% @private
do_fetch(Pid, Queries, From, Timeout) ->
    send_msg(Pid, {fetch, Queries}, From, Timeout).

%% @private
send_msg(Pid, Msg, _From, _Timeout) ->
    {ok, Response} = gen:call(Pid, '$mysql_conn_loop', Msg),
    case Response of
        {fetch_result, _Pid, Result} -> Result;
        Other -> Other
    end.

%% @private
mysql_init(Sock, RecvPid, User, Password) ->
    receive
        {mysql_recv, RecvPid, data, Packet, InitSeqNum} ->
            {Version, Salt1, Salt2, Caps} = greeting(Packet),
            AuthRes = case Caps band ?SECURE_CONNECTION of
                ?SECURE_CONNECTION ->
                    mysql_auth:do_new_auth(Sock, RecvPid, InitSeqNum + 1, User, Password, Salt1, Salt2);
                _ ->
                    mysql_auth:do_old_auth(Sock, RecvPid, InitSeqNum + 1, User, Password, Salt1)
            end,
            case AuthRes of
                {ok, <<0:8, _Rest/binary>>, _RecvNum} ->
                    {ok,Version};
                {ok, <<255:8, _Code:16/little, Message/binary>>, _RecvNum} ->
                    {error, binary_to_list(Message)};
                {ok, RecvPacket, _RecvNum} ->
                    {error, binary_to_list(RecvPacket)};
                {error, Reason} ->
                    {error, Reason}
            end;
        {mysql_recv, RecvPid, closed, _E} ->
            {error, "mysql_recv: socket was closed"}
    end.

%% @private
greeting(Packet) ->
    <<_Protocol:8, Rest/binary>> = Packet,
    {Version, Rest2} = asciz(Rest),
    <<_TreadID:32/little, Rest3/binary>> = Rest2,
    {Salt, Rest4} = asciz(Rest3),
    <<Caps:16/little, Rest5/binary>> = Rest4,
    <<_ServerChar:16/binary-unit:8, Rest6/binary>> = Rest5,
    {Salt2, _Rest7} = asciz(Rest6),
    {normalize_version(Version), Salt, Salt2, Caps}.

%% @private
asciz(Data) when is_binary(Data) ->
    mysql:asciz_binary(Data, []);
asciz(Data) when is_list(Data) ->
    {String, [0 | Rest]} = lists:splitwith(fun (C) -> C /= 0 end, Data),
    {String, Rest}.

%% @private
%% @todo This really needs to be cleaned up.
get_query_response(RecvPid, Version) ->
    case do_recv(RecvPid, undefined) of
        {ok, <<Fieldcount:8, Rest/binary>>, _} ->
            case Fieldcount of
                0 ->
                    {ok, AffectedRows, Rest1} = get_length_coded_binary(Rest),
                    {ok, InsertID, Rest2} = get_length_coded_binary(Rest1),
                    <<ServerStatus:16/integer, Rest3/binary>> = Rest2,
                    <<WarningCount:16/integer, Message0/binary>> = Rest3,
                    {ok, Message, _} = get_length_coded_string(Message0),
                    Res = #mysql_result{
                        affectedrows = AffectedRows, 
                        insert_id = InsertID,
                        server_status = ServerStatus,
                        warning_count = WarningCount,
                        message = Message
                    },
                    {updated, Res};
                255 ->
                    <<_Code:16/little, Message/binary>>  = Rest,
                    {error, #mysql_result{error=Message}};
                _ ->
                    %% Tabular data received
                    case get_fields(RecvPid, [], Version) of
                        {ok, Fields} ->
                            case get_rows(Fields, RecvPid, []) of
                                {ok, Rows} -> {data, #mysql_result{fieldinfo=Fields, rows=Rows}};
                                {error, Reason} ->{error, #mysql_result{error=Reason}}
                            end;
                        {error, Reason} ->
                            {error, #mysql_result{error=Reason}}
                    end
            end;
        {error, Reason} ->
            {error, #mysql_result{error=Reason}}
    end.

%% @private
get_length_coded_binary(<<FirstByte:8, Rest/binary>>) ->
    if
        FirstByte =< 250 -> {ok, FirstByte, Rest};
        FirstByte == 251 -> {ok, FirstByte, Rest};
        FirstByte == 252 ->
            case Rest of
                <<FollowingBytes:16/integer, Rest1/binary>> -> {ok, FollowingBytes, Rest1};
                _ -> {ok, bad_packet, <<>>}
            end;
        FirstByte == 253 ->
            case Rest of
                <<FollowingBytes:24/integer, Rest1/binary>> -> {ok, FollowingBytes, Rest1};
                _ -> {ok, bad_packet, <<>>}
            end;
        FirstByte == 254 ->
            case Rest of
                <<FollowingBytes:64/integer, Rest1/binary>> -> {ok, FollowingBytes, Rest1};
                _ -> {ok, bad_packet, <<>>}
            end;
        true ->
            {ok, bad_packet, <<>>}
    end;
get_length_coded_binary(_) ->
    {ok, bad_packet, <<>>}.

%% @private
get_length_coded_string(<<>>) -> {ok, "", <<>>};
get_length_coded_string(Bin) ->
    {ok, Length, Rest} = get_length_coded_binary(Bin),
    case Rest of
        <<String:Length/binary, Rest1/binary>> -> {ok, binary_to_list(String), Rest1};
        _ -> {ok, bad_packet, <<>>}
    end.

%% @private
get_fields(RecvPid, Res, ?MYSQL_4_0) ->
    case do_recv(RecvPid, undefined) of
        {ok, Packet, _Num} ->
            case Packet of
                <<254:8>> -> {ok, lists:reverse(Res)};
                <<254:8, Rest/binary>> when size(Rest) < 8 -> {ok, lists:reverse(Res)};
                _ ->
                    {Table, Rest} = get_with_length(Packet),
                    {Field, Rest2} = get_with_length(Rest),
                    {LengthB, Rest3} = get_with_length(Rest2),
                    LengthL = size(LengthB) * 8,
                    <<Length:LengthL/little>> = LengthB,
                    {Type, Rest4} = get_with_length(Rest3),
                    {_Flags, _Rest5} = get_with_length(Rest4),
                    This = {Table,
                        Field,
                        Length,
                        %% TODO: Check on MySQL 4.0 if types are specified
                        %%       using the same 4.1 formalism and could 
                        %%       be expanded to atoms:
                        Type},
                    get_fields(RecvPid, [This | Res], ?MYSQL_4_0)
            end;
        {error, Reason} ->
            {error, Reason}
    end;
%% Support for MySQL 4.1.x and 5.x:
get_fields(RecvPid, Res, ?MYSQL_4_1) ->
    case do_recv(RecvPid, undefined) of
        {ok, Packet, _Num} ->
            case Packet of
                <<254:8>> -> {ok, lists:reverse(Res)};
                <<254:8, Rest/binary>> when size(Rest) < 8 -> {ok, lists:reverse(Res)};
                _ ->
                    {_Catalog, Rest} = get_with_length(Packet),
                    {_Database, Rest2} = get_with_length(Rest),
                    {Table, Rest3} = get_with_length(Rest2),
                    %% OrgTable is the real table name if Table is an alias
                    {_OrgTable, Rest4} = get_with_length(Rest3),
                    {Field, Rest5} = get_with_length(Rest4),
                    %% OrgField is the real field name if Field is an alias
                    {_OrgField, Rest6} = get_with_length(Rest5),

                    %% <<Metadata:8/little, Charset:16/little, Length:32/little, Type:8/little, Flags:16/little, Decimals:8:litle, .../binary>>
                    <<_:8/little, _:16/little, Length:32/little, Type:8/little, _:16/little, _:8/little, _Rest7/binary>> = Rest6,

                    This = {Table, Field, Length, get_field_datatype(Type)},
                    get_fields(RecvPid, [This | Res], ?MYSQL_4_1)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
get_rows(Fields, RecvPid, Res) ->
    case do_recv(RecvPid, undefined) of
        {ok, Packet, _Num} ->
            case Packet of
                <<254:8, Rest/binary>> when size(Rest) < 8 -> {ok, lists:reverse(Res)};
                _ ->
                    {ok, This} = get_row(Fields, Packet, []),
                    get_rows(Fields, RecvPid, [This | Res])
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
get_row([], _Data, Res) ->
    {ok, lists:reverse(Res)};
get_row([Field | OtherFields], Data, Res) ->
    {Col, Rest} = get_with_length(Data),
    This = case Col of
        null -> undefined;
        _ -> convert_type(Col, element(4, Field))
    end,
    get_row(OtherFields, Rest, [This | Res]).

%% @private
get_with_length(<<251:8, Rest/binary>>) ->
    {null, Rest};
get_with_length(<<252:8, Length:16/little, Rest/binary>>) ->
    split_binary(Rest, Length);
get_with_length(<<253:8, Length:24/little, Rest/binary>>) ->
    split_binary(Rest, Length);
get_with_length(<<254:8, Length:64/little, Rest/binary>>) ->
    split_binary(Rest, Length);
get_with_length(<<Length:8, Rest/binary>>) when Length < 251 ->
    split_binary(Rest, Length).


%% @private
do_send(Sock, Packet, SeqNum) when is_binary(Packet), is_integer(SeqNum) ->
    Data = <<(size(Packet)):24/little, SeqNum:8, Packet/binary>>,
    gen_tcp:send(Sock, Data).

%% @private
normalize_version([$4,$.,$0|_T]) ->
    ?MYSQL_4_0;
normalize_version([$4,$.,$1|_T]) ->
    ?MYSQL_4_1;
normalize_version([$5|_T]) ->
    %% MySQL version 5.x protocol is compliant with MySQL 4.1.x:
    ?MYSQL_4_1; 
normalize_version(_Other) ->
    %% Error, but trying the oldest protocol anyway:
    ?MYSQL_4_0.

%% @private
get_field_datatype(0) ->   'DECIMAL';
get_field_datatype(1) ->   'TINY';
get_field_datatype(2) ->   'SHORT';
get_field_datatype(3) ->   'LONG';
get_field_datatype(4) ->   'FLOAT';
get_field_datatype(5) ->   'DOUBLE';
get_field_datatype(6) ->   'NULL';
get_field_datatype(7) ->   'TIMESTAMP';
get_field_datatype(8) ->   'LONGLONG';
get_field_datatype(9) ->   'INT24';
get_field_datatype(10) ->  'DATE';
get_field_datatype(11) ->  'TIME';
get_field_datatype(12) ->  'DATETIME';
get_field_datatype(13) ->  'YEAR';
get_field_datatype(14) ->  'NEWDATE';
get_field_datatype(246) -> 'NEWDECIMAL';
get_field_datatype(247) -> 'ENUM';
get_field_datatype(248) -> 'SET';
get_field_datatype(249) -> 'TINYBLOB';
get_field_datatype(250) -> 'MEDIUM_BLOG';
get_field_datatype(251) -> 'LONG_BLOG';
get_field_datatype(252) -> 'BLOB';
get_field_datatype(253) -> 'VAR_STRING';
get_field_datatype(254) -> 'STRING';
get_field_datatype(255) -> 'GEOMETRY'.

%% @todo Handle leftovers.
convert_type(Val, ColType) ->
    case ColType of
        T when T == 'TINY'; T == 'SHORT'; T == 'LONG'; T == 'LONGLONG'; T == 'INT24'; T == 'YEAR' ->
            list_to_integer(binary_to_list(Val));
        T when T == 'TIMESTAMP'; T == 'DATETIME' ->
            {ok, [Year, Month, Day, Hour, Minute, Second], _Leftovers} =
            io_lib:fread("~d-~d-~d ~d:~d:~d", binary_to_list(Val)),
            {datetime, {{Year, Month, Day}, {Hour, Minute, Second}}};
        'TIME' ->
            {ok, [Hour, Minute, Second], _Leftovers} =
            io_lib:fread("~d:~d:~d", binary_to_list(Val)),
            {time, {Hour, Minute, Second}};
        'DATE' ->
            {ok, [Year, Month, Day], _Leftovers} =
            io_lib:fread("~d-~d-~d", binary_to_list(Val)),
            {date, {Year, Month, Day}};
        T when T == 'DECIMAL'; T == 'NEWDECIMAL'; T == 'FLOAT'; T == 'DOUBLE' ->
            {ok, [Num], _Leftovers} = case io_lib:fread("~f", binary_to_list(Val)) of
                {error, _} -> io_lib:fread("~d", binary_to_list(Val));
                Res -> Res
            end,
            Num;
        _Other ->
            Val
    end.
