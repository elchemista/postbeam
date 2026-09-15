%%% Copyright 2009 Jack Danger Canty <code@jackcanty.com>. All rights reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining
%%% a copy of this software and associated documentation files (the
%%% "Software"), to deal in the Software without restriction, including
%%% without limitation the rights to use, copy, modify, merge, publish,
%%% distribute, sublicense, and/or sell copies of the Software, and to
%%% permit persons to whom the Software is furnished to do so, subject to
%%% the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be
%%% included in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
%%% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
%%% LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
%%% OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
%%% WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

%% @doc Facilitates transparent gen_tcp/ssl socket handling
-module(postbeam_smtp_legacy_smtp_socket_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").
-define(TCP_LISTEN_OPTIONS, [
    {active, false},
    {backlog, 30},
    {ip, {0, 0, 0, 0}},
    {keepalive, true},
    {packet, line},
    {reuseaddr, true}
]).
-define(TCP_CONNECT_OPTIONS, [
    {active, false},
    {packet, line},
    {ip, {0, 0, 0, 0}},
    {port, 0}
]).
-define(SSL_LISTEN_OPTIONS, [
    {active, false},
    {backlog, 30},
    {certfile, "server.crt"},
    {depth, 0},
    {keepalive, true},
    {keyfile, "server.key"},
    {packet, line},
    {reuse_sessions, false},
    {reuseaddr, true}
]).
-define(SSL_CONNECT_OPTIONS, [
    {active, false},
    {depth, 0},
    {packet, line},
    {ip, {0, 0, 0, 0}},
    {port, 0}
]).
accept(A1) -> 'Elixir.Postbeam.SMTP.Socket':accept(A1).
active_once(A1) -> 'Elixir.Postbeam.SMTP.Socket':active_once(A1).
begin_inet_async(A1) -> 'Elixir.Postbeam.SMTP.Socket':begin_inet_async(A1).
close(A1) -> 'Elixir.Postbeam.SMTP.Socket':close(A1).
connect(ssl, A2, A3) -> 'Elixir.Postbeam.SMTP.Socket':connect(ssl, A2, A3, [{verify, verify_none}]);
connect(A1, A2, A3) -> 'Elixir.Postbeam.SMTP.Socket':connect(A1, A2, A3).
connect(ssl, A2, A3, A4) -> 'Elixir.Postbeam.SMTP.Socket':connect(ssl, A2, A3, [{verify, verify_none}|A4]);
connect(A1, A2, A3, A4) -> 'Elixir.Postbeam.SMTP.Socket':connect(A1, A2, A3, A4).
controlling_process(A1, A2) -> 'Elixir.Postbeam.SMTP.Socket':controlling_process(A1, A2).
handle_inet_async(A1, A2) -> 'Elixir.Postbeam.SMTP.Socket':handle_inet_async(A1, A2).
handle_inet_async(A1, A2, A3) -> 'Elixir.Postbeam.SMTP.Socket':handle_inet_async(A1, A2, A3).
listen(A1, A2) -> 'Elixir.Postbeam.SMTP.Socket':listen(A1, A2).
listen(A1, A2, A3) -> 'Elixir.Postbeam.SMTP.Socket':listen(A1, A2, A3).
ssl_connect_options(A1) -> 'Elixir.Postbeam.SMTP.Socket':ssl_connect_options(A1).
ssl_listen_options(A1) -> 'Elixir.Postbeam.SMTP.Socket':ssl_listen_options(A1).
tcp_connect_options(A1) -> 'Elixir.Postbeam.SMTP.Socket':tcp_connect_options(A1).
tcp_listen_options(A1) -> 'Elixir.Postbeam.SMTP.Socket':tcp_listen_options(A1).
to_ssl_client(A1) -> 'Elixir.Postbeam.SMTP.Socket':to_ssl_client(A1, [{verify, verify_none}]).
to_ssl_server(A1) -> 'Elixir.Postbeam.SMTP.Socket':to_ssl_server(A1).
to_ssl_server(A1, A2) -> 'Elixir.Postbeam.SMTP.Socket':to_ssl_server(A1, A2).
type(A1) -> 'Elixir.Postbeam.SMTP.Socket':type(A1).

-define(TEST_PORT, 7586).

connect_test_() ->
    [
        {"listen and connect via tcp", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 1,
            Ref = make_ref(),
            spawn(fun() ->
                {ok, ListenSocket} = listen(tcp, Port),
                ?assert(is_port(ListenSocket)),
                Self ! {Ref, listen},
                {ok, ServerSocket} = accept(ListenSocket),
                controlling_process(ServerSocket, Self),
                Self ! {Ref, ListenSocket}
            end),
            receive
                {Ref, listen} -> ok
            end,
            {ok, ClientSocket} = connect(tcp, "localhost", Port),
            receive
                {Ref, ListenSocket} when is_port(ListenSocket) -> ok
            end,
            ?assert(is_port(ClientSocket)),
            close(ListenSocket)
        end},
        {"listen and connect via ssl", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 2,
            Ref = make_ref(),
            application:ensure_all_started(postbeam),
            spawn(fun() ->
                {ok, ListenSocket} = listen(ssl, Port, [
                    {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                    {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
                ]),
                ?assertMatch([sslsocket | _], tuple_to_list(ListenSocket)),
                Self ! {Ref, listen},
                {ok, ServerSocket} = accept(ListenSocket),
                controlling_process(ServerSocket, Self),
                Self ! {Ref, ListenSocket}
            end),
            receive
                {Ref, listen} -> ok
            end,
            {ok, ClientSocket} = connect(ssl, "localhost", Port, []),
            receive
                {Ref, ListenSocket} when element(1, ListenSocket) =:= sslsocket -> ok
            end,
            ?assertMatch([sslsocket | _], tuple_to_list(ClientSocket)),
            close(ListenSocket)
        end}
    ].

evented_connections_test_() ->
    [
        {"current process receives connection to TCP listen sockets", fun() ->
            Port = ?TEST_PORT + 3,
            {ok, ListenSocket} = listen(tcp, Port),
            begin_inet_async(ListenSocket),
            spawn(fun() -> connect(tcp, "localhost", Port) end),
            receive
                {inet_async, ListenSocket, _, {ok, ServerSocket}} -> ok
            end,
            {ok, NewServerSocket} = handle_inet_async(ListenSocket, ServerSocket),
            ?assert(is_port(ServerSocket)),
            %% only true for TCP
            ?assertEqual(ServerSocket, NewServerSocket),
            ?assert(is_port(ListenSocket)),
            % Stop the async
            spawn(fun() -> connect(tcp, "localhost", Port) end),
            receive
                _Ignored -> ok
            end,
            close(NewServerSocket),
            close(ListenSocket)
        end},
        {"current process receives connection to SSL listen sockets", fun() ->
            Port = ?TEST_PORT + 4,
            application:ensure_all_started(postbeam),
            {ok, ListenSocket} = listen(ssl, Port, [
                {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
            ]),
            begin_inet_async(ListenSocket),
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            receive
                {inet_async, _ListenPort, _, {ok, ServerSocket}} -> ok
            end,
            {ok, NewServerSocket} = handle_inet_async(ListenSocket, ServerSocket, [
                {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
            ]),
            ?assertMatch([sslsocket | _], tuple_to_list(ServerSocket)),
            ?assertMatch([sslsocket | _], tuple_to_list(NewServerSocket)),
            ?assertMatch([sslsocket | _], tuple_to_list(ListenSocket)),
            %Stop the async
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            receive
                _Ignored -> ok
            end,
            close(ListenSocket),
            close(NewServerSocket),
            ok
        end},
        %% TODO: figure out if the following passes because
        %% of an incomplete test case or if this really is
        %% a magical feature where a single listener
        %% can respond to either ssl or tcp connections.
        {"current TCP listener receives SSL connection", fun() ->
            Port = ?TEST_PORT + 5,
            application:ensure_all_started(postbeam),
            {ok, ListenSocket} = listen(tcp, Port),
            begin_inet_async(ListenSocket),
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            ServerSocket =
                receive
                    {inet_async, _ListenPort, _, {ok, ServerSocket0}} -> ServerSocket0
                end,
            ?assertMatch({ok, ServerSocket}, handle_inet_async(ListenSocket, ServerSocket)),
            ?assert(is_port(ListenSocket)),
            ?assert(is_port(ServerSocket)),
            {ok, NewServerSocket} = to_ssl_server(ServerSocket, [
                {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"},
                {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"}
            ]),
            ?assertMatch([sslsocket | _], tuple_to_list(NewServerSocket)),
            % Stop the async
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            receive
                _Ignored -> ok
            end,
            close(ListenSocket),
            close(NewServerSocket)
        end}
    ].

accept_test_() ->
    [
        {"Accept via tcp", fun() ->
            Port = ?TEST_PORT + 6,
            {ok, ListenSocket} = listen(tcp, Port, tcp_listen_options([])),
            ?assert(is_port(ListenSocket)),
            spawn(fun() -> connect(ssl, "localhost", Port, tcp_connect_options([])) end),
            {ok, ServerSocket} = accept(ListenSocket),
            ?assert(is_port(ListenSocket)),
            close(ServerSocket),
            close(ListenSocket)
        end},
        {"Accept via ssl", fun() ->
            Port = ?TEST_PORT + 7,
            application:ensure_all_started(postbeam),
            {ok, ListenSocket} = listen(ssl, Port, [
                {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
            ]),
            ?assertMatch([sslsocket | _], tuple_to_list(ListenSocket)),
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            accept(ListenSocket),
            close(ListenSocket)
        end}
    ].

type_test_() ->
    [
        {"a tcp socket returns 'tcp'", fun() ->
            {ok, ListenSocket} = listen(tcp, ?TEST_PORT + 8),
            ?assertMatch(tcp, type(ListenSocket)),
            close(ListenSocket)
        end},
        {"an ssl socket returns 'ssl'", fun() ->
            application:ensure_all_started(postbeam),
            {ok, ListenSocket} = listen(ssl, ?TEST_PORT + 9, [
                {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
            ]),
            ?assertMatch(ssl, type(ListenSocket)),
            close(ListenSocket)
        end}
    ].

active_once_test_() ->
    [
        {"socket is set to active:once on tcp", fun() ->
            {ok, ListenSocket} = listen(tcp, ?TEST_PORT + 10, tcp_listen_options([])),
            ?assertEqual({ok, [{active, false}]}, inet:getopts(ListenSocket, [active])),
            active_once(ListenSocket),
            ?assertEqual({ok, [{active, once}]}, inet:getopts(ListenSocket, [active])),
            close(ListenSocket)
        end},
        {"socket is set to active:once on ssl", fun() ->
            {ok, ListenSocket} = listen(
                ssl,
                ?TEST_PORT + 11,
                ssl_listen_options([
                    {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                    {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
                ])
            ),
            ?assertEqual({ok, [{active, false}]}, ssl:getopts(ListenSocket, [active])),
            active_once(ListenSocket),
            ?assertEqual({ok, [{active, once}]}, ssl:getopts(ListenSocket, [active])),
            close(ListenSocket)
        end}
    ].

option_test_() ->
    [
        {"tcp_listen_options has defaults", fun() ->
            ?assertEqual(
                lists:sort([list | ?TCP_LISTEN_OPTIONS]), lists:sort(tcp_listen_options([]))
            )
        end},
        {"tcp_connect_options has defaults", fun() ->
            ?assertEqual(
                lists:sort([list | ?TCP_CONNECT_OPTIONS]), lists:sort(tcp_connect_options([]))
            )
        end},
        {"ssl_listen_options has defaults", fun() ->
            ?assertEqual(
                lists:sort([list | ?SSL_LISTEN_OPTIONS]), lists:sort(ssl_listen_options([]))
            )
        end},
        {"ssl_connect_options has defaults", fun() ->
            ?assertEqual(
                lists:sort([list | ?SSL_CONNECT_OPTIONS]), lists:sort(ssl_connect_options([]))
            )
        end},
        {"tcp_listen_options defaults to list type", fun() ->
            ?assertEqual(
                lists:sort([list | ?TCP_LISTEN_OPTIONS]),
                lists:sort(tcp_listen_options([{active, false}]))
            ),
            ?assertEqual(
                lists:sort([binary | ?TCP_LISTEN_OPTIONS]),
                lists:sort(tcp_listen_options([binary, {active, false}]))
            )
        end},
        {"tcp_connect_options defaults to list type", fun() ->
            ?assertEqual(
                lists:sort([list | ?TCP_CONNECT_OPTIONS]),
                lists:sort(tcp_connect_options([{active, false}]))
            ),
            ?assertEqual(
                lists:sort([binary | ?TCP_CONNECT_OPTIONS]),
                lists:sort(tcp_connect_options([binary, {active, false}]))
            )
        end},
        {"ssl_listen_options defaults to list type", fun() ->
            ?assertEqual(
                lists:sort([list | ?SSL_LISTEN_OPTIONS]),
                lists:sort(ssl_listen_options([{active, false}]))
            ),
            ?assertEqual(
                lists:sort([binary | ?SSL_LISTEN_OPTIONS]),
                lists:sort(ssl_listen_options([binary, {active, false}]))
            )
        end},
        {"ssl_connect_options defaults to list type", fun() ->
            ?assertEqual(
                lists:sort([list | ?SSL_CONNECT_OPTIONS]),
                lists:sort(ssl_connect_options([{active, false}]))
            ),
            ?assertEqual(
                lists:sort([binary | ?SSL_CONNECT_OPTIONS]),
                lists:sort(ssl_connect_options([binary, {active, false}]))
            )
        end},
        {"tcp_listen_options merges provided proplist", fun() ->
            ?assertEqual(
                [
                    list
                    | lists:keysort(1, [
                        {active, true},
                        {backlog, 30},
                        {ip, {0, 0, 0, 0}},
                        {keepalive, true},
                        {packet, 2},
                        {reuseaddr, true}
                    ])
                ],
                tcp_listen_options([{active, true}, {packet, 2}])
            )
        end},
        {"tcp_connect_options merges provided proplist", fun() ->
            ?assertEqual(
                lists:sort([
                    list,
                    {active, true},
                    {packet, 2},
                    {ip, {0, 0, 0, 0}},
                    {port, 0}
                ]),
                lists:sort(tcp_connect_options([{active, true}, {packet, 2}]))
            )
        end},
        {"ssl_listen_options merges provided proplist", fun() ->
            ?assertEqual(
                [
                    list
                    | lists:keysort(1, [
                        {active, true},
                        {backlog, 30},
                        {certfile, "server.crt"},
                        {depth, 0},
                        {keepalive, true},
                        {keyfile, "server.key"},
                        {packet, 2},
                        {reuse_sessions, false},
                        {reuseaddr, true}
                    ])
                ],
                ssl_listen_options([{active, true}, {packet, 2}])
            ),
            ?assertEqual(
                [
                    list
                    | lists:keysort(1, [
                        {active, false},
                        {backlog, 30},
                        {certfile, "../server.crt"},
                        {depth, 0},
                        {keepalive, true},
                        {keyfile, "../server.key"},
                        {packet, line},
                        {reuse_sessions, false},
                        {reuseaddr, true}
                    ])
                ],
                ssl_listen_options([{certfile, "../server.crt"}, {keyfile, "../server.key"}])
            )
        end},
        {"ssl_connect_options merges provided proplist", fun() ->
            ?assertEqual(
                lists:sort([
                    list,
                    {active, true},
                    {depth, 0},
                    {ip, {0, 0, 0, 0}},
                    {port, 0},
                    {packet, 2}
                ]),
                lists:sort(ssl_connect_options([{active, true}, {packet, 2}]))
            )
        end}
    ].

ssl_upgrade_test_() ->
    [
        {"TCP connection can be upgraded to ssl", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 12,
            application:ensure_all_started(postbeam),
            spawn(fun() ->
                {ok, ListenSocket} = listen(tcp, Port),
                Self ! listening,
                {ok, ServerSocket} = accept(ListenSocket),
                {ok, NewServerSocket} = 'Elixir.Postbeam.SMTP.Socket':to_ssl_server(
                    ServerSocket,
                    [
                        {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                        {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
                    ]
                ),
                Self ! {sock, NewServerSocket}
            end),
            receive
                listening -> ok
            end,
            erlang:yield(),
            {ok, ClientSocket} = connect(tcp, "localhost", Port),
            ?assert(is_port(ClientSocket)),
            {ok, NewClientSocket} = to_ssl_client(ClientSocket),
            ?assertMatch([sslsocket | _], tuple_to_list(NewClientSocket)),
            receive
                {sock, NewServerSocket} -> ok
            end,
            ?assertEqual(sslsocket, element(1, NewServerSocket)),
            close(NewClientSocket),
            close(NewServerSocket)
        end},
        {"SSL server connection can't be upgraded again", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 13,
            application:ensure_all_started(postbeam),
            spawn(fun() ->
                {ok, ListenSocket} = listen(ssl, Port, [
                    {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                    {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
                ]),
                Self ! listening,
                {ok, ServerSocket} = accept(ListenSocket),
                ?assertMatch({error, already_ssl}, to_ssl_server(ServerSocket)),
                close(ServerSocket)
            end),
            receive
                listening -> ok
            end,
            erlang:yield(),
            {ok, ClientSocket} = connect(ssl, "localhost", Port),
            close(ClientSocket)
        end},
        {"SSL client connection can't be upgraded again", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 14,
            application:ensure_all_started(postbeam),
            spawn(fun() ->
                {ok, ListenSocket} = listen(ssl, Port, [
                    {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                    {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
                ]),
                Self ! listening,
                {ok, ServerSocket} = accept(ListenSocket),
                Self ! {sock, ServerSocket}
            end),
            receive
                listening -> ok
            end,
            erlang:yield(),
            {ok, ClientSocket} = connect(ssl, "localhost", Port),
            receive
                {sock, ServerSocket} -> ok
            end,
            ?assertMatch({error, already_ssl}, to_ssl_client(ClientSocket)),
            close(ClientSocket),
            close(ServerSocket)
        end}
    ].
