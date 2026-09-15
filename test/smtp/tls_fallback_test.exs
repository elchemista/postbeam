defmodule Postbeam.SMTP.TLSFallbackTest do
  use ExUnit.Case, async: false

  alias Postbeam.TestReceiver
  import TestReceiver, only: [command: 3, greet: 1, envelope: 1, data: 1]

  test "opportunistic TLS logs a certificate failure before reconnecting in plaintext" do
    previous_level = :logger.get_module_level(Postbeam.SMTP.Client)
    :ok = :logger.set_module_level(Postbeam.SMTP.Client, :notice)

    on_exit(fn ->
      :logger.unset_module_level(Postbeam.SMTP.Client)
      for {module, level} <- previous_level, do: :logger.set_module_level(module, level)
    end)

    Postbeam.TestDNS.put("example.net", :a, {:ok, [{127, 0, 0, 1}]})

    {port, token} =
      TestReceiver.start([
        fn socket, _, _ ->
          :gen_tcp.send(socket, "220 local.test ESMTP\r\n")
          command(socket, "EHLO", "250-local.test\r\n250 STARTTLS")
          command(socket, "STARTTLS", "220 go ahead")

          assert {:error, _} =
                   :ssl.handshake(socket,
                     certfile: ~c"test/smtp/fixtures/mx1.example.com-server.crt",
                     keyfile: ~c"test/smtp/fixtures/mx1.example.com-server.key"
                   )
        end,
        fn socket, _, _ ->
          greet(socket)
          envelope(socket)
          data(socket)
          :gen_tcp.send(socket, "250 fallback-accepted\r\n")
        end
      ])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{receipt: "fallback-accepted\r\n"}} =
                 Postbeam.deliver(
                   [
                     from: "sender@example.com",
                     to: "user@example.net",
                     subject: "TLS",
                     text: "body"
                   ],
                   resolver: Postbeam.TestDNS,
                   hostname: "mta.example.com",
                   port: port,
                   tls: :if_available,
                   tls_options: [cacertfile: ~c"test/smtp/fixtures/root.crt"]
                 )

        TestReceiver.done(token)
      end)

    assert log =~ "retrying without encryption because tls is :if_available"
  end
end
