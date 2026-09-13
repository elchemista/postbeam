defmodule Postbeam.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, config} <- Postbeam.Config.new([]),
         {:ok, _} <- Postbeam.DKIM.prepare(config) do
      Supervisor.start_link([Postbeam.SentStore.ETS],
        strategy: :one_for_one,
        name: Postbeam.Supervisor
      )
    end
  end
end
