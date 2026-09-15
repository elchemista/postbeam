# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Postbeam.SMTP.Delivery do
  @moduledoc false

  # Establish the optional caller link before returning the PID. This preserves
  # send/2's unlink/monitor contract even when the task scheduler is busy.
  def start(fun, link?) do
    owner = self()
    ready = make_ref()

    case Task.Supervisor.start_child(Postbeam.SMTP.ClientSupervisor, fn ->
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
         end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        receive do
          {^ready, ^pid} ->
            Process.demonitor(monitor, [:flush])
            send(pid, {ready, :run})
            {:ok, pid}

          {:DOWN, ^monitor, :process, ^pid, reason} ->
            {:error, reason}
        end

      error ->
        error
    end
  end
end
