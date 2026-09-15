defmodule Postbeam.Inbound.MessageTest do
  use ExUnit.Case, async: true

  alias Postbeam.Inbound.Message

  @spec message(binary()) :: Message.t()
  defp message(data) do
    %Message{
      from: "sender@example.org",
      to: ["hidden@example.net"],
      data: data,
      peer: {127, 0, 0, 1},
      helo: "sender.example.org",
      tls: true
    }
  end

  test "manual decoding returns the MIME tree while preserving raw data and envelope" do
    original =
      message(
        "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n" <>
          "Content-Transfer-Encoding: quoted-printable\r\n\r\nCaff=C3=A8\r\n"
      )

    assert {:ok, decoded} = Message.decode(original)
    assert {"text", "plain", _, _, "Caffè\r\n"} = decoded.decoded
    assert %{decoded | decoded: nil} == original
  end

  test "manual decoding normalizes parser exceptions and throws without leaking details" do
    for data <- [
          "MIME-Version: 1.0\r\nContent-Type: multipart/mixed\r\n\r\nPRIVATE body",
          "MIME-Version: 1.0\r\nContent-Type: invalid\r\n\r\nPRIVATE body",
          "MIME-Version: 1.0\r\nContent-Type: text/plain\r\n" <>
            "Content-Transfer-Encoding: quoted-printable\r\n\r\n=PRIVATE"
        ] do
      assert {:error, :invalid_mime} = data |> message() |> Message.decode()
    end
  end

  test "decoding remains usable without the optional charset converter" do
    script = """
    false = Code.ensure_loaded?(:iconv)
    message = struct!(Postbeam.Inbound.Message,
      from: "sender@example.org", to: ["user@example.net"],
      peer: {127, 0, 0, 1}, helo: "sender.example.org", tls: false,
      data: "MIME-Version: 1.0\\r\\nContent-Type: text/plain; charset=utf-8\\r\\n" <>
        "Subject: =?UTF-8?Q?Caff=C3=A8?=\\r\\n" <>
        "Content-Transfer-Encoding: base64\\r\\n\\r\\nQ2FmZsOo"
    )
    {:ok, decoded} = Postbeam.Inbound.Message.decode(message)
    {"text", "plain", headers, _, "Caffè"} = decoded.decoded
    true = {"Subject", "=?UTF-8?Q?Caff=C3=A8?="} in headers
    true = decoded.data == message.data
    nil = decoded.decode_error
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
