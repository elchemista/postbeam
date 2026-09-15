defmodule Postbeam.InboundTest do
  use ExUnit.Case, async: true

  alias Postbeam.Inbound
  alias Postbeam.TestInboundAdapter

  @data "From: visible@example.org\r\nTo: visible@example.net\r\nSubject: Incoming\r\n\r\nHello\r\n.one dot\r\n"

  defp listener(adapter_options \\ [], options \\ []) do
    name = make_ref()

    config =
      Keyword.merge(
        [
          name: name,
          adapter: {TestInboundAdapter, [owner: self()] ++ adapter_options},
          hostname: "mx.example.net",
          port: 0
        ],
        options
      )

    start_supervised!({Inbound, config})
    {name, :ranch.get_port(name)}
  end

  defp connect(port, greeting \\ "EHLO sender.example.org") do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :line], 2_000)

    on_exit(fn -> Postbeam.SMTP.Socket.close(socket) end)
    assert reply(socket) =~ "220 mx.example.net"
    assert command(socket, greeting) =~ "250 "
    socket
  end

  defp command(socket, line) do
    :ok = Postbeam.SMTP.Socket.send(socket, line <> "\r\n")
    reply(socket)
  end

  defp reply(socket) do
    {:ok, line} = Postbeam.SMTP.Socket.recv(socket, 0, 3_000)

    case line do
      <<_code::binary-size(3), "-", _::binary>> -> line <> reply(socket)
      _ -> line
    end
  end

  defp envelope(socket, from \\ "sender@example.org", to \\ "user@example.net") do
    assert command(socket, "MAIL FROM:<#{from}>") =~ "250 "
    assert command(socket, "RCPT TO:<#{to}>") =~ "250 "
  end

  defp send_data(socket, data \\ @data) do
    assert command(socket, "DATA") =~ "354 "
    escaped = Regex.replace(~r/^\./m, data, "..")
    :ok = Postbeam.SMTP.Socket.send(socket, escaped <> ".\r\n")
  end

  test "hands raw MIME and all accepted envelope recipients to the adapter exactly once" do
    {_, port} = listener()
    socket = connect(port)
    envelope(socket)
    assert command(socket, "RCPT TO:<hidden@example.net>") =~ "250 "
    assert command(socket, "RCPT TO:<outside@example.org>") =~ "550 5.7.1 Unknown recipient"
    send_data(socket)
    assert reply(socket) =~ "250 2.0.0 Message accepted"

    assert_receive {:inbound, _, {:message, %Inbound.Message{} = message}}
    assert message.from == "sender@example.org"
    assert message.to == ["user@example.net", "hidden@example.net"]
    assert message.data == @data
    assert message.peer == {127, 0, 0, 1}
    assert message.helo == "sender.example.org"
    refute message.tls
    refute_receive {:inbound, _, {:message, _}}
  end

  test "waits for adapter success before confirming SMTP acceptance" do
    {_, port} = listener(wait: true)
    socket = connect(port)
    envelope(socket)
    send_data(socket)
    assert_receive {:inbound, adapter, {:message, _}}, 1_000
    assert {:error, :timeout} = Postbeam.SMTP.Socket.recv(socket, 0, 50)
    send(adapter, :continue)
    assert reply(socket) =~ "250 "
  end

  test "a disconnected sender never hands incomplete DATA to the adapter" do
    {_, port} = listener()
    socket = connect(port)
    envelope(socket)
    assert command(socket, "DATA") =~ "354 "
    :ok = :gen_tcp.send(socket, "Subject: incomplete\r\n\r\nBody without terminator")
    :ok = :gen_tcp.close(socket)
    refute_receive {:inbound, _, {:message, _}}
  end

  test "rejected recipients cannot submit DATA and temporary recipient errors remain retryable" do
    {_, port} = listener(recipient_result: {:error, {:temporary, "Directory unavailable"}})
    socket = connect(port)
    assert command(socket, "MAIL FROM:<sender@example.org>") =~ "250 "
    assert command(socket, "RCPT TO:<user@example.net>") =~ "451 4.3.0 Directory unavailable"
    assert command(socket, "RCPT TO:<outside@example.org>") =~ "550 "
    assert command(socket, "DATA") =~ "503 "
    refute_receive {:inbound, _, {:message, _}}
  end

  test "maps temporary and permanent message failures to SMTP rejection" do
    for {kind, code} <- [temporary: "451", permanent: "550"] do
      {_, port} = listener(message_result: {:error, {kind, "Cannot handle this message"}})
      socket = connect(port)
      envelope(socket)
      send_data(socket)
      assert reply(socket) =~ "#{code} "
    end
  end

  test "encodes Unicode rejection text as bytes on the wire" do
    {_, port} = listener(recipient_result: {:error, {:permanent, "Utente non disponibile ☕"}})
    socket = connect(port)
    assert command(socket, "MAIL FROM:<sender@example.org>") =~ "250 "
    assert command(socket, "RCPT TO:<user@example.net>") =~ "550 5.7.1 Utente non disponibile ☕"
  end

  test "callback crashes, invalid responses and response injection fail temporarily without details" do
    for result <- [
          :raise,
          :throw,
          :exit,
          {:ok, "invalid result"},
          {:error, {:permanent, "PRIVATE\r\n250 accepted"}},
          {:error, {:temporary, <<255>>}},
          {:error, {:permanent, String.duplicate("x", 401)}}
        ],
        callback <- [:recipient_result, :message_result] do
      {_, port} = listener([{callback, result}])
      socket = connect(port)
      assert command(socket, "MAIL FROM:<sender@example.org>") =~ "250 "
      recipient_reply = command(socket, "RCPT TO:<user@example.net>")

      response =
        if callback == :message_result do
          assert recipient_reply =~ "250 "
          send_data(socket)
          reply(socket)
        else
          recipient_reply
        end

      assert response == "451 4.3.0 Incoming mail handler failed\r\n"
    end
  end

  test "supports bounce senders, RSET and consecutive messages without leaking recipients" do
    {_, port} = listener()
    socket = connect(port, "HELO sender.example.org")
    envelope(socket, "discard@example.org", "discard@example.net")
    assert command(socket, "RSET") =~ "250 "
    assert command(socket, "DATA") =~ "503 "

    for {from, to} <- [{"", "bounce@example.net"}, {"new@example.org", "new@example.net"}] do
      envelope(socket, from, to)
      send_data(socket)
      assert reply(socket) =~ "250 "
      assert_receive {:inbound, _, {:message, %{from: ^from, to: [^to], data: @data}}}
    end
  end

  test "advertises supported extensions and enforces declared and actual size limits" do
    {_, port} = listener([], max_size: 64)
    socket = connect(port)
    extensions = command(socket, "EHLO sender.example.org")
    assert extensions =~ "SIZE 64"
    assert extensions =~ "8BITMIME"
    refute extensions =~ "SMTPUTF8"
    refute extensions =~ "STARTTLS"
    refute extensions =~ "AUTH"
    assert command(socket, "MAIL FROM:<sender@example.org> SIZE=65") =~ "552 "
    assert command(socket, "MAIL FROM:<sender@example.org> SMTPUTF8") =~ "555 "

    for greeting <- ["EHLO sender.example.org", "HELO sender.example.org"] do
      oversized = connect(port, greeting)
      envelope(oversized)
      send_data(oversized)
      assert reply(oversized) =~ "552 "
    end

    refute_receive {:inbound, _, {:message, _}}
  end

  test "malformed SIZE and BODY parameters are rejected without killing or changing the session" do
    {_, port} = listener()
    socket = connect(port)

    for parameter <- [
          "SIZE=abc",
          "SIZE=",
          "SIZE=-1",
          "SIZE=+1",
          "SIZE=1.5",
          "SIZE=1x",
          "SIZE=" <> String.duplicate("9", 21),
          "BODY=WHATEVER",
          "BODY="
        ] do
      assert command(socket, "MAIL FROM:<sender@example.org> " <> parameter) =~ "501 "
      assert command(socket, "NOOP") =~ "250 "
      assert command(socket, "DATA") =~ "503 "
    end

    assert command(socket, "MAIL FROM:<sender@example.org> SIZE=0 BODY=7BIT") =~ "250 "
    assert command(socket, "RCPT TO:<user@example.net>") =~ "250 "
    send_data(socket)
    assert reply(socket) =~ "250 "
    assert_receive {:inbound, _, {:message, %{data: @data}}}
  end

  test "preserves multipart content, attachments and non-UTF-8 data without parsing" do
    {_, port} = listener()
    socket = connect(port)
    envelope(socket)

    data =
      "Content-Type: multipart/mixed; boundary=parts\r\n\r\n" <>
        "--parts\r\nContent-Type: text/plain\r\n\r\nCaffè\r\n" <>
        "--parts\r\nContent-Type: application/octet-stream\r\n" <>
        "Content-Disposition: attachment; filename=a.bin\r\n" <>
        "Content-Transfer-Encoding: base64\r\n\r\nAP8=\r\n--parts--\r\n"

    send_data(socket, data)
    assert reply(socket) =~ "250 "
    assert_receive {:inbound, _, {:message, %{data: ^data}}}

    envelope(socket)
    raw = "Subject: raw\r\n\r\n" <> <<255>> <> "\r\n"
    send_data(socket, raw)
    assert reply(socket) =~ "250 "
    assert_receive {:inbound, _, {:message, %{data: ^raw}}}
  end

  test "the size limit includes the message's final CRLF" do
    for {limit, code} <- [{byte_size(@data), "250"}, {byte_size(@data) - 1, "552"}] do
      {_, port} = listener([], max_size: limit)
      socket = connect(port)
      envelope(socket)
      send_data(socket)
      assert reply(socket) =~ "#{code} "
    end

    assert_receive {:inbound, _, {:message, _}}
    refute_receive {:inbound, _, {:message, _}}
  end

  test "STARTTLS encrypts reception and resets the client greeting" do
    certificate =
      :public_key.pkix_test_data(%{
        root: [digest: :sha256, key: {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}],
        intermediates: [],
        peer: [
          digest: :sha256,
          key: {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}},
          extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"mx.example.net"}]}]
        ]
      })

    {_, port} = listener([], tls_options: certificate)
    socket = connect(port)
    assert command(socket, "EHLO before.example.org") =~ "STARTTLS"
    envelope(socket, "old@example.org", "old@example.net")
    assert command(socket, "STARTTLS") =~ "220 "

    {:ok, secure} =
      :ssl.connect(
        socket,
        [
          active: false,
          packet: :line,
          mode: :binary,
          verify: :verify_peer,
          cacerts: certificate[:cacerts],
          server_name_indication: ~c"mx.example.net"
        ],
        3_000
      )

    assert command(secure, "DATA") =~ "503 "
    extensions = command(secure, "EHLO secure.example.org")
    refute extensions =~ "STARTTLS"
    envelope(secure)
    send_data(secure)
    assert reply(secure) =~ "250 "

    assert_receive {:inbound, _,
                    {:message, %{tls: true, helo: "secure.example.org", to: ["user@example.net"]}}}

    :ssl.close(secure)
  end

  test "listeners have independent adapters and stop with their supervisor" do
    {name, port} = listener([], adapter: TestInboundAdapter)
    socket = connect(port)
    envelope(socket)
    send_data(socket)
    assert reply(socket) =~ "250 "
    assert command(socket, "VRFY user@example.net") =~ "252 "
    assert command(socket, "UNKNOWN") =~ "500 "
    assert command(socket, "QUIT") =~ "221 "
    assert :ok = stop_supervised({Inbound, name})
    assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 500)
  end

  test "start_link supports a linked IPv6 listener" do
    name = make_ref()
    address = {0, 0, 0, 0, 0, 0, 0, 1}
    options = [name: name, address: address, port: 0, adapter: TestInboundAdapter]

    start_supervised!(%{
      id: name,
      start: {Inbound, :start_link, [options]},
      type: :supervisor
    })

    {:ok, socket} =
      :gen_tcp.connect(address, :ranch.get_port(name), [:inet6, :binary, active: false], 2_000)

    assert reply(socket) =~ "220 localhost"
    :gen_tcp.close(socket)
  end

  test "recipient cap rejects excess recipients and resets after DATA and RSET" do
    {_, port} = listener([], max_recipients: 3)
    socket = connect(port)
    assert command(socket, "RCPT TO:<early@example.net>") =~ "503 "
    assert command(socket, "MAIL FROM:<sender@example.org>") =~ "250 "
    recipients = ["first@example.net", "second@example.net", "third@example.net"]
    for recipient <- recipients, do: assert(command(socket, "RCPT TO:<#{recipient}>") =~ "250 ")
    assert command(socket, "RCPT TO:<excess@example.net>") =~ "452 "
    refute_receive {:inbound, _, {:recipient, "excess@example.net"}}
    send_data(socket)
    assert reply(socket) =~ "250 "
    assert_receive {:inbound, _, {:message, %{to: ^recipients}}}
    envelope(socket)
    assert command(socket, "RSET") =~ "250 "
    envelope(socket, "other@example.org", "again@example.net")
    send_data(socket)
    assert reply(socket) =~ "250 "
    assert_receive {:inbound, _, {:message, %{to: ["again@example.net"]}}}
  end

  test "default recipient cap accepts 100 recipients and rejects the next" do
    {_, port} = listener()
    socket = connect(port)
    assert command(socket, "MAIL FROM:<sender@example.org>") =~ "250 "

    for number <- 1..100,
        do: assert(command(socket, "RCPT TO:<user#{number}@example.net>") =~ "250 ")

    assert command(socket, "RCPT TO:<overflow@example.net>") =~ "452 "
  end

  test "listener controls reach Ranch and the session" do
    {name, port} =
      listener([],
        num_acceptors: 2,
        max_connections: 7,
        session_timeout: 200,
        allow_bare_newlines: :fix
      )

    assert :ranch.get_max_connections(name) == 7
    assert :ranch.get_transport_options(name).num_acceptors == 2
    socket = connect(port)
    envelope(socket)
    send_data(socket, "From: a@example.org\r\n\r\nHello\nworld\r\n")
    assert reply(socket) =~ "250 "

    assert_receive {:inbound, _,
                    {:message, %{data: "From: a@example.org\r\n\r\nHello\r\nworld\r\n"}}}

    assert reply(socket) =~ "421 "
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
  end

  test "rejects invalid or incomplete configuration before listening" do
    assert_raise ArgumentError, ~r/adapter/, fn -> Inbound.child_spec([]) end

    for options <- [%{}, [port: 2525, port: 2526]] do
      assert_raise ArgumentError, ~r/keyword list/, fn -> Inbound.child_spec(options) end
    end

    for {key, value} <- [
          adapter: nil,
          adapter: String,
          adapter: {TestInboundAdapter, %{}},
          adapter: {{TestInboundAdapter, []}, []},
          adapter: {TestInboundAdapter, [key: 1, key: 2]},
          hostname: "bad\r\nhost",
          address: "127.0.0.1",
          address: {256, 0, 0, 1},
          port: -1,
          port: 65_536,
          max_size: 0,
          max_size: :infinity,
          max_recipients: 0,
          max_connections: -1,
          num_acceptors: 0,
          session_timeout: 0,
          session_timeout: :infinity,
          tls_timeout: -1,
          allow_bare_newlines: true,
          tls_options: %{},
          unknown: true
        ] do
      assert_raise ArgumentError, "invalid inbound option: #{key}", fn ->
        Inbound.child_spec(Keyword.put([adapter: TestInboundAdapter], key, value))
      end
    end
  end
end
