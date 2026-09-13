defmodule Postbeam.TestDNS do
  @moduledoc false
  @behaviour Postbeam.MX

  def put(domain, type, result), do: Process.put({__MODULE__, domain, type}, result)

  @impl true
  def lookup(domain, type, _options) do
    send(self(), {:dns, domain, type})
    Process.get({__MODULE__, domain, type}, {:ok, []})
  end
end

defmodule Postbeam.TestTransport do
  @moduledoc false
  @behaviour Postbeam.SMTP

  @impl true
  def deliver(host, message, options) do
    send(self(), {:attempt, host, message, options})
    Process.get({__MODULE__, host}, {:ok, "queued"})
  end
end

defmodule Postbeam.TestReceiver do
  @moduledoc false
  import ExUnit.Assertions

  # Each test owns a passive socket and supplies a short SMTP conversation.
  def start(conversation, options \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(Keyword.get(options, :port, 0), [
        :binary,
        active: false,
        packet: :line,
        ip: Keyword.get(options, :ip, {127, 0, 0, 1})
      ])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()
    token = make_ref()

    pid =
      spawn(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          conversation.(socket, parent, token)
          :gen_tcp.close(socket)
          send(parent, {token, :done})
        rescue
          error -> send(parent, {token, {:failed, error, __STACKTRACE__}})
        after
          :gen_tcp.close(listener)
        end
      end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    {port, token}
  end

  def command(socket, prefix, reply) do
    {:ok, line} = :smtp_socket.recv(socket, 0, 3_000)
    assert String.starts_with?(line, prefix), "Expected #{prefix}, got #{inspect(line)}"
    if reply, do: :smtp_socket.send(socket, reply <> "\r\n")
    line
  end

  def greet(socket) do
    :smtp_socket.send(socket, "220 local.test ESMTP\r\n")
    command(socket, "EHLO mta.example.com", "250-local.test\r\n250 AUTH PLAIN")
  end

  def envelope(socket) do
    from = command(socket, "MAIL FROM:", "250 sender ok")
    to = command(socket, "RCPT TO:", "250 recipient ok")
    {from, to}
  end

  def data(socket) do
    command(socket, "DATA", "354 continue")
    read_data(socket, [])
  end

  defp read_data(socket, acc) do
    case :smtp_socket.recv(socket, 0, 3_000) do
      {:ok, ".\r\n"} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, line} -> read_data(socket, [line | acc])
      other -> flunk("Incomplete message: #{inspect(other)}")
    end
  end

  def done(token) do
    receive do
      {^token, :done} -> :ok
      {^token, {:failed, error, stack}} -> reraise(error, stack)
    after
      4_000 -> flunk("SMTP receiver did not finish")
    end
  end
end
