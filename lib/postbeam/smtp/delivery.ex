defmodule Postbeam.SMTP.Delivery do
  @moduledoc false

  alias Postbeam.SMTP.ClientSupervisor

  # Establish the optional caller link before returning the PID. This preserves
  # send/2's unlink/monitor contract even when the task scheduler is busy.
  @doc false
  @spec start((-> term()), boolean()) :: {:ok, pid()} | {:error, term()}
  def start(fun, link?), do: start_delivery(fun, link?, false)

  @doc false
  @spec start_monitor((-> term())) :: {:ok, pid(), reference()} | {:error, term()}
  def start_monitor(fun), do: start_delivery(fun, false, true)

  @spec start_delivery((-> term()), boolean(), boolean()) ::
          {:ok, pid()} | {:ok, pid(), reference()} | {:error, term()}
  defp start_delivery(fun, link?, monitor?) do
    owner = self()
    ready = make_ref()

    with {:ok, pid} <-
           Task.Supervisor.start_child(ClientSupervisor, fn ->
             await_start(owner, ready, link?, fun)
           end) do
      await_ready(pid, ready, monitor?)
    end
  end

  @spec await_start(pid(), reference(), boolean(), (-> term())) :: term()
  defp await_start(owner, ready, link?, fun) do
    monitor = Process.monitor(owner)
    if link?, do: Process.link(owner)
    send(owner, {ready, self()})

    receive do
      {^ready, :run} ->
        Process.demonitor(monitor, [:flush])
        fun.()

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok
    end
  end

  @spec await_ready(pid(), reference(), boolean()) ::
          {:ok, pid()} | {:ok, pid(), reference()} | {:error, term()}
  defp await_ready(pid, ready, monitor?) do
    monitor = Process.monitor(pid)

    receive do
      {^ready, ^pid} ->
        if not monitor?, do: Process.demonitor(monitor, [:flush])
        send(pid, {ready, :run})
        if monitor?, do: {:ok, pid, monitor}, else: {:ok, pid}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, reason}
    end
  end
end
