-module(postbeam_smtp_gen_smtp_server_test).

-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

invalid_lmtp_port_test_() ->
    {"gen_smtp_server should prevent starting LMTP on port 25 (RFC2023, section 5)", fun() ->
        Options = [{port, 25}, {sessionoptions, [{protocol, lmtp}]}],
        [
            ?_assertMatch(
                {error, invalid_lmtp_port},
                'Elixir.Postbeam.SMTP.Server':start('Elixir.Postbeam.SMTP.Server', Options)
            ),
            ?_assertError(
                invalid_lmtp_port,
                'Elixir.Postbeam.SMTP.Server':child_spec("LMTP Server", 'Elixir.Postbeam.SMTP.Server', Options)
            )
        ]
    end}.
