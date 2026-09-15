# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Postbeam.SMTP.TLS do
  @moduledoc false

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

  def server_options(options) do
    # Recent OTP releases require default credentials even when SNI is configured.
    case :proplists.get_value(:sni_hosts, options, []) do
      [{_host, defaults} | _] ->
        Enum.reduce([:certs_keys, :cert, :certfile, :key, :keyfile], options, fn key, acc ->
          case :proplists.get_value(key, defaults) do
            :undefined -> acc
            value -> put_new(acc, key, value)
          end
        end)

      _ ->
        options
    end
  end

  defp put_new(options, key, value) do
    if :proplists.is_defined(key, options), do: options, else: [{key, value} | options]
  end
end
