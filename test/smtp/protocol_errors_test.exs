defmodule Postbeam.SMTP.ProtocolErrorsTest do
  use ExUnit.Case, async: true

  alias Postbeam.SMTP.Server
  alias Postbeam.SMTP.Socket
  alias Postbeam.SMTP.TestHandler

  defp listener(callback_options, session_options \\ []) do
    name = make_ref()

    start_supervised!(
      {Server,
       {TestHandler,
        name: name,
        port: 0,
        address: {127, 0, 0, 1},
        domain: ~c"localhost",
        sessionoptions:
          Keyword.merge(
            [
              callbackoptions: [owner: self(), notify_termination: true] ++ callback_options,
              tls_options: [
                certfile: ~c"test/smtp/fixtures/mx1.example.com-server.crt",
                keyfile: ~c"test/smtp/fixtures/mx1.example.com-server.key"
              ]
            ],
            session_options
          )}}
    )

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, :ranch.get_port(name), [
        :binary,
        active: false,
        packet: :line
      ])

    on_exit(fn -> Socket.close(socket) end)
    assert reply(socket) =~ "220 "
    assert command(socket, "EHLO sender.test") =~ "250 "
    {name, socket}
  end

  defp command(socket, command) do
    :ok = Socket.send(socket, command <> "\r\n")
    reply(socket)
  end

  defp reply(socket) do
    {:ok, response} = Socket.recv(socket, 0, 2_000)

    case response do
      <<_::binary-size(3), "-", _::binary>> -> response <> reply(socket)
      _ -> response
    end
  end

  test "a multiple DATA response in SMTP stops cleanly and invokes terminate" do
    {name, socket} = listener(multiple: true)
    [session] = Server.sessions(name)
    monitor = Process.monitor(session)
    assert command(socket, "MAIL FROM:<sender@example.org>") =~ "250 "
    assert command(socket, "RCPT TO:<one@example.net>") =~ "250 "
    assert command(socket, "DATA") =~ "354 "
    :ok = Socket.send(socket, "Hello\r\n.\r\n")
    assert reply(socket) =~ "451 "
    assert_receive {:session_terminated, ^session, {:handle_DATA_error, _}}
    assert_receive {:DOWN, ^monitor, :process, ^session, {:handle_DATA_error, _}}
  end

  test "invalid AUTH payloads and unsupported mechanisms do not crash or stall the session" do
    {_, socket} = listener(auth_types: ~c"PLAIN LOGIN CRAM-MD5 XOAUTH2")

    for command <- [
          "AUTH PLAIN !",
          "AUTH PLAIN " <> Base.encode64("no separators"),
          "AUTH XOAUTH2"
        ] do
      assert command(socket, command) =~ ~r/^50[14] /
      assert command(socket, "NOOP") =~ "250 "
    end

    for mechanism <- ["PLAIN", "LOGIN", "CRAM-MD5"] do
      assert command(socket, "AUTH " <> mechanism) =~ "334"
      assert command(socket, "!") =~ "501 "
      assert command(socket, "NOOP") =~ "250 "
    end
  end

  test "the configured TLS deadline closes a stalled handshake" do
    {name, socket} = listener([tls: true], tls_timeout: 100)
    [session] = Server.sessions(name)
    monitor = Process.monitor(session)
    assert command(socket, "STARTTLS") =~ "220 "
    assert_receive {:DOWN, ^monitor, :process, ^session, _}, 1500
    assert {:error, :closed} = Socket.recv(socket, 0, 1000)
  end

  test "LMTP retains recipient order when emitting individual delivery results" do
    name = make_ref()

    start_supervised!(
      {Server,
       {TestHandler,
        name: name,
        port: 0,
        sessionoptions: [protocol: :lmtp, callbackoptions: [owner: self(), multiple: true]]}}
    )

    recipients = ["first@example.net", "second@example.net", "third@example.net"]

    results =
      Postbeam.SMTP.Client.send_blocking({"sender@example.org", recipients, "Hello"},
        relay: ~c"localhost",
        port: :ranch.get_port(name),
        protocol: :lmtp,
        tls: :never,
        auth: :never
      )

    assert results == Enum.map(recipients, &{&1, "250 queued\r\n"})
    assert_receive {:delivery_started, _, _, ^recipients, "Hello"}
  end
end
