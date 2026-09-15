defmodule Postbeam.Application do
  @moduledoc "Application supervisor for outbound deliveries and incoming DATA readers."
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor,
       name: Postbeam.SMTP.ClientSupervisor,
       max_children: Application.get_env(:postbeam, :max_outbound_connections, 1024)},
      Supervisor.child_spec({Task.Supervisor, name: Postbeam.SMTP.DataSupervisor},
        id: Postbeam.SMTP.DataSupervisor
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Postbeam.SMTP.Supervisor)
  end
end
