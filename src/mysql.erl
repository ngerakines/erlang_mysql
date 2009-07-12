%%% File    : mysql.erl
%%% Author  : Magnus Ahltorp <ahltorp@nada.kth.se>
%%% Descrip.: MySQL client.
%%%
%%% Created :  4 Aug 2005 by Magnus Ahltorp <ahltorp@nada.kth.se>
%%%
%%% Copyright (c) 2001-2004 Kungliga Tekniska Högskolan
%%% See the file COPYING
%%%
%%% Modified: 9/12/2006 by Yariv Sadan <yarivvv@gmail.com>
%%% Note: Added support for prepared statements,
%%% transactions, better connection pooling, more efficient logging
%%% and made other internal enhancements.
%%%
%%% Modified: 9/23/2006 Rewrote the transaction handling code to
%%% provide a simpler, Mnesia-style transaction interface. Also,
%%% moved much of the prepared statement handling code to mysql_conn.erl
%%% and added versioning to prepared statements.
%%% 
%%%
%%% Usage:
%%%
%%%
%%% Call one of the start-functions before any call to fetch/2
%%%
%%%   start_link(PoolId, Host, User, Password, Database)
%%%   start_link(PoolId, Host, Port, User, Password, Database)
%%%
%%% (These functions also have non-linking coutnerparts.)
%%%
%%% PoolId is a connection pool identifier. If you want to have more
%%% than one connection to a server (or a set of MySQL replicas),
%%% add more with
%%%
%%%   connect(PoolId, Host, Port, User, Password, Database, Reconnect)
%%%
%%% use 'undefined' as Port to get default MySQL port number (3306).
%%% MySQL querys will be sent in a per-PoolId round-robin fashion.
%%% Set Reconnect to 'true' if you want the dispatcher to try and
%%% open a new connection, should this one die.
%%%
%%% When you have a mysql_dispatcher running, this is how you make a
%%% query :
%%%
%%%   fetch(PoolId, "select * from hello") -> Result
%%%     Result = {data, MySQLRes} | {updated, MySQLRes} |
%%%              {error, MySQLRes}
%%%
%%% Actual data can be extracted from MySQLRes by calling the following API
%%% functions:
%%%     - on data received:
%%%          FieldInfo = mysql:get_result_field_info(MysqlRes)
%%%          AllRows   = mysql:get_result_rows(MysqlRes)
%%%         with FieldInfo = list() of {Table, Field, Length, Name}
%%%          and AllRows   = list() of list() representing records
%%%     - on update:
%%%          Affected  = mysql:get_result_affected_rows(MysqlRes)
%%%         with Affected  = integer()
%%%     - on error:
%%%          Reason    = mysql:get_result_reason(MysqlRes)
%%%         with Reason    = string()
%%% 
%%% If you just want a single MySQL connection, or want to manage your
%%% connections yourself, you can use the mysql_conn module as a
%%% stand-alone single MySQL connection. See the comment at the top of
%%% mysql_conn.erl.

-module(mysql).
-behaviour(gen_server).

%% Internal exports - gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-compile(export_all).

%% Records
-include("mysql.hrl").

-record(conn, {pool_id, pid, reconnect, host, port, user, password, database, encoding}).
-record(state, {
    conn_pools = gb_trees:empty(),
    pids_pools = gb_trees:empty(),
    prepares = gb_trees:empty()
}).

%% Macros
-define(SERVER, mysql_dispatcher).
-define(STATE_VAR, mysql_connection_state).
-define(CONNECT_TIMEOUT, 5000).
-define(LOCAL_FILES, 128).
-define(PORT, 3306).

%% @spec start_link(PoolId, Host, Port, User, Password, Database, Encoding) -> Result
%%       PoolId = atom()
%%       Host = string()
%%       Port = undefined | integer()
%%       User = string()
%%       Password = string()
%%       Database = string()
%%       Encoding = atom
%%       Result = {ok, pid()} | ignore | {error, any()}
%% @doc Starts the MySQL client gen_server process.
start_link(PoolId, Host, undefined, User, Password, Database, Encoding) ->
    start_link(PoolId, Host, ?PORT, User, Password, Database, Encoding);
start_link(PoolId, Host, Port, User, Password, Database, Encoding) ->
    crypto:start(),
    gen_server:start_link(
        {local, ?SERVER},
        ?MODULE,
        [PoolId, Host, Port, User, Password, Database, Encoding],
        []
    ).

%% @spec: connect(PoolId::atom(), Host::string(), Port::integer() | undefined,
%%    User::string(), Password::string(), Database::string(),
%%    Encoding::string(), Reconnect::bool(), LinkConnection::bool()) ->
%%      {ok, ConnPid} | {error, Reason}
%% @doc Add an additional MySQL connection to a given pool.
%% @spec connect(PoolId, Host, Port, User, Password, Database, Encoding) -> Result
connect(PoolId, Host, undefined, User, Password, Database, Encoding) ->
    connect(PoolId, Host, ?PORT, User, Password, Database, Encoding);
connect(PoolId, Host, Port, User, Password, Database, Encoding) ->
    case mysql_conn:start_link(Host, Port, User, Password, Database, Encoding, PoolId) of
        {ok, ConnPid} ->
            Conn = new_conn(PoolId, ConnPid, true, Host, Port, User, Password, Database, Encoding),
            case gen_server:call(?SERVER, {add_conn, Conn}) of
                ok -> {ok, ConnPid};
                Res -> Res
            end;
        Err-> Err
    end.

new_conn(PoolId, ConnPid, Reconnect, Host, Port, User, Password, Database, Encoding) ->
    case Reconnect of
        true ->
            #conn{
                pool_id = PoolId,
                pid = ConnPid,
                reconnect = true,
                host = Host,
                port = Port,
                user = User,
                password = Password,
                database = Database,
                encoding = Encoding
            };
        false ->                        
            #conn{
                pool_id = PoolId,
                pid = ConnPid,
                reconnect = false
            }
    end.

%% @doc Send a query to a connection from the connection pool and wait
%%   for the result. If this function is called inside a transaction,
%%   the PoolId parameter is ignored.
%%
%% @spec fetch(PoolId::atom(), Query::iolist(), Timeout::integer()) ->
%%   query_result()
fetch(PoolId, Query) ->
    fetch(PoolId, Query, undefined).

fetch(PoolId, Query, Timeout) -> 
    call_server({fetch, PoolId, Query}, Timeout).


%% @doc Register a prepared statement with the dispatcher. This call does not
%%   prepare the statement in any connections. The statement is prepared
%%   lazily in each connection when it is told to execute the statement.
%%   If the Name parameter matches the name of a statement that has
%%   already been registered, the version of the statement is incremented
%%   and all connections that have already prepared the statement will
%%   prepare it again with the newest version.
%%
%% @spec prepare(Name::atom(), Query::iolist()) -> ok
prepare(Name, Query) ->
    gen_server:cast(?SERVER, {prepare, Name, Query}).

%% @doc Get the prepared statement with the given name.
%%
%%  This function is called from mysql_conn when the connection is
%%  told to execute a prepared statement it has not yet prepared, or
%%  when it is told to execute a statement inside a transaction and
%%  it's not sure that it has the latest version of the statement.
%%
%%  If the latest version of the prepared statement matches the Version
%%  parameter, the return value is {ok, latest}. This saves the cost
%%  of sending the query when the connection already has the latest version.
%%
%% @spec get_prepared(Name::atom(), Version::integer()) ->
%%   {ok, latest} | {ok, Statement::binary()} | {error, Err}
get_prepared(Name) ->
    get_prepared(Name, undefined).
get_prepared(Name, Version) ->
    gen_server:call(?SERVER, {get_prepared, Name, Version}).

%% @doc Execute a query in the connection pool identified by
%% PoolId. This function optionally accepts a list of parameters to pass
%% to the prepared statement and a Timeout parameter.
%% If this function is called inside a transaction, the PoolId paramter is
%% ignored.
%%
%% @spec execute(PoolId::atom(), Name::atom(), Params::[term()],
%%   Timeout::integer()) -> mysql_result()
execute(PoolId, Name) when is_atom(PoolId), is_atom(Name) ->
    execute(PoolId, Name, []).

execute(PoolId, Name, Timeout) when is_integer(Timeout) ->
    execute(PoolId, Name, [], Timeout);

execute(PoolId, Name, Params) when is_list(Params) ->
    execute(PoolId, Name, Params, undefined).

execute(PoolId, Name, Params, Timeout) ->
    call_server({execute, PoolId, Name, Params}, Timeout).

%% @doc Extract the FieldInfo from MySQL Result on data received.
%%
%% @spec get_result_field_info(MySQLRes::mysql_result()) ->
%%   [{Table, Field, Length, Name}]
get_result_field_info(#mysql_result{fieldinfo = FieldInfo}) -> FieldInfo.

%% @doc Extract the Rows from MySQL Result on data received
%% 
%% @spec get_result_rows(MySQLRes::mysql_result()) -> [Row::list()]
get_result_rows(#mysql_result{rows=AllRows}) -> AllRows.

%% @doc Extract the Rows from MySQL Result on update
%%
%% @spec get_result_affected_rows(MySQLRes::mysql_result()) ->
%%           AffectedRows::integer()
get_result_affected_rows(#mysql_result{affectedrows=AffectedRows}) -> AffectedRows.

%% @doc Extract the insert id from MySQL Result on insert
%%
%% @spec get_result_insert_id(MySQLRes::mysql_result()) ->
%%           InsertID::integer()
get_result_insert_id(#mysql_result{insert_id=InsertID}) -> InsertID.

%% @doc Extract the error Reason from MySQL Result on error
%%
%% @spec get_result_reason(MySQLRes::mysql_result()) ->
%%    Reason::string()
get_result_reason(#mysql_result{error=Reason}) -> Reason.

init([PoolId, Host, Port, User, Password, Database, Encoding]) ->
    case mysql_conn:start_link(Host, Port, User, Password, Database, Encoding, PoolId) of
        {ok, ConnPid} ->
            Conn = new_conn(PoolId, ConnPid, true, Host, Port, User, Password, Database, Encoding),
            {ok, add_conn(Conn, #state{ })};
        {error, Reason} ->
            {stop, {error, Reason}}
    end.

handle_call({fetch, PoolId, Query}, From, State) ->
    with_next_conn(
        PoolId, State,
        fun(Conn, State1) ->
            Pid = Conn#conn.pid,
            Results = mysql_conn:fetch(Pid, Query, From),
            {reply, Results, State1}
        end
    );

handle_call({get_prepared, Name, Version}, _From, State) ->
    case gb_trees:lookup(Name, State#state.prepares) of
        none ->
            {reply, {error, {undefined, Name}}, State};
        {value, {_StmtBin, Version1}} when Version1 == Version ->
            {reply, {ok, latest}, State};
        {value, Stmt} ->
            {reply, {ok, Stmt}, State}
    end;

handle_call({execute, PoolId, Name, Params}, From, State) ->
    with_next_conn(
        PoolId, State,
        fun(Conn, State1) ->
            case gb_trees:lookup(Name, State1#state.prepares) of
                none ->
                    {reply, {error, {no_such_statement, Name}}, State1};
                {value, {Stmt, Version}} ->
                    Response = mysql_conn:execute(Conn#conn.pid, Name, Version, Params, From, Stmt),
                    {reply, Response, State1}
            end
        end
    );

handle_call({add_conn, Conn}, _From, State) ->
    NewState = add_conn(Conn, State),
    {reply, ok, NewState}.

handle_cast({prepare, Name, Stmt}, State) ->
    Version1 = case gb_trees:lookup(Name, State#state.prepares) of
        {value, {_Stmt, Version}} -> Version + 1;
        none -> 1
    end,
    {noreply, State#state{prepares = gb_trees:enter(Name, {Stmt, Version1}, State#state.prepares)}}.

%% Called when a connection to the database has been lost. If
%% The 'reconnect' flag was set to true for the connection, we attempt
%% to establish a new connection to the database.
handle_info({'DOWN', _MonitorRef, process, Pid, _Info}, State) ->
    case remove_conn(Pid, State) of
        {ok, Conn, NewState} ->
            case Conn#conn.reconnect of
                true -> start_reconnect(Conn);
                false -> ok
            end,
            {noreply, NewState};
        error ->
            {noreply, State}
    end.
    
terminate(Reason, _State) -> Reason.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Internal functions

with_next_conn(PoolId, State, Fun) ->
    case get_next_conn(PoolId, State) of
        {ok, Conn, NewState} ->    
            Fun(Conn, NewState);
        error ->
            {reply, {error, {no_connection_in_pool, PoolId}}, State}
    end.

call_server(Msg, Timeout) when Timeout == undefined ->
    gen_server:call(?SERVER, Msg);
call_server(Msg, Timeout) ->
    gen_server:call(?SERVER, Msg, Timeout).

add_conn(Conn, State) ->
    Pid = Conn#conn.pid,
    erlang:monitor(process, Conn#conn.pid),
    PoolId = Conn#conn.pool_id,
    ConnPools = State#state.conn_pools,
    NewPool =  case gb_trees:lookup(PoolId, ConnPools) of
        none -> {[Conn],[]};
        {value, {Unused, Used}} -> {[Conn | Unused], Used}
    end,
    State#state{
        conn_pools = gb_trees:enter(PoolId, NewPool, ConnPools),
        pids_pools = gb_trees:enter(Pid, PoolId, State#state.pids_pools)
    }.

remove_pid_from_list(Pid, Conns) ->
    lists:foldl(
        fun (OtherConn, {NewConns, undefined}) ->
            if
                OtherConn#conn.pid == Pid -> {NewConns, OtherConn};
                true -> {[OtherConn | NewConns], undefined}
            end;
            (OtherConn, {NewConns, FoundConn}) ->
                {[OtherConn|NewConns], FoundConn}
        end,
        {[],undefined}, lists:reverse(Conns)
    ).

remove_pid_from_lists(Pid, Conns1, Conns2) ->
    case remove_pid_from_list(Pid, Conns1) of
        {NewConns1, undefined} ->
            {NewConns2, Conn} = remove_pid_from_list(Pid, Conns2),
            {Conn, {NewConns1, NewConns2}};
        {NewConns1, Conn} ->
            {Conn, {NewConns1, Conns2}}
    end.
    
remove_conn(Pid, State) ->
    PidsPools = State#state.pids_pools,
    case gb_trees:lookup(Pid, PidsPools) of
        none ->
            error;
        {value, PoolId} ->
            ConnPools = State#state.conn_pools,
            case gb_trees:lookup(PoolId, ConnPools) of
            none ->
                error;
            {value, {Unused, Used}} ->
                {Conn, NewPool} = remove_pid_from_lists(Pid, Unused, Used),
                NewConnPools = gb_trees:enter(PoolId, NewPool, ConnPools),
                {ok, Conn, State#state{
                    conn_pools = NewConnPools,
                    pids_pools = gb_trees:delete(Pid, PidsPools)
                }}
            end
    end.

get_next_conn(PoolId, State) ->
    ConnPools = State#state.conn_pools,
    case gb_trees:lookup(PoolId, ConnPools) of
        none ->
            error;
        {value, {[],[]}} ->
            error;
        {value, {[], Used}} ->
            [Conn | Conns] = lists:reverse(Used),
            {ok, Conn, State#state{
                conn_pools = gb_trees:enter(PoolId, {Conns, [Conn]}, ConnPools)
            }};
        {value, {[Conn|Unused], Used}} ->
            {ok, Conn, State#state{
                conn_pools = gb_trees:enter(PoolId, {Unused, [Conn|Used]}, ConnPools)
            }}
    end.

%% @todo This should probably be monitored somehow.
start_reconnect(Conn) ->
    spawn_link(fun () ->
        reconnect_loop(Conn#conn{ pid = undefined }, 0)
    end),
    ok.

reconnect_loop(Conn, N) ->
    {PoolId, Host, Port} = {Conn#conn.pool_id, Conn#conn.host, Conn#conn.port},
    case connect(PoolId, Host, Port, Conn#conn.user, Conn#conn.password, Conn#conn.database, Conn#conn.encoding) of
        {ok, _ConnPid} ->
            ok;
        {error, _Reason} ->
            timer:sleep(5 * 1000),
            reconnect_loop(Conn, N + 1)
    end.


%% @doc Encode a value so that it can be included safely in a MySQL query.
%%
%% @spec encode(Val::term(), AsBinary::bool()) ->
%%   string() | binary() | {error, Error}
encode(Val) ->
    encode(Val, false).
encode(Val, false) when Val == undefined; Val == null ->
    "null";
encode(Val, true) when Val == undefined; Val == null ->
    <<"null">>;
encode(Val, false) when is_binary(Val) ->
    binary_to_list(quote(Val));
encode(Val, true) when is_binary(Val) ->
    quote(Val);
encode(Val, true) ->
    list_to_binary(encode(Val,false));
encode(Val, false) when is_atom(Val) ->
    quote(atom_to_list(Val));
encode(Val, false) when is_list(Val) ->
    quote(Val);
encode(Val, false) when is_integer(Val) ->
    integer_to_list(Val);
encode(Val, false) when is_float(Val) ->
    [Res] = io_lib:format("~w", [Val]),
    Res;
encode({datetime, Val}, AsBinary) ->
    encode(Val, AsBinary);
encode({{Year, Month, Day}, {Hour, Minute, Second}}, false) ->
    Res = two_digits([Year, Month, Day, Hour, Minute, Second]),
    lists:flatten(Res);
encode({TimeType, Val}, AsBinary)
  when TimeType == 'date';
       TimeType == 'time' ->
    encode(Val, AsBinary);
encode({Time1, Time2, Time3}, false) ->
    Res = two_digits([Time1, Time2, Time3]),
    lists:flatten(Res);
encode(Val, _AsBinary) ->
    {error, {unrecognized_value, Val}}.

two_digits(Nums) when is_list(Nums) ->
    [two_digits(Num) || Num <- Nums];
two_digits(Num) ->
    [Str] = io_lib:format("~b", [Num]),
    case length(Str) of
        1 -> [$0 | Str];
        _ -> Str
    end.

%%  Quote a string or binary value so that it can be included safely in a
%%  MySQL query.
quote(String) when is_list(String) ->
    [39 | lists:reverse([39 | quote(String, [])])];	%% 39 is $'
quote(Bin) when is_binary(Bin) ->
    list_to_binary(quote(binary_to_list(Bin))).

quote([], Acc) ->
    Acc;
quote([0 | Rest], Acc) ->
    quote(Rest, [$0, $\\ | Acc]);
quote([10 | Rest], Acc) ->
    quote(Rest, [$n, $\\ | Acc]);
quote([13 | Rest], Acc) ->
    quote(Rest, [$r, $\\ | Acc]);
quote([$\\ | Rest], Acc) ->
    quote(Rest, [$\\ , $\\ | Acc]);
quote([39 | Rest], Acc) ->		%% 39 is $'
    quote(Rest, [39, $\\ | Acc]);	%% 39 is $'
quote([34 | Rest], Acc) ->		%% 34 is $"
    quote(Rest, [34, $\\ | Acc]);	%% 34 is $"
quote([26 | Rest], Acc) ->
    quote(Rest, [$Z, $\\ | Acc]);
quote([C | Rest], Acc) ->
    quote(Rest, [C | Acc]).


%% @doc Find the first zero-byte in Data and add everything before it
%%   to Acc, as a string.
%%
%% @spec asciz_binary(Data::binary(), Acc::list()) ->
%%   {NewList::list(), Rest::binary()}
asciz_binary(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
asciz_binary(<<0:8, Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
asciz_binary(<<C:8, Rest/binary>>, Acc) ->
    asciz_binary(Rest, [C | Acc]).
