defmodule Postbeam.DNSTest do
  use ExUnit.Case, async: true
  alias Postbeam.TestReceiver
  import Postbeam.TestDNSServer, only: [dns: 1]

  test "OTP resolver distinguishes NODATA, Null MX and NXDOMAIN over actual local DNS" do
    options =
      dns(%{
        {"mx.test", :mx} => [{10, ~c"mail.test"}],
        {"null.test", :mx} => [{0, ~c""}],
        {"missing.test", :mx} => :nxdomain
      })

    assert {:ok, ["mail.test"]} = Postbeam.MX.resolve("mx.test", options)
    assert {:ok, ["empty.test"]} = Postbeam.MX.resolve("empty.test", options)
    assert {:error, {:null_mx, "null.test"}} = Postbeam.MX.resolve("null.test", options)

    assert {:error, {:dns, "missing.test", :mx, :nxdomain}} =
             Postbeam.MX.resolve("missing.test", options)
  end

  test "full DNS to SMTP path uses default adapters with local receivers" do
    options =
      dns(%{
        {"example.net", :mx} => [{10, ~c"mail.test"}],
        {"mail.test", :a} => [{127, 0, 0, 1}]
      })

    {port, token} =
      TestReceiver.start(fn socket, _, _ ->
        TestReceiver.greet(socket)
        TestReceiver.envelope(socket)
        TestReceiver.data(socket)
        :gen_tcp.send(socket, "250 dns-to-smtp\r\n")
      end)

    assert {:ok, %{mx: "mail.test", receipt: "dns-to-smtp\r\n"}} =
             Postbeam.deliver(
               [from: "a@example.com", to: "b@example.net", subject: "Full flow", text: "Hello"],
               options ++
                 [hostname: "mta.example.com", port: port, tls: :never, smtp_timeout: 2_000]
             )

    TestReceiver.done(token)
  end
end
