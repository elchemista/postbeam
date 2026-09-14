defmodule Postbeam.StorageTest.FailingKeyStore do
  @moduledoc false
  alias Postbeam.KeyStore
  @behaviour KeyStore
  @impl KeyStore
  @doc false
  @spec fetch(KeyStore.id(), keyword()) :: {:ok, binary()} | :not_found | {:error, term()}
  def fetch(_id, options) do
    case options[:fetch] do
      :raise -> raise ArgumentError, "secret"
      :throw -> throw(:secret)
      :exit -> exit(:secret)
      result -> result
    end
  end

  @impl KeyStore
  @doc false
  @spec put_new(KeyStore.id(), binary(), keyword()) :: :ok | {:error, term()}
  def put_new(_id, _pem, options), do: options[:put]
end
