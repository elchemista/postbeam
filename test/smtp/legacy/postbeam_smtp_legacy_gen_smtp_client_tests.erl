%%% Copyright 2009 Andrew Thompson <andrew@hijacked.us>. All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%
%%%   1. Redistributions of source code must retain the above copyright notice,
%%%      this list of conditions and the following disclaimer.
%%%   2. Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE FREEBSD PROJECT ``AS IS'' AND ANY EXPRESS OR
%%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
%%% EVENT SHALL THE FREEBSD PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
%%% INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
%%% (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
%%% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

%% @doc A simple SMTP client used for sending mail - assumes relaying via a
%% smarthost.

-module(postbeam_smtp_legacy_gen_smtp_client_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").
-record(smtp_client_socket,{socket :: 'Elixir.Postbeam.SMTP.Socket':socket(),
                            host :: string(),
                            extensions :: list(),
                            options :: list()}).
-define(DEFAULT_OPTIONS, [
    % whether to connect on 465 in ssl mode
    {ssl, false},
    % always, never, if_available
    {tls, if_available},
    % used in ssl:connect, http://erlang.org/doc/man/ssl.html
    {tls_options, [{versions, ['tlsv1', 'tlsv1.1', 'tlsv1.2']}]},
    {auth, if_available},
    {hostname, 'Elixir.Postbeam.SMTP.Util':guess_FQDN()},
    % how many retries per smtp host on temporary failure
    {retries, 1},
    {on_transaction_error, quit},
    % smtp, lmtp
    {protocol, smtp}
]).
-define(AUTH_PREFERENCE, [
    "CRAM-MD5",
    "LOGIN",
    "PLAIN",
    "XOAUTH2"
]).
-define(TIMEOUT, 1200000).
close(A1) -> 'Elixir.Postbeam.SMTP.Client':close(A1).
deliver(A1, A2) -> 'Elixir.Postbeam.SMTP.Client':deliver(A1, A2).
open(A1) -> 'Elixir.Postbeam.SMTP.Client':open(test_tls_options(A1)).
parse_extensions(A1, A2) -> 'Elixir.Postbeam.SMTP.Client':parse_extensions(A1, A2).
send(A1, A2) -> 'Elixir.Postbeam.SMTP.Client':send(A1, test_tls_options(A2)).
send(A1, A2, A3) -> 'Elixir.Postbeam.SMTP.Client':send(A1, test_tls_options(A2), A3).


session_start_test_() ->
    {foreach, local,
        fun() ->
            {ok, ListenSock} = 'Elixir.Postbeam.SMTP.Socket':listen(tcp, 9876),
            {ListenSock}
        end,
        fun({ListenSock}) ->
            'Elixir.Postbeam.SMTP.Socket':close(ListenSock)
        end,
        [
            fun({ListenSock}) ->
                {"simple session initiation", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"retry on crashed EHLO twice if requested", fun() ->
                    Options = [
                        {relay, "localhost"}, {port, 9876}, {hostname, "testing"}, {retries, 2}
                    ],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(X),
                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(Y),
                    {ok, Z} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(Z, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Z, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"retry on crashed EHLO", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    unlink(Pid),
                    Monitor = erlang:monitor(process, Pid),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(X),
                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(Y),
                    ?assertEqual({error, timeout}, 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000)),
                    receive
                        {'DOWN', Monitor, _, _, Error} ->
                            ?assertMatch({error, retries_exceeded, _}, Error)
                    end,
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"abort on 554 greeting", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    unlink(Pid),
                    Monitor = erlang:monitor(process, Pid),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "554 get lost, kid\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    receive
                        {'DOWN', Monitor, _, _, Error} ->
                            ?assertMatch({error, no_more_hosts, _}, Error)
                    end,
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"retry on 421 greeting", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "421 can't you see I'm busy?\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"retry on messed up EHLO response", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    unlink(Pid),
                    Monitor = erlang:monitor(process, Pid),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(
                        X, "250-server.example.com EHLO\r\n250-AUTH LOGIN PLAIN\r\n421 too busy\r\n"
                    ),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),

                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(
                        Y, "250-server.example.com EHLO\r\n250-AUTH LOGIN PLAIN\r\n421 too busy\r\n"
                    ),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    receive
                        {'DOWN', Monitor, _, _, Error} ->
                            ?assertMatch({error, retries_exceeded, _}, Error)
                    end,
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"retry with HELO when EHLO not accepted", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 \r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "500 5.3.3 Unrecognized command\r\n"),
                    ?assertMatch({ok, "HELO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 Some banner\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"use LHLO for LMTP connections", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}, {protocol, lmtp}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 \r\n"),
                    ?assertMatch({ok, "LHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 Some banner\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"handle single responses from DATA on LMTP connections", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}, {protocol, lmtp}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 \r\n"),
                    ?assertMatch({ok, "LHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 Some banner\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"handle multiple successful responses from DATA on LMTP connections", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}, {protocol, lmtp}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com", "bar@foo.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 \r\n"),
                    ?assertMatch({ok, "LHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 Some banner\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<bar@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"handle mixed responses from DATA on LMTP connections #1", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}, {protocol, lmtp}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com", "bar@foo.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 \r\n"),
                    ?assertMatch({ok, "LHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 Some banner\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<bar@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n452 <bar@foo.com> is temporarily over quota\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"handle mixed responses from DATA on LMTP connections #2", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}, {protocol, lmtp}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com", "bar@foo.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 \r\n"),
                    ?assertMatch({ok, "LHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 Some banner\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<bar@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "452 <bar@foo.com> is temporarily over quota\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"a valid complete transaction without TLS advertised should succeed", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 hostname\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"a valid complete transaction exercising period escaping", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], ".hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 hostname\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "..hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"a valid complete transaction with binary arguments should succeed", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, "testing"}],
                    {ok, _Pid} = send(
                        {<<"test@foo.com">>, [<<"foo@bar.com">>], <<"hello world">>}, Options
                    ),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 hostname\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"a valid complete transaction with TLS advertised should succeed", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, <<"testing">>}],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 STARTTLS\r\n"),
                    ?assertMatch({ok, "STARTTLS\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    application:ensure_all_started(postbeam),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 ok\r\n"),
                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':to_ssl_server(
                        X,
                        [
                            {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"},
                            {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"}
                        ],
                        5000
                    ),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250-hostname\r\n250 STARTTLS\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"a valid complete transaction with TLS advertised and binary arguments should succeed", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, <<"testing">>}],
                    {ok, _Pid} = send(
                        {<<"test@foo.com">>, [<<"foo@bar.com">>], <<"hello world">>}, Options
                    ),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 STARTTLS\r\n"),
                    ?assertMatch({ok, "STARTTLS\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    application:ensure_all_started(postbeam),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 ok\r\n"),
                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':to_ssl_server(
                        X,
                        [
                            {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"},
                            {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"}
                        ],
                        5000
                    ),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250-hostname\r\n250 STARTTLS\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch(
                        {ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"Transaction with TLS advertised, but broken, should be restarted without TLS, if allowed", fun() ->
                    Options = [
                        {relay, "localhost"},
                        {port, 9876},
                        {hostname, <<"testing">>},
                        {tls, if_available}
                    ],
                    {ok, _Pid} = send(
                        {<<"test@foo.com">>, [<<"foo@bar.com">>], <<"hello world">>}, Options
                    ),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 STARTTLS\r\n"),
                    ?assertMatch({ok, "STARTTLS\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 ok\r\n"),
                    %% Now, send some invalid data instead of TLS handshake and close the socket
                    {ok, [22, V1, V2 | _]} = 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, [22, V1, V2, 0, 0]),
                    'Elixir.Postbeam.SMTP.Socket':close(X),
                    %% Client would make another attempt to connect, without TLS
                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250-hostname\r\n250 STARTTLS\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch(
                        {ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"Send with callback", fun() ->
                    Options = [{relay, "localhost"}, {port, 9876}, {hostname, <<"testing">>}],
                    Self = self(),
                    Ref = make_ref(),
                    Callback = fun(Arg) -> Self ! {callback, Ref, Arg} end,
                    {ok, _Pid1} = send(
                        {<<"test@foo.com">>, [<<"foo@bar.com">>], <<"hello world">>},
                        Options,
                        Callback
                    ),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 hostname\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch(
                        {ok, <<"ok\r\n">>},
                        receive
                            {callback, Ref, CbRet1} -> CbRet1
                        end
                    ),
                    {ok, _Pid2} = send(
                        {<<"test@foo.com">>, [<<"foo@bar.com">>], <<"hello world">>},
                        Options,
                        Callback
                    ),
                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 hostname\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "599 error\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ?assertMatch(
                        {error, send, {permanent_failure, _, <<"599 error\r\n">>}},
                        receive
                            {callback, Ref, CbRet2} -> CbRet2
                        end
                    ),
                    ok
                end}
            end,

            fun({ListenSock}) ->
                {"Deliver with RSET on transaction error", fun() ->
                    Self = self(),
                    Pid = spawn_link(fun() ->
                        EMail = {"test@foo.com", ["foo@bar.com"], "hello world"},
                        Options = [
                            {relay, "localhost"},
                            {port, 9876},
                            {hostname, "testing"},
                            {on_transaction_error, reset}
                        ],
                        {ok, X} = open(Options),
                        LoopFn = fun Loop() ->
                            receive
                                {Self, deliver, Exp} ->
                                    ?assertMatch({Exp, _}, deliver(X, EMail)),
                                    Loop();
                                {Self, stop} ->
                                    close(X),
                                    ok
                            end
                        end,
                        LoopFn(),
                        unlink(Self)
                    end),
                    {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "220 Some Banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 hostname\r\n"),

                    Pid ! {self(), deliver, error},
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "599 Error\r\n"),
                    ?assertMatch({ok, "RSET\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),

                    Pid ! {self(), deliver, error},
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "599 Error\r\n"),
                    ?assertMatch({ok, "RSET\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),

                    Pid ! {self(), deliver, error},
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "599 Error\r\n"),
                    ?assertMatch({ok, "RSET\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),

                    Pid ! {self(), deliver, error},
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "354 Continue\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "599 Error\r\n"),

                    Pid ! {self(), deliver, ok},
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "354 Continue\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y, "250 Ok\r\n"),

                    Pid ! {self(), stop},
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(Y),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"Deliver with QUIT on transaction error", fun() ->
                    Self = self(),
                    Pid = spawn_link(fun() ->
                        EMail = {"test@foo.com", ["foo@bar.com"], "hello world"},
                        Options = [
                            {relay, "localhost"},
                            {port, 9876},
                            {hostname, "testing"},
                            {on_transaction_error, quit}
                        ],
                        LoopFn = fun Loop(LastSock) ->
                            receive
                                {Self, deliver, Exp} ->
                                    {ok, X} = open(Options),
                                    ?assertMatch({Exp, _}, deliver(X, EMail)),
                                    Loop(X);
                                {Self, stop} ->
                                    catch close(LastSock),
                                    ok
                            end
                        end,
                        LoopFn(undefined),
                        unlink(Self)
                    end),
                    SessionInitFn = fun() ->
                        {ok, Y} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                        'Elixir.Postbeam.SMTP.Socket':send(Y, "220 Some Banner\r\n"),
                        ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y, 0, 1000)),
                        'Elixir.Postbeam.SMTP.Socket':send(Y, "250 hostname\r\n"),
                        Y
                    end,

                    Pid ! {self(), deliver, error},
                    Y1 = SessionInitFn(),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y1, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y1, "599 Error\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y1, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(Y1),

                    Pid ! {self(), deliver, error},
                    Y2 = SessionInitFn(),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y2, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y2, "250 Ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y2, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y2, "599 Error\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y2, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(Y2),

                    Pid ! {self(), deliver, error},
                    Y3 = SessionInitFn(),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y3, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y3, "250 Ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y3, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y3, "250 Ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y3, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y3, "599 Error\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y3, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(Y3),

                    Pid ! {self(), deliver, error},
                    Y4 = SessionInitFn(),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y4, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y4, "250 Ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y4, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y4, "250 Ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y4, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y4, "354 Continue\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y4, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y4, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y4, "599 Error\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y4, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(Y4),

                    Pid ! {self(), deliver, ok},
                    Y5 = SessionInitFn(),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y5, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(Y5, "250 Ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y5, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y5, "250 Ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y5, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y5, "354 Continue\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y5, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y5, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(Y5, "250 Ok\r\n"),

                    Pid ! {self(), stop},
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(Y5, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(Y5),
                    ok
                end}
            end,

            fun({ListenSock}) ->
                {"AUTH PLAIN should work", fun() ->
                    Options = [
                        {relay, "localhost"},
                        {port, 9876},
                        {hostname, "testing"},
                        {username, "user"},
                        {password, "pass"}
                    ],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 AUTH PLAIN\r\n"),
                    AuthString = binary_to_list(base64:encode("\0user\0pass")),
                    AuthPacket = "AUTH PLAIN " ++ AuthString ++ "\r\n",
                    ?assertEqual({ok, AuthPacket}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "235 ok\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"AUTH LOGIN should work", fun() ->
                    Options = [
                        {relay, "localhost"},
                        {port, 9876},
                        {hostname, "testing"},
                        {username, "user"},
                        {password, "pass"}
                    ],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 AUTH LOGIN\r\n"),
                    ?assertEqual({ok, "AUTH LOGIN\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "334 VXNlcm5hbWU6\r\n"),
                    UserString = binary_to_list(base64:encode("user")),
                    ?assertEqual({ok, UserString ++ "\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "334 UGFzc3dvcmQ6\r\n"),
                    PassString = binary_to_list(base64:encode("pass")),
                    ?assertEqual({ok, PassString ++ "\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "235 ok\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"AUTH LOGIN should work with lowercase prompts", fun() ->
                    Options = [
                        {relay, "localhost"},
                        {port, 9876},
                        {hostname, "testing"},
                        {username, "user"},
                        {password, "pass"}
                    ],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 AUTH LOGIN\r\n"),
                    ?assertEqual({ok, "AUTH LOGIN\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "334 dXNlcm5hbWU6\r\n"),
                    UserString = binary_to_list(base64:encode("user")),
                    ?assertEqual({ok, UserString ++ "\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "334 cGFzc3dvcmQ6\r\n"),
                    PassString = binary_to_list(base64:encode("pass")),
                    ?assertEqual({ok, PassString ++ "\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "235 ok\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"AUTH LOGIN should work with appended methods", fun() ->
                    Options = [
                        {relay, "localhost"},
                        {port, 9876},
                        {hostname, "testing"},
                        {username, "user"},
                        {password, "pass"}
                    ],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 AUTH LOGIN\r\n"),
                    ?assertEqual({ok, "AUTH LOGIN\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "334 VXNlcm5hbWU6 R6S4yT8pcW5sQjZD3CW61N0 - hssmtp\r\n"),
                    UserString = binary_to_list(base64:encode("user")),
                    ?assertEqual({ok, UserString ++ "\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "334 UGFzc3dvcmQ6 R6S4yT8pcW5sQjZD3CW61N0 - hssmtp\r\n"),
                    PassString = binary_to_list(base64:encode("pass")),
                    ?assertEqual({ok, PassString ++ "\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "235 ok\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"AUTH CRAM-MD5 should work", fun() ->
                    Options = [
                        {relay, "localhost"},
                        {port, 9876},
                        {hostname, "testing"},
                        {username, "user"},
                        {password, "pass"}
                    ],
                    {ok, _Pid} = send({"test@foo.com", ["foo@bar.com"], "hello world"}, Options),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 AUTH CRAM-MD5\r\n"),
                    ?assertEqual({ok, "AUTH CRAM-MD5\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    Seed = 'Elixir.Postbeam.SMTP.Util':get_cram_string('Elixir.Postbeam.SMTP.Util':guess_FQDN()),
                    DecodedSeed = base64:decode_to_string(Seed),
                    Digest = 'Elixir.Postbeam.SMTP.Util':compute_cram_digest("pass", DecodedSeed),
                    String = binary_to_list(base64:encode(list_to_binary(["user ", Digest]))),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "334 " ++ Seed ++ "\r\n"),
                    {ok, Packet} = 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000),
                    CramDigest = 'Elixir.Postbeam.SMTP.Util':trim_crlf(Packet),
                    ?assertEqual(String, CramDigest),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "235 ok\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"AUTH CRAM-MD5 should work", fun() ->
                    Options = [
                        {relay, <<"localhost">>},
                        {port, 9876},
                        {hostname, <<"testing">>},
                        {username, <<"user">>},
                        {password, <<"pass">>}
                    ],
                    {ok, _Pid} = send(
                        {<<"test@foo.com">>, [<<"foo@bar.com">>, <<"baz@bar.com">>], <<"hello world">>},
                        Options
                    ),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 AUTH CRAM-MD5\r\n"),
                    ?assertEqual({ok, "AUTH CRAM-MD5\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    Seed = 'Elixir.Postbeam.SMTP.Util':get_cram_string('Elixir.Postbeam.SMTP.Util':guess_FQDN()),
                    DecodedSeed = base64:decode_to_string(Seed),
                    Digest = 'Elixir.Postbeam.SMTP.Util':compute_cram_digest("pass", DecodedSeed),
                    String = binary_to_list(base64:encode(list_to_binary(["user ", Digest]))),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "334 " ++ Seed ++ "\r\n"),
                    {ok, Packet} = 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000),
                    CramDigest = 'Elixir.Postbeam.SMTP.Util':trim_crlf(Packet),
                    ?assertEqual(String, CramDigest),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "235 ok\r\n"),
                    ?assertMatch(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"should bail when AUTH is required but not provided", fun() ->
                    Options = [
                        {relay, <<"localhost">>},
                        {port, 9876},
                        {hostname, <<"testing">>},
                        {auth, always},
                        {username, <<"user">>},
                        {retries, 0},
                        {password, <<"pass">>}
                    ],
                    {ok, Pid} = send(
                        {<<"test@foo.com">>, [<<"foo@bar.com">>, <<"baz@bar.com">>], <<"hello world">>},
                        Options
                    ),
                    unlink(Pid),
                    Monitor = erlang:monitor(process, Pid),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 8BITMIME\r\n"),
                    ?assertEqual({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    receive
                        {'DOWN', Monitor, _, _, Error} ->
                            ?assertMatch(
                                {error, retries_exceeded, {missing_requirement, _, auth}}, Error
                            )
                    end,
                    ok
                end}
            end,
            fun({ListenSock}) ->
                {"should bail when AUTH is required but of an unsupported type", fun() ->
                    Options = [
                        {relay, <<"localhost">>},
                        {port, 9876},
                        {hostname, <<"testing">>},
                        {auth, always},
                        {username, <<"user">>},
                        {retries, 0},
                        {password, <<"pass">>}
                    ],
                    {ok, Pid} = send(
                        {<<"test@foo.com">>, [<<"foo@bar.com">>, <<"baz@bar.com">>], <<"hello world">>},
                        Options
                    ),
                    unlink(Pid),
                    Monitor = erlang:monitor(process, Pid),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250-AUTH GSSAPI\r\n250 8BITMIME\r\n"),
                    ?assertEqual({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    receive
                        {'DOWN', Monitor, _, _, Error} ->
                            ?assertMatch(
                                {error, no_more_hosts, {permanent_failure, _, auth_failed}}, Error
                            )
                    end,
                    ok
                end}
            end,
            fun({_ListenSock}) ->
                {"Connecting to a SSL socket directly should work", fun() ->
                    application:ensure_all_started(postbeam),
                    {ok, ListenSock} = 'Elixir.Postbeam.SMTP.Socket':listen(ssl, 9877, [
                        {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"},
                        {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"}
                    ]),
                    Options = [
                        {relay, <<"localhost">>},
                        {port, 9877},
                        {hostname, <<"testing">>},
                        {ssl, true}
                    ],
                    {ok, _Pid} = send(
                        {<<"test@foo.com">>, [<<"<foo@bar.com>">>, <<"baz@bar.com">>], <<"hello world">>},
                        Options
                    ),
                    {ok, X} = 'Elixir.Postbeam.SMTP.Socket':accept(ListenSock, 1000),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "220 Some banner\r\n"),
                    ?assertMatch({ok, "EHLO testing\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250-hostname\r\n250 AUTH CRAM-MD5\r\n"),
                    ?assertEqual(
                        {ok, "MAIL FROM:<test@foo.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<foo@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "RCPT TO:<baz@bar.com>\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "DATA\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "354 ok\r\n"),
                    ?assertMatch({ok, "hello world\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    ?assertMatch({ok, ".\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':send(X, "250 ok\r\n"),
                    ?assertMatch({ok, "QUIT\r\n"}, 'Elixir.Postbeam.SMTP.Socket':recv(X, 0, 1000)),
                    'Elixir.Postbeam.SMTP.Socket':close(ListenSock),
                    ok
                end}
            end
        ]}.

extension_parse_test_() ->
    [
        {"parse extensions", fun() ->
            Res = parse_extensions(
                <<"250-smtp.example.com\r\n250-PIPELINING\r\n250-SIZE 20971520\r\n250-VRFY\r\n250-ETRN\r\n250-STARTTLS\r\n250-AUTH CRAM-MD5 PLAIN DIGEST-MD5 LOGIN\r\n250-AUTH=CRAM-MD5 PLAIN DIGEST-MD5 LOGIN\r\n250-ENHANCEDSTATUSCODES\r\n250-8BITMIME\r\n250 DSN">>,
                []
            ),
            ?assertEqual(true, proplists:get_value(<<"PIPELINING">>, Res)),
            ?assertEqual(<<"20971520">>, proplists:get_value(<<"SIZE">>, Res)),
            ?assertEqual(true, proplists:get_value(<<"VRFY">>, Res)),
            ?assertEqual(true, proplists:get_value(<<"ETRN">>, Res)),
            ?assertEqual(true, proplists:get_value(<<"STARTTLS">>, Res)),
            ?assertEqual(
                <<"CRAM-MD5 PLAIN DIGEST-MD5 LOGIN">>, proplists:get_value(<<"AUTH">>, Res)
            ),
            ?assertEqual(true, proplists:get_value(<<"ENHANCEDSTATUSCODES">>, Res)),
            ?assertEqual(true, proplists:get_value(<<"8BITMIME">>, Res)),
            ?assertEqual(true, proplists:get_value(<<"DSN">>, Res)),
            ?assertEqual(10, length(Res)),
            ok
        end}
    ].


% Fixtures use a private CA; certificate verification is covered by the TLS integration tests.
test_tls_options(Opts) ->
  TLS = [{tls_options, [{verify, verify_none}]} | Opts],
  case proplists:get_value(ssl, Opts, false) of
    true -> [{sockopts, [binary, {packet, line}, {active, false}, {verify, verify_none}]} | TLS];
    false -> TLS
  end.
