defmodule Postbeam.SMTP.OTPTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  defp listener(opts \\ []) do
    name = {__MODULE__, make_ref()}

    callback = [
      owner: self(),
      hold: Keyword.get(opts, :hold, false),
      tls: Keyword.get(opts, :tls, false)
    ]

    session = [
      callbackoptions: callback,
      tls_options: [
        certfile: ~c"test/smtp/fixtures/mx1.example.com-server.crt",
        keyfile: ~c"test/smtp/fixtures/mx1.example.com-server.key"
      ]
    ]

    start_supervised!(
      {Postbeam.SMTP.Server,
       {Postbeam.SMTP.TestHandler,
        [
          name: name,
          address: {127, 0, 0, 1},
          port: 0,
          domain: ~c"localhost",
          num_acceptors: 2,
          max_connections: 16,
          protocol: Keyword.get(opts, :transport, :tcp),
          ranch_opts: %{
            socket_opts: if(opts[:transport] == :ssl, do: session[:tls_options], else: [])
          },
          sessionoptions: session
        ]}}
    )

    options = [
      relay: ~c"127.0.0.1",
      port: :ranch.get_port(name),
      no_mx_lookups: true,
      hostname: "localhost",
      retries: 0
    ]

    {name, options}
  end

  defp email(body \\ "hello"), do: {"sender@example.com", ["recipient@example.com"], body}

  test "bounded concurrent deliveries are supervised and preserve results" do
    {_name, opts} = listener(hold: true)

    task =
      Task.async(fn ->
        Postbeam.SMTP.Client.send_many(Enum.map(1..4, &email("message #{&1}")), opts,
          max_concurrency: 2,
          timeout: 5000
        )
        |> Enum.to_list()
      end)

    assert_receive {:delivery_started, first, _, _, _}, 2000
    assert_receive {:delivery_started, second, _, _, _}, 2000
    assert length(Task.Supervisor.children(Postbeam.SMTP.ClientSupervisor)) == 2
    refute_receive {:delivery_started, _, _, _, _}, 100
    send(first, :release)
    assert_receive {:delivery_started, third, _, _, _}, 2000
    send(second, :release)
    assert_receive {:delivery_started, fourth, _, _, _}, 2000
    send(third, :release)
    send(fourth, :release)
    assert Task.await(task, 5000) == List.duplicate({:ok, "queued\r\n"}, 4)
  end

  test "a failed asynchronous delivery does not terminate the caller or restart the message" do
    {_name, opts} = listener(hold: true)
    {:ok, worker} = Postbeam.SMTP.Client.send_async(email(), opts)
    monitor = Process.monitor(worker)
    assert_receive {:delivery_started, session, _, _, _}, 2000
    assert worker in Task.Supervisor.children(Postbeam.SMTP.ClientSupervisor)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2000
    send(session, :release)
    refute_receive {:delivery_started, _, _, _, _}, 100
    assert Process.alive?(Process.whereis(Postbeam.SMTP.ClientSupervisor))
  end

  test "a session closing during DATA also stops its supervised reader" do
    {name, opts} = listener()

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", opts[:port], [:binary, packet: :line, active: false])

    assert {:ok, _} = :gen_tcp.recv(socket, 0, 1000)

    for {command, code} <- [
          {"HELO test", "250"},
          {"MAIL FROM:<a@b.com>", "250"},
          {"RCPT TO:<c@d.com>", "250"},
          {"DATA", "354"}
        ] do
      :ok = :gen_tcp.send(socket, command <> "\r\n")
      assert {:ok, response} = :gen_tcp.recv(socket, 0, 1000)
      assert String.starts_with?(response, code)
    end

    [session] = Postbeam.SMTP.Server.sessions(name)
    %Postbeam.SMTP.Session.State{reader: %Task{pid: reader}} = :sys.get_state(session)
    assert reader in Task.Supervisor.children(Postbeam.SMTP.DataSupervisor)
    monitor = Process.monitor(reader)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 2000
    :gen_tcp.close(socket)
  end

  test "the link is established before send returns so callers can unlink reliably" do
    {_name, opts} = listener(hold: true)
    {:ok, worker} = Postbeam.SMTP.Client.send(email(), opts)
    assert worker in elem(Process.info(self(), :links), 1)
    Process.unlink(worker)
    assert_receive {:delivery_started, session, _, _, _}, 2000
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2000
    send(session, :release)
  end

  test "code_change accepts a new handler state" do
    state = %Postbeam.SMTP.Session.State{
      module: Postbeam.SMTP.TestHandler,
      callbackstate: %{version: 1}
    }

    assert {:ok, %{callbackstate: %{version: 1, upgraded: true}}} =
             Postbeam.SMTP.Session.code_change(:old, state, [])
  end

  test "STARTTLS verifies a configured CA and hostname" do
    {_name, opts} = listener(tls: true)

    opts =
      Keyword.merge(opts,
        tls: :always,
        tls_options: [
          cacertfile: ~c"test/smtp/fixtures/root.crt",
          server_name_indication: ~c"mx1.example.com"
        ]
      )

    assert Postbeam.SMTP.Client.send_blocking(email(), opts) == "queued\r\n"
    assert_receive {:delivery_started, _, _, _, "hello"}, 2000
  end

  test "required TLS cannot fall back to plaintext after certificate verification fails" do
    {_name, opts} = listener(tls: true)

    opts =
      Keyword.merge(opts,
        tls: :always,
        tls_options: [
          cacerts: [],
          server_name_indication: ~c"mx1.example.com"
        ]
      )

    assert {:error, :retries_exceeded, {:temporary_failure, _, :tls_failed}} =
             Postbeam.SMTP.Client.send_blocking(email(), opts)

    refute_receive {:delivery_started, _, _, _, _}, 100
  end

  test "implicit TLS honors tls_options and does not attempt a second STARTTLS" do
    {_name, opts} = listener(transport: :ssl)

    opts =
      Keyword.merge(opts,
        ssl: true,
        tls: :always,
        relay: {127, 0, 0, 1},
        tls_options: [
          cacertfile: ~c"test/smtp/fixtures/root.crt",
          server_name_indication: ~c"mx1.example.com"
        ]
      )

    assert Postbeam.SMTP.Client.send_blocking(email(), opts) == "queued\r\n"
    assert_receive {:delivery_started, _, _, _, "hello"}, 2000
  end

  test "malformed SMTP replies return errors and close the connection" do
    for response <- ["\r\n", "bad reply\r\n", "220-first line\r\n\r\n"] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_address, port}} = :inet.sockname(listener)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2000)
          :ok = :gen_tcp.send(socket, response)
          assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2000)
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
        end)

      assert {:error, :retries_exceeded, {:unexpected_response, _, _}} =
               Postbeam.SMTP.Client.send_blocking(email(),
                 relay: {127, 0, 0, 1},
                 port: port,
                 retries: 0
               )

      Task.await(server)
    end
  end

  test "LMTP is rejected on port 25 before a listener starts" do
    assert {:error, :invalid_lmtp_port} =
             Postbeam.SMTP.Server.start(make_ref(), Postbeam.SMTP.TestHandler,
               port: 25,
               sessionoptions: [protocol: :lmtp]
             )
  end

  test "invalid ports are rejected before spawning a delivery" do
    for port <- [-1, 0, 65_536, "25"] do
      assert {:error, :invalid_port} =
               Postbeam.SMTP.Client.send_async(email(), relay: "localhost", port: port)
    end
  end
end
