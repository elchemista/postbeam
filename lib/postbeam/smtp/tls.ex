defmodule Postbeam.SMTP.TLS do
  @moduledoc false

  @doc false
  @spec client_options(list()) :: list()
  def client_options(options) do
    options = put_new(options, :verify, :verify_peer)

    if :proplists.get_value(:verify, options) == :verify_peer and
         not :proplists.is_defined(:cacerts, options) and
         not :proplists.is_defined(:cacertfile, options) do
      [{:cacerts, :public_key.cacerts_get()} | options]
    else
      options
    end
  end

  @doc false
  @spec server_options(list()) :: list()
  def server_options(options) do
    # Recent OTP releases require default credentials even when SNI is configured.
    case :proplists.get_value(:sni_hosts, options, []) do
      [{_host, defaults} | _] ->
        Enum.reduce(
          [:certs_keys, :cert, :certfile, :key, :keyfile],
          options,
          &inherit_option(&2, defaults, &1)
        )

      _ ->
        options
    end
  end

  @spec inherit_option(list(), list(), atom()) :: list()
  defp inherit_option(options, defaults, key) do
    case :proplists.get_value(key, defaults) do
      :undefined -> options
      value -> put_new(options, key, value)
    end
  end

  @spec put_new(list(), atom(), term()) :: list()
  defp put_new(options, key, value) do
    if :proplists.is_defined(key, options), do: options, else: [{key, value} | options]
  end
end
