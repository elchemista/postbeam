defmodule Postbeam.SMTP.MIMETest do
  use ExUnit.Case, async: true

  test "raw decoding preserves arbitrary bytes while decoding transfer encoding" do
    message =
      "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=windows-1252\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nprice =80"

    assert {"text", "plain", _, _, <<"price ", 128>>} =
             Postbeam.SMTP.MIME.decode(message, encoding: :raw)
  end

  test "the default decoder works without the optional native charset dependency" do
    script = """
    false = Code.ensure_loaded?(:iconv)
    message = "MIME-Version: 1.0\\r\\nContent-Type: text/plain; charset=utf-8\\r\\n\\r\\ncaffè"
    {"text", "plain", _, _, "caffè"} = Postbeam.SMTP.MIME.decode(message)
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2", "-pa", Application.app_dir(:postbeam, "ebin"), "-e", script],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
