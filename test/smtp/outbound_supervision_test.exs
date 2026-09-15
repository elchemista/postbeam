defmodule Postbeam.SMTP.OutboundSupervisionTest do
  use ExUnit.Case, async: false

  alias Postbeam.SMTP.ClientSupervisor
  alias Postbeam.TestDNS
  alias Postbeam.TestReceiver

  defp deliver(port) do
    Postbeam.deliver(
      [from: "sender@example.com", to: "user@example.net", subject: "Capacity", text: "Hello"],
      resolver: TestDNS,
      hostname: "mta.example.com",
      tls: :never,
      port: port,
      smtp_timeout: 2000
    )
  end

  test "public deliveries use the shared supervisor and release capacity when done" do
    TestDNS.put("example.net", :a, {:ok, [{127, 0, 0, 1}]})

    {port, token} =
      TestReceiver.start(fn socket, parent, token ->
        send(parent, {token, :connected})
        TestReceiver.greet(socket)
        TestReceiver.envelope(socket)
        TestReceiver.data(socket)
        assert [_worker] = Task.Supervisor.children(ClientSupervisor)
        :gen_tcp.send(socket, "250 queued\r\n")
      end)

    assert {:ok, _} = deliver(port)
    TestReceiver.done(token)
    assert Task.Supervisor.children(ClientSupervisor) == []
    refute_receive {:DOWN, _, :process, _, _}
    refute_receive {_, :result, _}
  end

  test "the shared capacity limit prevents public deliveries from opening sockets" do
    limit = Application.get_env(:postbeam, :max_outbound_connections, 1024)
    owner = self()

    workers =
      for _ <- 1..limit do
        {:ok, pid} =
          Task.Supervisor.start_child(ClientSupervisor, fn ->
            monitor = Process.monitor(owner)

            receive do
              :release -> :ok
              {:DOWN, ^monitor, :process, ^owner, _} -> :ok
            end
          end)

        pid
      end

    on_exit(fn -> Enum.each(workers, &Process.exit(&1, :kill)) end)
    TestDNS.put("example.net", :a, {:ok, [{127, 0, 0, 1}]})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    assert {:error, {:exhausted, details}} = deliver(port)
    assert inspect(details) =~ "max_children"
    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
    assert length(Task.Supervisor.children(ClientSupervisor)) == limit

    for worker <- workers do
      monitor = Process.monitor(worker)
      send(worker, :release)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
    end

    assert Task.Supervisor.children(ClientSupervisor) == []
  end
end
