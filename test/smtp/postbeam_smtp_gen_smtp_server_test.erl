-module(postbeam_smtp_gen_smtp_server_test).

-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

invalid_lmtp_port_test_() ->
    Options = [{port, 25}, {sessionoptions, [{protocol, lmtp}]}],
    {"Postbeam.SMTP.Server should prevent starting LMTP on port 25 (RFC2023, section 5)",
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
    }.
