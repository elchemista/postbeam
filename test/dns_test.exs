defmodule Postbeam.DNSTest do
  use ExUnit.Case, async: true
  alias Postbeam.TestReceiver

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

  defp dns(records) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    pid = spawn(fn -> respond(socket, records) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_udp.close(socket)
    end)

    [
      dns_timeout: 500,
      dns_options: [nameservers: [{{127, 0, 0, 1}, port}], alt_nameservers: [], retry: 1]
    ]
  end

  defp respond(socket, records) do
    with {:ok, {ip, port, packet}} <- :gen_udp.recv(socket, 0, 5_000) do
      {:ok, query} = :inet_dns.decode(packet)
      [question] = :inet_dns.msg(query, :qdlist)
      domain = :inet_dns.dns_query(question, :domain)
      type = :inet_dns.dns_query(question, :type)
      result = Map.get(records, {to_string(domain), type}, [])

      answers = answers(result, domain, type)

      header =
        :inet_dns.make_header(:inet_dns.msg(query, :header),
          qr: true,
          ra: true,
          rcode: if(result == :nxdomain, do: 3, else: 0)
        )

      response = :inet_dns.make_msg(query, header: header, anlist: answers)
      :gen_udp.send(socket, ip, port, :inet_dns.encode(response))
      respond(socket, records)
    end
  end

  defp answers(records, domain, type) when is_list(records) do
    for data <- records,
        do: :inet_dns.make_rr(domain: domain, type: type, class: :in, ttl: 0, data: data)
  end

  defp answers(_, _, _), do: []
end
