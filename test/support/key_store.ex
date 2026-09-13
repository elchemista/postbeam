defmodule Postbeam.StorageTest.Store do
  @moduledoc false
  alias Postbeam.KeyStore
  @behaviour KeyStore

  @impl KeyStore
  @doc false
  @spec fetch(KeyStore.id(), keyword()) :: {:ok, binary()} | :not_found | {:error, term()}
  def fetch(id, options), do: Agent.get(options[:agent], &Map.get(&1, id, :not_found))

  @impl KeyStore
  @doc false
  @spec put_new(KeyStore.id(), binary(), keyword()) :: :ok | {:error, term()}
  def put_new(id, pem, options) do
    Agent.get_and_update(options[:agent], fn keys ->
      if Map.has_key?(keys, id),
        do: {{:error, :already_exists}, keys},
        else: {:ok, Map.put(keys, id, {:ok, pem})}
    end)
  end
end
