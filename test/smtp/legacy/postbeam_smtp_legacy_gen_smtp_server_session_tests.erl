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

%% @doc Process representing a SMTP session, extensible via a callback module. This
%% module is implemented as a behaviour that the callback module should
%% implement. To see the details of the required callback functions to provide,
%% please see `smtp_server_example'.
%% @see smtp_server_example

-module(postbeam_smtp_legacy_gen_smtp_server_session_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").
-record(envelope,{from :: binary() | undefined,
                  to = [] :: [binary()],
                  data = <<>> :: binary(),
                  expectedsize = 0 :: pos_integer() | 0,
                  auth = {<<>>, <<>>} :: {binary(), binary()},
                  flags = [] :: [smtputf8 | '8bitmime' | '7bit']}).
-record(state,{socket = error({undefined, socket}) :: port() | tuple(),
               module = error({undefined, module}) :: atom(),
               transport :: module(),
               ranch_ref :: ranch:ref(),
               envelope = undefined :: undefined | #envelope{},
               extensions = [] :: [{string(), string()}],
               maxsize = 10485760 :: pos_integer() | infinity,
               waitingauth = false :: false | plain | login | 'cram-md5',
               authdata :: undefined | binary(),
               readmessage = false :: boolean(),
               tls = false :: boolean(),
               callbackstate :: any(),
               protocol = smtp :: smtp | lmtp,
               options = [] :: [tuple()]}).
-record(pa,{quotes = false, ab = true, utf8 = false}).
-define(DEFAULT_MAXSIZE, 10485760).
-define(BUILTIN_EXTENSIONS, [
    {"SIZE", integer_to_list(?DEFAULT_MAXSIZE)},
    {"8BITMIME", true},
    {"PIPELINING", true},
    {"SMTPUTF8", true}
]).
-define(TIMEOUT, 180000).
-define(LOGGER_META, #{domain => [postbeam, server]}).
check_bare_crlf(A1, A2, A3, A4) -> 'Elixir.Postbeam.SMTP.Session.DataReader':check_bare_crlf(A1, A2, A3, A4).
parse_encoded_address(A1, A2) -> 'Elixir.Postbeam.SMTP.Session':parse_encoded_address(A1, A2).
parse_request(A1) -> 'Elixir.Postbeam.SMTP.Session':parse_request(A1).

parse_encoded_address_test_() ->
    [
        {"Valid addresses should parse", fun() ->
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"<God@heaven.af.mil>">>, false)
            ),
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"<\\God@heaven.af.mil>">>, false)
            ),
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"<\"God\"@heaven.af.mil>">>, false)
            ),
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<>>},
                parse_encoded_address(
                    <<"<@gateway.af.mil,@uucp.local:\"\\G\\o\\d\"@heaven.af.mil>">>, false
                )
            ),
            ?assertEqual(
                {<<"God2@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"<God2@heaven.af.mil>">>, false)
            ),
            ?assertEqual(
                {<<"God+extension@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"<God+extension@heaven.af.mil>">>, false)
            ),
            ?assertEqual(
                {<<"God~*$@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"<God~*$@heaven.af.mil>">>, false)
            ),
            ?assertEqual(
                {<<"God~!#$%^&*()_+123@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"<\"God~!#$%^&*()_+123\"@heaven.af.mil>">>, false)
            )
        end},
        {"Addresses that are sorta valid should parse", fun() ->
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"God@heaven.af.mil">>, false)
            ),
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<"God@heaven.af.mil ">>, false)
            ),
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<" God@heaven.af.mil ">>, false)
            ),
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<>>},
                parse_encoded_address(<<" <God@heaven.af.mil> ">>, false)
            )
        end},
        {"Addresses with UTF8 characters should parse only when allowed", fun() ->
            %% https://www.iana.org/domains/reserved
            ?assertEqual(
                {<<"испытание@пример.испытание"/utf8>>, <<>>},
                parse_encoded_address(<<"<испытание@пример.испытание>"/utf8>>, true)
            ),
            ?assertEqual(
                {<<"測試@例子.測試"/utf8>>, <<>>},
                parse_encoded_address(<<"<測試@例子.測試>"/utf8>>, true)
            ),
            ?assertEqual(
                {<<"испытание@пример.испытание"/utf8>>, <<"SIZE=100">>},
                parse_encoded_address(<<"<испытание@пример.испытание> SIZE=100"/utf8>>, true)
            ),
            ?assertEqual(
                {<<"test@пример.испытание"/utf8>>, <<>>},
                parse_encoded_address(<<"<test@пример.испытание>"/utf8>>, true)
            ),
            ?assertEqual(
                {<<"испытание!#¤½§´`<>@пример.испытание"/utf8>>, <<>>},
                parse_encoded_address(<<"<\"испытание!#¤½§´`<>\"@пример.испытание>"/utf8>>, true)
            ),
            ?assertEqual(
                error, parse_encoded_address(<<"<испытание@пример.испытание>"/utf8>>, false)
            )
        end},
        {"Addresses containing unescaped <> that aren't at start/end should fail", fun() ->
            ?assertEqual(error, parse_encoded_address(<<"<<">>, false)),
            ?assertEqual(error, parse_encoded_address(<<"<God<@heaven.af.mil>">>, false))
        end},
        {"Address that begins with < but doesn't end with a > should fail", fun() ->
            ?assertEqual(error, parse_encoded_address(<<"<God@heaven.af.mil">>, false)),
            ?assertEqual(error, parse_encoded_address(<<"<God@heaven.af.mil ">>, false))
        end},
        {"Address that begins without < but ends with a > should fail", fun() ->
            ?assertEqual(error, parse_encoded_address(<<"God@heaven.af.mil>">>, false))
        end},
        {"Address longer than 320 characters should fail", fun() ->
            MegaAddress = list_to_binary(
                lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++
                    lists:seq(97, 122) ++ lists:seq(97, 122) ++ "@" ++ lists:seq(97, 122) ++
                    lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++
                    lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122)
            ),
            ?assertEqual(error, parse_encoded_address(MegaAddress, false))
        end},
        {"Address with an invalid route should fail", fun() ->
            ?assertEqual(
                error, parse_encoded_address(<<"<@gateway.af.mil God@heaven.af.mil>">>, false)
            )
        end},
        {"Empty addresses should parse OK", fun() ->
            ?assertEqual({<<>>, <<>>}, parse_encoded_address(<<"<>">>, false)),
            ?assertEqual({<<>>, <<>>}, parse_encoded_address(<<" <> ">>, false))
        end},
        {"Completely empty addresses are an error", fun() ->
            ?assertEqual(error, parse_encoded_address(<<"">>, false)),
            ?assertEqual(error, parse_encoded_address(<<" ">>, false))
        end},
        {"addresses with trailing parameters should return the trailing parameters", fun() ->
            ?assertEqual(
                {<<"God@heaven.af.mil">>, <<"SIZE=100 BODY=8BITMIME">>},
                parse_encoded_address(<<"<God@heaven.af.mil> SIZE=100 BODY=8BITMIME">>, false)
            )
        end}
    ].

parse_request_test_() ->
    [
        {"Parsing normal SMTP requests", fun() ->
            ?assertEqual({<<"HELO">>, <<>>}, parse_request(<<"HELO\r\n">>)),
            ?assertEqual(
                {<<"EHLO">>, <<"hell.af.mil">>}, parse_request(<<"EHLO hell.af.mil\r\n">>)
            ),
            ?assertEqual(
                {<<"LHLO">>, <<"hell.af.mil">>}, parse_request(<<"LHLO hell.af.mil\r\n">>)
            ),
            ?assertEqual(
                {<<"MAIL">>, <<"FROM:God@heaven.af.mil">>},
                parse_request(<<"MAIL FROM:God@heaven.af.mil">>)
            )
        end},
        {"Verbs should be uppercased", fun() ->
            ?assertEqual({<<"HELO">>, <<"hell.af.mil">>}, parse_request(<<"helo hell.af.mil">>)),
            ?assertEqual({<<"RSET">>, <<>>}, parse_request(<<"rset\r\n">>))
        end},
        {"Leading and trailing spaces are removed", fun() ->
            ?assertEqual(
                {<<"HELO">>, <<"hell.af.mil">>}, parse_request(<<" helo   hell.af.mil           ">>)
            )
        end},
        {"Blank lines are blank", fun() ->
            ?assertEqual({<<>>, <<>>}, parse_request(<<"">>))
        end}
    ].

smtp_session_test_() ->
    {foreach, local,
        fun() ->
            application:ensure_all_started(postbeam),
            {ok, Pid} = 'Elixir.Postbeam.SMTP.Server':start(
                'Elixir.Postbeam.SMTP.Example',
                [
                    {domain, "localhost"},
                    {port, 9876}
                ]
            ),
            {ok, CSock} = 'Elixir.Postbeam.SMTP.Socket':connect(tcp, "localhost", 9876),
            {CSock, Pid}
        end,
        fun({CSock, _Pid}) ->
            'Elixir.Postbeam.SMTP.Server':stop('Elixir.Postbeam.SMTP.Server'),
            'Elixir.Postbeam.SMTP.Socket':close(CSock),
            timer:sleep(10)
        end,
        [
            fun({CSock, _Pid}) ->
                {"A new connection should get a banner", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> ok
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"A correct response to HELO", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "HELO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 localhost\r\n", Packet2)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"An error in response to an invalid HELO", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "HELO\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("501 Syntax: HELO hostname\r\n", Packet2)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"An error in response to an LHLO sent by SMTP", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "LHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch(
                        "500 Error: SMTP should send HELO or EHLO instead of LHLO\r\n", Packet2
                    )
                end}
            end,
            fun({CSock, _Pid}) ->
                {"A rejected HELO", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "HELO invalid\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("554 invalid hostname\r\n", Packet2)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"A rejected EHLO", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO invalid\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("554 invalid hostname\r\n", Packet2)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"EHLO response", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F) ->
                        receive
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F);
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                ok;
                            {tcp, CSock, _R} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(ok, Foo(Foo))
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Unsupported AUTH PLAIN", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F) ->
                        receive
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F);
                            {tcp, CSock, "250" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                ok;
                            {tcp, CSock, _R} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(ok, Foo(Foo)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH PLAIN\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("502 Error: AUTH not implemented\r\n", Packet4)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Sending DATA", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "HELO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 localhost\r\n", Packet2),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO:<user@otherhost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "DATA\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("354 " ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "Subject: tls message\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "To: <user@otherhost>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "From: <user@somehost.com>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "message body"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n.\r\n"),
                    receive
                        {tcp, CSock, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 queued as" ++ _, Packet6)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Sending with spaced MAIL FROM / RCPT TO", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "HELO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 localhost\r\n", Packet2),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM: <user@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "DATA\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("354 " ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "Subject: tls message\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "To: <user@otherhost>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "From: <user@somehost.com>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "message body"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n.\r\n"),
                    receive
                        {tcp, CSock, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 queued as" ++ _, Packet6)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Sending with UTF8 addresses and body", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    receive
                        {tcp, CSock, Packet31} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-SIZE" ++ _, Packet31),
                    receive
                        {tcp, CSock, Packet32} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-8BITMIME" ++ _, Packet32),
                    receive
                        {tcp, CSock, Packet33} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-PIPELINING" ++ _, Packet33),
                    receive
                        {tcp, CSock, Packet34} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 SMTPUTF8" ++ _, Packet34),
                    'Elixir.Postbeam.SMTP.Socket':send(
                        CSock, <<"MAIL FROM: <испытание@пример.испытание> SMTPUTF8\r\n"/utf8>>
                    ),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 sender Ok" ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, <<"RCPT TO: <測試@例子.測試>\r\n"/utf8>>),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 recipient Ok" ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "DATA\r\n"),
                    receive
                        {tcp, CSock, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("354 " ++ _, Packet6),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, <<"Subject: Я помню чудное мгновенье\r\n"/utf8>>),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, <<"To: <測試@例子.測試>\r\n"/utf8>>),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, <<"From: <испытание@пример.испытание>\r\n"/utf8>>),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, <<"Передо мной явилась ты"/utf8>>),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n.\r\n"),
                    receive
                        {tcp, CSock, Packet7} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 queued as" ++ _, Packet7)
                end}
            end,
            %			fun({CSock, _Pid}) ->
            %					{"Sending DATA with a bare newline",
            %						fun() ->
            %								smtp_socket:active_once(CSock),
            %								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("220 localhost"++_Stuff,  Packet),
            %								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
            %								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 localhost\r\n",  Packet2),
            %								smtp_socket:send(CSock, "MAIL FROM:<user@somehost.com>\r\n"),
            %								receive {tcp, CSock, Packet3} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 "++_, Packet3),
            %								smtp_socket:send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
            %								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 "++_, Packet4),
            %								smtp_socket:send(CSock, "DATA\r\n"),
            %								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("354 "++_, Packet5),
            %								smtp_socket:send(CSock, "Subject: tls message\r\n"),
            %								smtp_socket:send(CSock, "To: <user@otherhost>\r\n"),
            %								smtp_socket:send(CSock, "From: <user@somehost.com>\r\n"),
            %								smtp_socket:send(CSock, "\r\n"),
            %								smtp_socket:send(CSock, "this\r\n"),
            %								smtp_socket:send(CSock, "body\r\n"),
            %								smtp_socket:send(CSock, "has\r\n"),
            %								smtp_socket:send(CSock, "a\r\n"),
            %								smtp_socket:send(CSock, "bare\n"),
            %								smtp_socket:send(CSock, "newline\r\n"),
            %								smtp_socket:send(CSock, "\r\n.\r\n"),
            %								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("451 "++_, Packet6),
            %						end
            %					}
            %			end,
            %fun({CSock, _Pid}) ->
            %					{"Sending DATA with a bare CR",
            %						fun() ->
            %								smtp_socket:active_once(CSock),
            %								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("220 localhost"++_Stuff,  Packet),
            %								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
            %								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 localhost\r\n",  Packet2),
            %								smtp_socket:send(CSock, "MAIL FROM:<user@somehost.com>\r\n"),
            %								receive {tcp, CSock, Packet3} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 "++_, Packet3),
            %								smtp_socket:send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
            %								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 "++_, Packet4),
            %								smtp_socket:send(CSock, "DATA\r\n"),
            %								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("354 "++_, Packet5),
            %								smtp_socket:send(CSock, "Subject: tls message\r\n"),
            %								smtp_socket:send(CSock, "To: <user@otherhost>\r\n"),
            %								smtp_socket:send(CSock, "From: <user@somehost.com>\r\n"),
            %								smtp_socket:send(CSock, "\r\n"),
            %								smtp_socket:send(CSock, "this\r\n"),
            %								smtp_socket:send(CSock, "\rbody\r\n"),
            %								smtp_socket:send(CSock, "has\r\n"),
            %								smtp_socket:send(CSock, "a\r\n"),
            %								smtp_socket:send(CSock, "bare\r"),
            %								smtp_socket:send(CSock, "CR\r\n"),
            %								smtp_socket:send(CSock, "\r\n.\r\n"),
            %								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("451 "++_, Packet6),
            %						end
            %					}
            %			end,

            %			fun({CSock, _Pid}) ->
            %					{"Sending DATA with a bare newline in the headers",
            %						fun() ->
            %								smtp_socket:active_once(CSock),
            %								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("220 localhost"++_Stuff,  Packet),
            %								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
            %								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 localhost\r\n",  Packet2),
            %								smtp_socket:send(CSock, "MAIL FROM:<user@somehost.com>\r\n"),
            %								receive {tcp, CSock, Packet3} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 "++_, Packet3),
            %								smtp_socket:send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
            %								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("250 "++_, Packet4),
            %								smtp_socket:send(CSock, "DATA\r\n"),
            %								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("354 "++_, Packet5),
            %								smtp_socket:send(CSock, "Subject: tls message\r\n"),
            %								smtp_socket:send(CSock, "To: <user@otherhost>\n"),
            %								smtp_socket:send(CSock, "From: <user@somehost.com>\r\n"),
            %								smtp_socket:send(CSock, "\r\n"),
            %								smtp_socket:send(CSock, "this\r\n"),
            %								smtp_socket:send(CSock, "body\r\n"),
            %								smtp_socket:send(CSock, "has\r\n"),
            %								smtp_socket:send(CSock, "no\r\n"),
            %								smtp_socket:send(CSock, "bare\r\n"),
            %								smtp_socket:send(CSock, "newlines\r\n"),
            %								smtp_socket:send(CSock, "\r\n.\r\n"),
            %								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
            %								?assertMatch("451 "++_, Packet6),
            %						end
            %					}
            %			end,
            fun({CSock, _Pid}) ->
                {"Sending DATA with bare newline on first line of body", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "HELO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 localhost\r\n", Packet2),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO:<user@otherhost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "DATA\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("354 " ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "Subject: tls message\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "To: <user@otherhost>\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "From: <user@somehost.com>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "this\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "body\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "has\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "no\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "bare\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "newlines\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n.\r\n"),
                    receive
                        {tcp, CSock, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("451 " ++ _, Packet6)
                end}
            end
        ]}.

lmtp_session_test_() ->
    {foreach, local,
        fun() ->
            application:ensure_all_started(postbeam),
            {ok, Pid} = 'Elixir.Postbeam.SMTP.Server':start(
                'Elixir.Postbeam.SMTP.Example',
                [
                    {sessionoptions, [
                        {protocol, lmtp},
                        {callbackoptions, [
                            {protocol, lmtp},
                            {size, infinity}
                        ]}
                    ]},
                    {domain, "localhost"},
                    {port, 9876}
                ]
            ),
            {ok, CSock} = 'Elixir.Postbeam.SMTP.Socket':connect(tcp, "localhost", 9876),
            {CSock, Pid}
        end,
        fun({CSock, _Pid}) ->
            'Elixir.Postbeam.SMTP.Server':stop('Elixir.Postbeam.SMTP.Server'),
            'Elixir.Postbeam.SMTP.Socket':close(CSock),
            timer:sleep(10)
        end,
        [
            fun({CSock, _Pid}) ->
                {"An error in response to a HELO/EHLO sent by LMTP", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "HELO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch(
                        "500 Error: LMTP should replace HELO and EHLO with LHLO\r\n", Packet2
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch(
                        "500 Error: LMTP should replace HELO and EHLO with LHLO\r\n", Packet3
                    )
                end}
            end,
            fun({CSock, _Pid}) ->
                {"LHLO response", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "LHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F) ->
                        receive
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F);
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                ok;
                            {tcp, CSock, _R} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(ok, Foo(Foo))
                end}
            end,
            fun({CSock, _Pid}) ->
                {"DATA with multiple RCPT TO", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "LHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-SIZE" ++ _ = Data} ->
                                {error, ["received: ", Data]};
                            {tcp, CSock, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 PIPELINING" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 SMTPUTF8" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, Data} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                {error, ["received: ", Data]}
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),

                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@otherhost>\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO:<test1@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO:<test2@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO:<test3@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet6),

                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "DATA\r\n"),
                    receive
                        {tcp, CSock, Packet7} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("354 " ++ _, Packet7),

                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "Subject: tls message\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "To: <user@otherhost>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "From: <user@somehost.com>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "message body"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n.\r\n"),
                    % We sent 3 RCPT TO, so we should have 3 delivery reports
                    AssertDelivery = fun(_) ->
                        receive
                            {tcp, CSock, Packet8} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                        end,
                        ?assertMatch("250 " ++ _, Packet8)
                    end,
                    lists:foreach(AssertDelivery, [1, 2, 3]),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "QUIT\r\n"),
                    receive
                        {tcp, CSock, Packet9} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("221 " ++ _, Packet9)
                end}
            end
        ]}.

smtp_session_auth_test_() ->
    {foreach, local,
        fun() ->
            application:ensure_all_started(postbeam),
            {ok, Pid} = 'Elixir.Postbeam.SMTP.Server':start(
                'Elixir.Postbeam.SMTP.Example',
                [
                    {sessionoptions, [{callbackoptions, [{auth, true}]}]},
                    {domain, "localhost"},
                    {port, 9876}
                ]
            ),
            {ok, CSock} = 'Elixir.Postbeam.SMTP.Socket':connect(tcp, "localhost", 9876),
            {CSock, Pid}
        end,
        fun({CSock, _Pid}) ->
            'Elixir.Postbeam.SMTP.Server':stop('Elixir.Postbeam.SMTP.Server'),
            'Elixir.Postbeam.SMTP.Socket':close(CSock),
            timer:sleep(10)
        end,
        [
            fun({CSock, _Pid}) ->
                {"EHLO response includes AUTH", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false))
                end}
            end,
            fun({CSock, _Pid}) ->
                {"AUTH before EHLO is error", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH CRAZY\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("503 " ++ _, Packet4)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Unknown authentication type", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH CRAZY\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("504 Unrecognized authentication type\r\n", Packet4)
                end}
            end,

            fun({CSock, _Pid}) ->
                {"A successful AUTH PLAIN", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH PLAIN\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334\r\n", Packet4),
                    String = binary_to_list(base64:encode("\0username\0PaSSw0rd")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("235 Authentication successful.\r\n", Packet5)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"A successful AUTH PLAIN with an identity", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH PLAIN\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334\r\n", Packet4),
                    String = binary_to_list(base64:encode("username\0username\0PaSSw0rd")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("235 Authentication successful.\r\n", Packet5)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"A successful immediate AUTH PLAIN", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    String = binary_to_list(base64:encode("\0username\0PaSSw0rd")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH PLAIN " ++ String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("235 Authentication successful.\r\n", Packet5)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"A successful immediate AUTH PLAIN with an identity", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _R} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    String = binary_to_list(base64:encode("username\0username\0PaSSw0rd")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH PLAIN " ++ String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("235 Authentication successful.\r\n", Packet5)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"An unsuccessful immediate AUTH PLAIN", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    String = binary_to_list(base64:encode("username\0username\0PaSSw0rd2")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH PLAIN " ++ String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("535 Authentication failed.\r\n", Packet5)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"An unsuccessful AUTH PLAIN", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH PLAIN\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334\r\n", Packet4),
                    String = binary_to_list(base64:encode("\0username\0NotThePassword")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("535 Authentication failed.\r\n", Packet5)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"A successful AUTH LOGIN", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH LOGIN\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334 VXNlcm5hbWU6\r\n", Packet4),
                    String = binary_to_list(base64:encode("username")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334 UGFzc3dvcmQ6\r\n", Packet5),
                    PString = binary_to_list(base64:encode("PaSSw0rd")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, PString ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("235 Authentication successful.\r\n", Packet6)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"An unsuccessful AUTH LOGIN", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH LOGIN\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334 VXNlcm5hbWU6\r\n", Packet4),
                    String = binary_to_list(base64:encode("username2")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334 UGFzc3dvcmQ6\r\n", Packet5),
                    PString = binary_to_list(base64:encode("PaSSw0rd")),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, PString ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("535 Authentication failed.\r\n", Packet6)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"A successful AUTH CRAM-MD5", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH CRAM-MD5\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334 " ++ _, Packet4),

                    ["334", Seed64] = string:tokens('Elixir.Postbeam.SMTP.Util':trim_crlf(Packet4), " "),
                    Seed = base64:decode_to_string(Seed64),
                    Digest = 'Elixir.Postbeam.SMTP.Util':compute_cram_digest("PaSSw0rd", Seed),
                    String = binary_to_list(base64:encode(list_to_binary(["username ", Digest]))),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("235 Authentication successful.\r\n", Packet5)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"An unsuccessful AUTH CRAM-MD5", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 AUTH" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "AUTH CRAM-MD5\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("334 " ++ _, Packet4),

                    ["334", Seed64] = string:tokens('Elixir.Postbeam.SMTP.Util':trim_crlf(Packet4), " "),
                    Seed = base64:decode_to_string(Seed64),
                    Digest = 'Elixir.Postbeam.SMTP.Util':compute_cram_digest("Passw0rd", Seed),
                    String = binary_to_list(base64:encode(list_to_binary(["username ", Digest]))),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, String ++ "\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("535 Authentication failed.\r\n", Packet5)
                end}
            end
        ]}.

smtp_session_tls_test_() ->
    {foreach, local,
        fun() ->
            application:ensure_all_started(postbeam),
            {ok, Pid} = 'Elixir.Postbeam.SMTP.Server':start(
                'Elixir.Postbeam.SMTP.Example',
                [
                    {sessionoptions, [
                        {tls_options, [
                            {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                            {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"}
                        ]},
                        {callbackoptions, [{auth, true}]}
                    ]},
                    {domain, "localhost"},
                    {port, 9876}
                ]
            ),
            {ok, CSock} = 'Elixir.Postbeam.SMTP.Socket':connect(tcp, "localhost", 9876),
            {CSock, Pid}
        end,
        fun({CSock, _Pid}) ->
            'Elixir.Postbeam.SMTP.Server':stop('Elixir.Postbeam.SMTP.Server'),
            'Elixir.Postbeam.SMTP.Socket':close(CSock),
            timer:sleep(10)
        end,
        [
            fun({CSock, _Pid}) ->
                {"EHLO response includes STARTTLS", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false))
                end}
            end,
            fun({CSock, _Pid}) ->
                {"STARTTLS does a SSL handshake", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "STARTTLS\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> ok
                    end,
                    ?assertMatch("220 " ++ _, Packet4),
                    Result = 'Elixir.Postbeam.SMTP.Socket':to_ssl_client(CSock, [{verify, verify_none}]),
                    ?assertMatch({ok, _Socket}, Result),
                    {ok, _Socket} = Result
                %smtp_socket:active_once(Socket),
                %ssl:send(Socket, "EHLO somehost.com\r\n"),
                %receive {ssl, Socket, Packet5} -> smtp_socket:active_once(Socket) end,
                %?assertEqual("Foo", Packet5),
                end}
            end,
            fun({CSock, _Pid}) ->
                {"After STARTTLS, EHLO doesn't report STARTTLS", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "STARTTLS\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> ok
                    end,
                    ?assertMatch("220 " ++ _, Packet4),
                    Result = 'Elixir.Postbeam.SMTP.Socket':to_ssl_client(CSock, [{verify, verify_none}]),
                    ?assertMatch({ok, _Socket}, Result),
                    {ok, Socket} = Result,
                    'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "EHLO somehost.com\r\n"),
                    receive
                        {ssl, Socket, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet5),
                    Bar = fun(F, Acc) ->
                        receive
                            {ssl, Socket, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                F(F, true);
                            {ssl, Socket, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                F(F, Acc);
                            {ssl, Socket, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                true;
                            {ssl, Socket, "250 " ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                Acc;
                            {ssl, Socket, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                error
                        end
                    end,
                    ?assertEqual(false, Bar(Bar, false))
                end}
            end,
            fun({CSock, _Pid}) ->
                {"After STARTTLS, re-negotiating STARTTLS is an error", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "STARTTLS\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> ok
                    end,
                    ?assertMatch("220 " ++ _, Packet4),
                    Result = 'Elixir.Postbeam.SMTP.Socket':to_ssl_client(CSock, [{verify, verify_none}]),
                    ?assertMatch({ok, _Socket}, Result),
                    {ok, Socket} = Result,
                    'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "EHLO somehost.com\r\n"),
                    receive
                        {ssl, Socket, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet5),
                    Bar = fun(F, Acc) ->
                        receive
                            {ssl, Socket, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                F(F, true);
                            {ssl, Socket, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                F(F, Acc);
                            {ssl, Socket, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                true;
                            {ssl, Socket, "250 " ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                Acc;
                            {ssl, Socket, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                error
                        end
                    end,
                    ?assertEqual(false, Bar(Bar, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "STARTTLS\r\n"),
                    receive
                        {ssl, Socket, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("500 " ++ _, Packet6)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"STARTTLS can't take any parameters", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "STARTTLS foo\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> ok
                    end,
                    ?assertMatch("501 " ++ _, Packet4)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Negotiating STARTTLS twice is an error", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, _Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, _Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ReadExtensions = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, ReadExtensions(ReadExtensions, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "STARTTLS\r\n"),
                    receive
                        {tcp, CSock, _} -> ok
                    end,
                    {ok, Socket} = 'Elixir.Postbeam.SMTP.Socket':to_ssl_client(CSock, [{verify, verify_none}]),
                    'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "EHLO somehost.com\r\n"),
                    receive
                        {ssl, Socket, PacketN} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("250-localhost\r\n", PacketN),
                    Bar = fun(F, Acc) ->
                        receive
                            {ssl, Socket, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                F(F, true);
                            {ssl, Socket, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                F(F, Acc);
                            {ssl, Socket, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                true;
                            {ssl, Socket, "250 " ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                Acc;
                            {tcp, Socket, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                error
                        end
                    end,
                    ?assertEqual(false, Bar(Bar, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "STARTTLS\r\n"),
                    receive
                        {ssl, Socket, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("500 " ++ _, Packet6)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"STARTTLS can't take any parameters", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "STARTTLS foo\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> ok
                    end,
                    ?assertMatch("501 " ++ _, Packet4)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"After STARTTLS, message is received by server", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, _Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, _Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ReadExtensions = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-" ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 STARTTLS" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 " ++ _Packet3} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                Acc;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, ReadExtensions(ReadExtensions, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "STARTTLS\r\n"),
                    receive
                        {tcp, CSock, _} -> ok
                    end,
                    {ok, Socket} = 'Elixir.Postbeam.SMTP.Socket':to_ssl_client(CSock, [{verify, verify_none}]),
                    'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "EHLO somehost.com\r\n"),
                    ReadSSLExtensions = fun(F, Acc) ->
                        receive
                            {ssl, Socket, "250-" ++ _Rest} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                F(F, Acc);
                            {ssl, Socket, "250 " ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                true;
                            {ssl, Socket, _R} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(Socket),
                                error
                        end
                    end,
                    ?assertEqual(true, ReadSSLExtensions(ReadSSLExtensions, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "MAIL FROM:<user@somehost.com>\r\n"),
                    receive
                        {ssl, Socket, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("250 " ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "RCPT TO:<user@otherhost.com>\r\n"),
                    receive
                        {ssl, Socket, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("250 " ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "DATA\r\n"),
                    receive
                        {ssl, Socket, Packet6} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("354 " ++ _, Packet6),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "Subject: tls message\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "To: <user@otherhost>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "From: <user@somehost.com>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "message body"),
                    'Elixir.Postbeam.SMTP.Socket':send(Socket, "\r\n.\r\n"),
                    receive
                        {ssl, Socket, Packet7} -> 'Elixir.Postbeam.SMTP.Socket':active_once(Socket)
                    end,
                    ?assertMatch("250 " ++ _, Packet7)
                end}
            end
        ]}.

smtp_session_tls_sni_test_() ->
    {foreach, local,
        fun() ->
            SniHosts =
                [
                    {"mx1.example.com", [
                        {keyfile, "test/smtp/fixtures/mx1.example.com-server.key"},
                        {certfile, "test/smtp/fixtures/mx1.example.com-server.crt"},
                        {cacertfile, "test/smtp/fixtures/root.crt"}
                    ]},
                    {"mx2.example.com", [
                        {keyfile, "test/smtp/fixtures/mx2.example.com-server.key"},
                        {certfile, "test/smtp/fixtures/mx2.example.com-server.crt"},
                        {cacertfile, "test/smtp/fixtures/root.crt"}
                    ]}
                ],
            application:ensure_all_started(postbeam),
            {ok, _} = 'Elixir.Postbeam.SMTP.Server':start(
                'Elixir.Postbeam.SMTP.Example',
                [
                    {sessionoptions, [
                        {tls_options, [{sni_hosts, SniHosts}]},
                        {callbackoptions, [{auth, true}]}
                    ]},
                    {domain, "localhost"},
                    {port, 9876}
                ]
            ),
            [Host || {Host, _} <- SniHosts]
        end,
        fun(_Hosts) ->
            'Elixir.Postbeam.SMTP.Server':stop('Elixir.Postbeam.SMTP.Server')
        end,
        [fun strict_sni/1]}.

strict_sni(Hosts) ->
    {"Do strict validation based on SNI", fun() ->
        [
            begin
                {ok, CSock} = 'Elixir.Postbeam.SMTP.Socket':connect(tcp, "localhost", 9876),
                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                receive
                    {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                end,
                ?assertMatch("220 localhost" ++ _Stuff, Packet),
                'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                receive
                    {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                end,
                ?assertMatch("250-localhost\r\n", Packet2),
                Foo = fun Foo(Acc) ->
                    receive
                        {tcp, CSock, "250-STARTTLS" ++ _} ->
                            'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                            Foo(true);
                        {tcp, CSock, "250-" ++ _Packet3} ->
                            'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                            Foo(Acc);
                        {tcp, CSock, "250 STARTTLS" ++ _} ->
                            'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                            true;
                        {tcp, CSock, "250 " ++ _Packet3} ->
                            'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                            Acc;
                        {tcp, CSock, _} ->
                            'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                            error
                    end
                end,
                ?assertEqual(true, Foo(false)),
                'Elixir.Postbeam.SMTP.Socket':send(CSock, "STARTTLS\r\n"),
                receive
                    {tcp, CSock, Packet4} -> ok
                end,
                ?assertMatch("220 " ++ _, Packet4),
                {ok, TlsSocket} = ssl:connect(
                    CSock,
                    [
                        {server_name_indication, Host},
                        {verify, verify_peer},
                        {cacertfile, "test/smtp/fixtures/root.crt"}
                    ]
                ),
                %% Make sure server selects certificate based on SNI
                {ok, Cert} = ssl:peercert(TlsSocket),
                verify_cert_hostname(Cert, Host),
                'Elixir.Postbeam.SMTP.Socket':active_once(TlsSocket),
                'Elixir.Postbeam.SMTP.Socket':send(TlsSocket, "EHLO somehost.com\r\n"),
                receive
                    {ssl, TlsSocket, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(TlsSocket)
                end,
                ?assertMatch("250-localhost\r\n", Packet5),
                ssl:close(TlsSocket)
            end
         || Host <- Hosts
        ]
    end}.

verify_cert_hostname(BinCert, Host) ->
    DecCert = public_key:pkix_decode_cert(BinCert, otp),
    ?assert(public_key:pkix_verify_hostname(DecCert, [{dns_id, Host}])).

stray_newline_test_() ->
    [
        {"Error out by default", fun() ->
            ?assertEqual(<<"foo">>, check_bare_crlf(<<"foo">>, <<>>, false, 0)),
            ?assertEqual(error, check_bare_crlf(<<"foo\n">>, <<>>, false, 0)),
            ?assertEqual(error, check_bare_crlf(<<"fo\ro\n">>, <<>>, false, 0)),
            ?assertEqual(error, check_bare_crlf(<<"fo\ro\n\r">>, <<>>, false, 0)),
            ?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\r\n">>, <<>>, false, 0)),
            ?assertEqual(<<"foo\r">>, check_bare_crlf(<<"foo\r">>, <<>>, false, 0))
        end},
        {"Fixing them should work", fun() ->
            ?assertEqual(<<"foo">>, check_bare_crlf(<<"foo">>, <<>>, fix, 0)),
            ?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\n">>, <<>>, fix, 0)),
            ?assertEqual(<<"fo\r\no\r\n">>, check_bare_crlf(<<"fo\ro\n">>, <<>>, fix, 0)),
            ?assertEqual(<<"fo\r\no\r\n\r">>, check_bare_crlf(<<"fo\ro\n\r">>, <<>>, fix, 0)),
            ?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\r\n">>, <<>>, fix, 0))
        end},
        {"Stripping them should work", fun() ->
            ?assertEqual(<<"foo">>, check_bare_crlf(<<"foo">>, <<>>, strip, 0)),
            ?assertEqual(<<"foo">>, check_bare_crlf(<<"fo\ro\n">>, <<>>, strip, 0)),
            ?assertEqual(<<"foo\r">>, check_bare_crlf(<<"fo\ro\n\r">>, <<>>, strip, 0)),
            ?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\r\n">>, <<>>, strip, 0))
        end},
        {"Ignoring them should work", fun() ->
            ?assertEqual(<<"foo">>, check_bare_crlf(<<"foo">>, <<>>, ignore, 0)),
            ?assertEqual(<<"fo\ro\n">>, check_bare_crlf(<<"fo\ro\n">>, <<>>, ignore, 0)),
            ?assertEqual(<<"fo\ro\n\r">>, check_bare_crlf(<<"fo\ro\n\r">>, <<>>, ignore, 0)),
            ?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\r\n">>, <<>>, ignore, 0))
        end},
        {"Leading bare LFs should check the previous line", fun() ->
            ?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r">>, false, 0)),
            ?assertEqual(
                <<"\r\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r\n">>, fix, 0)
            ),
            ?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r">>, fix, 0)),
            ?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r\n">>, strip, 0)),
            ?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r">>, strip, 0)),
            ?assertEqual(
                <<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r\n">>, ignore, 0)
            ),
            ?assertEqual(error, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r\n">>, false, 0)),
            ?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r">>, false, 0))
        end}
    ].

smtp_session_maxsize_test_() ->
    {foreach, local,
        fun() ->
            application:ensure_all_started(postbeam),
            {ok, Pid} = 'Elixir.Postbeam.SMTP.Server':start(
                'Elixir.Postbeam.SMTP.Example',
                [
                    {sessionoptions, [{callbackoptions, [{size, 100}]}]},
                    {domain, "localhost"},
                    {port, 9876}
                ]
            ),
            {ok, CSock} = 'Elixir.Postbeam.SMTP.Socket':connect(tcp, "localhost", 9876),
            {CSock, Pid}
        end,
        fun({CSock, _Pid}) ->
            'Elixir.Postbeam.SMTP.Server':stop('Elixir.Postbeam.SMTP.Server'),
            'Elixir.Postbeam.SMTP.Socket':close(CSock),
            timer:sleep(10)
        end,
        [
            fun({CSock, _Pid}) ->
                {"Message with ok size", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-SIZE 100\r\n"} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-SIZE" ++ _} ->
                                error;
                            {tcp, CSock, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 PIPELINING" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 SMTPUTF8" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@otherhost>\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO:<test@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "DATA\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("354 " ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "Subject: tls message\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "To: <user@otherhost>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "From: <user@somehost.com>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "message body"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n.\r\n"),
                    receive
                        {tcp, CSock, Packet7} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet7)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Message with too large size", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-SIZE 100\r\n"} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-SIZE" ++ _} ->
                                error;
                            {tcp, CSock, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 PIPELINING" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 SMTPUTF8" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@otherhost>\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO:<test@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "DATA\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("354 " ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "Subject: tls message\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "To: <user@otherhost>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "From: <user@somehost.com>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(
                        CSock, "message body message body message body message body message body"
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(
                        CSock, "message body message body message body message body message body"
                    ),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n.\r\n"),
                    receive
                        {tcp, CSock, Packet7} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("552 " ++ _, Packet7)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Message with ok size in FROM extension", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-SIZE 100\r\n"} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-SIZE" ++ _} ->
                                error;
                            {tcp, CSock, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 PIPELINING" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 SMTPUTF8" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@otherhost> SIZE=100\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Message with not ok size in FROM extension", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-SIZE 100\r\n"} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-SIZE" ++ _} ->
                                error;
                            {tcp, CSock, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 PIPELINING" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 SMTPUTF8" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@otherhost> SIZE=101\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("552 " ++ _, Packet3)
                end}
            end
        ]}.

smtp_session_nomaxsize_test_() ->
    {foreach, local,
        fun() ->
            application:ensure_all_started(postbeam),
            {ok, Pid} = 'Elixir.Postbeam.SMTP.Server':start(
                'Elixir.Postbeam.SMTP.Example',
                [
                    {sessionoptions, [{callbackoptions, [{size, infinity}]}]},
                    {domain, "localhost"},
                    {port, 9876}
                ]
            ),
            {ok, CSock} = 'Elixir.Postbeam.SMTP.Socket':connect(tcp, "localhost", 9876),
            {CSock, Pid}
        end,
        fun({CSock, _Pid}) ->
            'Elixir.Postbeam.SMTP.Server':stop('Elixir.Postbeam.SMTP.Server'),
            'Elixir.Postbeam.SMTP.Socket':close(CSock),
            timer:sleep(10)
        end,
        [
            fun({CSock, _Pid}) ->
                {"Message with no max size", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-SIZE" ++ _ = _Data} ->
                                error;
                            {tcp, CSock, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 PIPELINING" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 SMTPUTF8" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, _Data} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@otherhost>\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "RCPT TO:<test@somehost.com>\r\n"),
                    receive
                        {tcp, CSock, Packet4} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet4),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "DATA\r\n"),
                    receive
                        {tcp, CSock, Packet5} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("354 " ++ _, Packet5),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "Subject: tls message\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "To: <user@otherhost>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "From: <user@somehost.com>\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "message body"),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "\r\n.\r\n"),
                    receive
                        {tcp, CSock, Packet7} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet7)
                end}
            end,
            fun({CSock, _Pid}) ->
                {"Message with ok huge size in FROM extension", fun() ->
                    'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                    receive
                        {tcp, CSock, Packet} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("220 localhost" ++ _Stuff, Packet),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "EHLO somehost.com\r\n"),
                    receive
                        {tcp, CSock, Packet2} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250-localhost\r\n", Packet2),
                    Foo = fun(F, Acc) ->
                        receive
                            {tcp, CSock, "250-SIZE 100\r\n"} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, true);
                            {tcp, CSock, "250-SIZE" ++ _} ->
                                error;
                            {tcp, CSock, "250-" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                F(F, Acc);
                            {tcp, CSock, "250 PIPELINING" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, "250 SMTPUTF8" ++ _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                true;
                            {tcp, CSock, _} ->
                                'Elixir.Postbeam.SMTP.Socket':active_once(CSock),
                                error
                        end
                    end,
                    ?assertEqual(true, Foo(Foo, false)),
                    'Elixir.Postbeam.SMTP.Socket':send(CSock, "MAIL FROM:<user@otherhost> SIZE=100000000\r\n"),
                    receive
                        {tcp, CSock, Packet3} -> 'Elixir.Postbeam.SMTP.Socket':active_once(CSock)
                    end,
                    ?assertMatch("250 " ++ _, Packet3)
                end}
            end
        ]}.

