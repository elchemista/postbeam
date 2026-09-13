defmodule Postbeam.SMTPTest do
  use ExUnit.Case, async: true
  alias Postbeam.{TestDNS, TestReceiver}
  import TestReceiver, only: [command: 3, greet: 1, envelope: 1, data: 1]

  @message [from: "sender@example.com", to: "user@example.net", subject: "Local", text: "Caffè ☕"]

  defp deliver(port, overrides \\ []) do
    options = [
      resolver: TestDNS,
      hostname: "mta.example.com",
      port: port,
      tls: :never,
      smtp_timeout: 2_000,
      connect_timeout: 200
    ]

    Postbeam.deliver(@message, Keyword.merge(options, overrides))
  end

  setup do
    TestDNS.put("example.net", :a, {:ok, [{127, 0, 0, 1}]})
    :ok
  end

  test "full local SMTP delivery checks EHLO, envelope, MIME and no authentication" do
    {port, token} =
      TestReceiver.start(fn socket, parent, token ->
        greet(socket)
        {from, to} = envelope(socket)
        mime = data(socket)
        :gen_tcp.send(socket, "250 queued-local\r\n")
        send(parent, {token, from, to, mime})
      end)

    assert {:ok, %{receipt: "queued-local\r\n", message_id: id}} = deliver(port)

    assert_receive {^token, "MAIL FROM:<sender@example.com>\r\n",
                    "RCPT TO:<user@example.net>\r\n", mime}

    assert mime =~ "Message-ID: #{id}"
    assert {"text", "plain", _, _, "Caffè ☕"} = :mimemail.decode(mime, encoding: :none)
    TestReceiver.done(token)
  end

  test "tries next MX when its predecessor is unreachable" do
    TestDNS.put("example.net", :mx, {:ok, [{1, "bad.test"}, {2, "good.test"}]})
    TestDNS.put("bad.test", :a, {:ok, [{127, 0, 0, 2}]})
    TestDNS.put("good.test", :a, {:ok, [{127, 0, 0, 1}]})

    {port, token} =
      TestReceiver.start(fn socket, _, _ ->
        greet(socket)
        envelope(socket)
        data(socket)
        :gen_tcp.send(socket, "250 accepted\r\n")
      end)

    assert {:ok, %{mx: "good.test"}} = deliver(port)
    TestReceiver.done(token)
  end

  test "temporary and permanent envelope rejections preserve the server response" do
    for {code, kind} <- [{"450 later", :exhausted}, {"550 no mailbox", :permanent}] do
      {port, token} =
        TestReceiver.start(fn socket, _, _ ->
          greet(socket)
          command(socket, "MAIL FROM:", "250 ok")
          command(socket, "RCPT TO:", code)
        end)

      assert {:error, {^kind, details}} = deliver(port)
      assert inspect(details) =~ code
      TestReceiver.done(token)
    end
  end

  test "explicit DATA rejection is retryable or permanent, never uncertain" do
    for {code, kind} <- [{"451 try later", :exhausted}, {"554 rejected", :permanent}] do
      {port, token} =
        TestReceiver.start(fn socket, _, _ ->
          greet(socket)
          envelope(socket)
          data(socket)
          :gen_tcp.send(socket, code <> "\r\n")
        end)

      assert {:error, {^kind, details}} = deliver(port)
      assert inspect(details) =~ code
      TestReceiver.done(token)
    end
  end

  test "lost receipt is uncertain and never falls through to another MX" do
    TestDNS.put("example.net", :mx, {:ok, [{1, "first.test"}, {2, "second.test"}]})
    TestDNS.put("first.test", :a, {:ok, [{127, 0, 0, 1}]})

    {port, token} =
      TestReceiver.start(fn socket, _, _ ->
        greet(socket)
        envelope(socket)
        data(socket)
        # Close after the final dot without an acceptance or rejection.
      end)

    assert {:error, {:uncertain, %{mx: "first.test", reason: _}}} =
             deliver(port)

    refute_receive {:dns, "second.test", _}
    TestReceiver.done(token)
  end

  test "connection loss before DATA remains retryable" do
    {port, token} =
      TestReceiver.start(fn socket, _, _ ->
        greet(socket)
        command(socket, "MAIL FROM:", nil)
      end)

    assert {:error, {:exhausted, _}} = deliver(port)
    TestReceiver.done(token)
  end

  test "deadline closes a stalled greeting and a stalled receipt with different outcomes" do
    for {phase, kind} <- [{:greeting, :exhausted}, {:receipt, :uncertain}] do
      {port, token} =
        TestReceiver.start(fn socket, _, _ ->
          if phase == :receipt do
            greet(socket)
            envelope(socket)
            data(socket)
          end

          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        end)

      start = System.monotonic_time(:millisecond)
      assert {:error, {^kind, _}} = deliver(port, smtp_timeout: 300)
      assert System.monotonic_time(:millisecond) - start < 1_500
      TestReceiver.done(token)
    end
  end

  test "required STARTTLS fails before the envelope when not advertised" do
    {port, token} =
      TestReceiver.start(fn socket, _, _ ->
        greet(socket)
        command(socket, "QUIT", nil)
      end)

    assert {:error, {:exhausted, details}} = deliver(port, tls: :always)
    assert inspect(details) =~ "missing_requirement"
    TestReceiver.done(token)
  end

  test "both A/AAAA errors are retained, but working IPv6 is usable when A fails" do
    TestDNS.put("example.net", :a, {:error, :servfail})
    TestDNS.put("example.net", :aaaa, {:error, :timeout})
    assert {:error, {:exhausted, details}} = deliver(25)
    assert inspect(details) =~ "servfail"
    assert inspect(details) =~ "timeout"

    loopback = {0, 0, 0, 0, 0, 0, 0, 1}
    TestDNS.put("example.net", :aaaa, {:ok, [loopback]})

    {port, token} =
      TestReceiver.start(
        fn socket, _, _ ->
          greet(socket)
          envelope(socket)
          data(socket)
          :gen_tcp.send(socket, "250 ipv6\r\n")
        end,
        ip: loopback
      )

    assert {:ok, %{receipt: "ipv6\r\n"}} = deliver(port)
    TestReceiver.done(token)
  end

  test "temporary DATA rejection falls through to another MX with identical signed bytes" do
    TestDNS.put("example.net", :mx, {:ok, [{1, "first.test"}, {2, "second.test"}]})
    TestDNS.put("first.test", :a, {:ok, [{127, 0, 0, 2}]})
    TestDNS.put("second.test", :a, {:ok, [{127, 0, 0, 1}]})

    conversation = fn reply ->
      fn socket, parent, token ->
        greet(socket)
        envelope(socket)
        send(parent, {token, data(socket)})
        :gen_tcp.send(socket, reply <> "\r\n")
      end
    end

    {port, first} = TestReceiver.start(conversation.("451 later"), ip: {127, 0, 0, 2})
    {^port, second} = TestReceiver.start(conversation.("250 accepted"), port: port)
    key = :public_key.generate_key({:rsa, 1024, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:ok, %{mx: "second.test"}} =
             deliver(port,
               dkim: [d: "example.com", s: "test", private_key: {:pem_plain, pem}]
             )

    assert_receive {^first, first_data}
    assert_receive {^second, second_data}
    assert first_data == second_data
    assert first_data =~ "DKIM-Signature:"
    TestReceiver.done(first)
    TestReceiver.done(second)
  end

  test "STARTTLS encrypts delivery and verifies the MX hostname" do
    ipv6 = {0, 0, 0, 0, 0, 0, 0, 1}

    for {cert_host, expected, address} <- [
          {~c"example.net", :ok, {127, 0, 0, 1}},
          {~c"example.net", :ok, ipv6},
          {~c"wrong.test", :error, {127, 0, 0, 1}}
        ] do
      TestDNS.put("example.net", :a, {:ok, if(address == ipv6, do: [], else: [address])})
      TestDNS.put("example.net", :aaaa, {:ok, if(address == ipv6, do: [address], else: [])})

      certificate =
        :public_key.pkix_test_data(%{
          root: [digest: :sha256, key: {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}],
          intermediates: [[digest: :sha256, key: {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}]],
          peer: [
            digest: :sha256,
            key: {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}},
            extensions: [
              {:Extension, {2, 5, 29, 17}, false, [{:dNSName, cert_host}]}
            ]
          ]
        })

      {port, token} =
        TestReceiver.start(
          fn socket, _, _ ->
            :gen_tcp.send(socket, "220 local.test ESMTP\r\n")
            command(socket, "EHLO", "250-local.test\r\n250 STARTTLS")
            command(socket, "STARTTLS", "220 go ahead")

            case :ssl.handshake(socket, certificate ++ [active: false, packet: :line], 2_000) do
              {:ok, secure} ->
                assert expected == :ok
                command(secure, "EHLO", "250 local.test")
                envelope(secure)
                data(secure)
                :ssl.send(secure, "250 encrypted\r\n")
                :ssl.close(secure)

              {:error, reason} ->
                assert expected == :error, "TLS handshake failed: #{inspect(reason)}"
            end
          end,
          ip: address
        )

      result = deliver(port, tls: :always, tls_options: [cacerts: certificate[:cacerts]])
      TestReceiver.done(token)

      if expected == :ok do
        assert {:ok, %{receipt: "encrypted\r\n"}} = result
      else
        assert {:error, {:exhausted, _}} = result
      end
    end
  end

  test "disconnect at DATA before 354 is conservatively uncertain" do
    {port, token} =
      TestReceiver.start(fn socket, _, _ ->
        greet(socket)
        envelope(socket)
        command(socket, "DATA", nil)
      end)

    assert {:error, {:uncertain, _}} = deliver(port)
    TestReceiver.done(token)
    refute_receive {:DOWN, _, :process, _, _}
    refute_receive {_, :data}
    refute_receive {_, :envelope}
  end

  test "malformed final reply is uncertain rather than retryable" do
    {port, token} =
      TestReceiver.start(fn socket, _, _ ->
        greet(socket)
        envelope(socket)
        data(socket)
        :gen_tcp.send(socket, "nonsense\r\n")
      end)

    assert {:error, {:uncertain, _}} = deliver(port)
    TestReceiver.done(token)
  end

  test "server greeting rejection permits fallback and preserves diagnostic" do
    {port, token} =
      TestReceiver.start(fn socket, _, _ ->
        :gen_tcp.send(socket, "554 this host is unavailable\r\n")
      end)

    assert {:error, {:exhausted, details}} = deliver(port)
    assert inspect(details) =~ "554 this host is unavailable"
    TestReceiver.done(token)
  end

  test "worker closes its socket within its deadline even if the caller dies" do
    {port, token} =
      TestReceiver.start(fn socket, parent, token ->
        send(parent, {token, :connected})
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    pid =
      spawn(fn ->
        TestDNS.put("example.net", :a, {:ok, [{127, 0, 0, 1}]})
        deliver(port, smtp_timeout: 300)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {^token, :connected}, 1_000
    Process.exit(pid, :kill)
    TestReceiver.done(token)
  end
end
