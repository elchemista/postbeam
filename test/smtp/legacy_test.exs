defmodule Postbeam.SMTP.LegacyTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000
  for module <- [
        :postbeam_smtp_legacy_mimemail_tests,
        :postbeam_smtp_legacy_gen_smtp_client_tests,
        :postbeam_smtp_legacy_gen_smtp_server_session_tests,
        :postbeam_smtp_legacy_smtp_socket_tests,
        :postbeam_smtp_gen_smtp_util_test,
        :postbeam_smtp_gen_smtp_server_test
      ] do
    test "original regression suite: #{module}" do
      assert :ok == :eunit.test(unquote(module), [:verbose])
    end
  end
end
