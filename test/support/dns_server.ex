defmodule Postbeam.TestDNSServer do
  @moduledoc false

  def dns(records, options \\ []) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    parent = self()
    ttl = Keyword.get(options, :ttl, 0)
    pid = spawn(fn -> respond(socket, records, ttl, parent) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_udp.close(socket)
    end)

    [
      dns_timeout: 500,
      dns_options: [nameservers: [{{127, 0, 0, 1}, port}], alt_nameservers: [], retry: 1]
    ]
  end

  defp respond(socket, records, ttl, parent) do
    with {:ok, {ip, port, packet}} <- :gen_udp.recv(socket, 0, 5_000) do
      {:ok, query} = :inet_dns.decode(packet)
      [question] = :inet_dns.msg(query, :qdlist)
      domain = :inet_dns.dns_query(question, :domain)
      type = :inet_dns.dns_query(question, :type)
      send(parent, {:dns_query, to_string(domain), type})
      result = Map.get(records, {to_string(domain), type}, [])

      header =
        :inet_dns.make_header(:inet_dns.msg(query, :header),
          qr: true,
          ra: true,
          rcode: rcode(result)
        )

      response =
        :inet_dns.make_msg(query, header: header, anlist: answers(result, domain, type, ttl))

      :gen_udp.send(socket, ip, port, :inet_dns.encode(response))
      respond(socket, records, ttl, parent)
    end
  end

  defp rcode(:nxdomain), do: 3
  defp rcode(:servfail), do: 2
  defp rcode(_), do: 0

  defp answers(records, domain, type, ttl) when is_list(records) do
    Enum.map(records, fn
      {:rr, rr_type, data, rr_ttl} -> record(domain, rr_type, data, rr_ttl)
      data -> record(domain, type, data, ttl)
    end)
  end

  defp answers(_, _, _, _), do: []

  defp record(domain, type, data, ttl),
    do: :inet_dns.make_rr(domain: domain, type: type, class: :in, ttl: ttl, data: data)
end
