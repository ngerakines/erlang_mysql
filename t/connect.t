#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa ./ebin -boot start_sasl

main(_) ->
    etap:plan(unknown),
    {Host, User, Pass, Name} = {"localhost", "test", "test", "testdatabase"},
    {ok, Pid} = mysql:start_link(test1, Host, 3306, User, Pass, Name, 'utf8'),
    etap:ok(is_process_alive(Pid), "MySQL gen_server running"),
    etap:end_tests().
