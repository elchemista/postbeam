defmodule Postbeam.Application do
  @moduledoc "Application supervisor for outbound deliveries and incoming DATA readers."

  alias Postbeam.SMTP.ClientSupervisor
  alias Postbeam.SMTP.DataSupervisor
  use Application

  @impl Application
  @doc false
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [
      {Task.Supervisor,
       name: ClientSupervisor,
       max_children: Application.get_env(:postbeam, :max_outbound_connections, 1024)},
      Supervisor.child_spec({Task.Supervisor, name: DataSupervisor},
        id: DataSupervisor
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Postbeam.SMTP.Supervisor)
  end
end
