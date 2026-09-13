defmodule Postbeam.DKIM do
  @moduledoc """
  Generates, persists and reuses RSA DKIM keys without external commands.

  Call `setup/1` from application code to obtain the public DNS record. It accepts
  the same options as `Postbeam.deliver/2`, including application defaults:

      {:ok, record} = Postbeam.DKIM.setup(dkim: [d: "example.com", s: "postbeam"])
      # Publish record.value at record.name (or record.host in your DNS zone).

  RSA keys are 2048 bits. Managed signing omits `:private_key`; the default store
  is `Postbeam.KeyStore.File`. Configured managed keys are prepared when the
  Postbeam application starts, and per-call keys on first delivery. Subsequent
  calls read the existing key. Stores needed during application startup must
  already be running (for example, in an OTP application dependency).

  An unreadable, corrupt or non-RSA stored key fails closed. To rotate, choose a
  new selector, call `setup/1`, publish its record, then switch delivery settings.
  No DNS is modified and no email is sent by this module.
  """
  alias Postbeam.{Config, Store}

  @type dns_record :: %{
          type: :txt,
          name: String.t(),
          host: String.t(),
          value: String.t()
        }
  @type error :: {:dkim, term()}

  @doc "Creates or loads a managed key and returns only its public DNS record."
  @spec setup(keyword()) :: {:ok, dns_record()} | {:error, Config.error() | error()}
  def setup(options \\ []) do
    with {:ok, config} <- Config.new(options),
         {:ok, dkim} <- managed(config[:dkim]),
         {:ok, _pem, key} <- load(dkim, config[:key_store]) do
      {:SubjectPublicKeyInfo, der, :not_encrypted} =
        :public_key.pem_entry_encode(
          :SubjectPublicKeyInfo,
          {:RSAPublicKey, elem(key, 2), elem(key, 3)}
        )

      host = String.downcase(dkim[:s]) <> "._domainkey"

      {:ok,
       %{
         type: :txt,
         host: host,
         name: host <> "." <> String.downcase(dkim[:d]),
         value: "v=DKIM1; k=rsa; p=" <> Base.encode64(der)
       }}
    end
  end

  @doc false
  @spec prepare(Config.t()) :: {:ok, Config.t()} | {:error, error()}
  def prepare(config) do
    case config[:dkim] do
      nil -> {:ok, config}
      dkim -> prepare_key(dkim, config)
    end
  end

  defp prepare_key(dkim, config) do
    if Keyword.has_key?(dkim, :private_key) do
      {:ok, config}
    else
      with {:ok, pem, _key} <- load(dkim, config[:key_store]) do
        {:ok, Keyword.put(config, :dkim, Keyword.put(dkim, :private_key, {:pem_plain, pem}))}
      end
    end
  end

  defp managed(nil), do: {:error, {:dkim, :not_configured}}

  defp managed(dkim) do
    if Keyword.has_key?(dkim, :private_key),
      do: {:error, {:dkim, :explicit_private_key}},
      else: {:ok, dkim}
  end

  defp load(dkim, store) do
    id = {String.downcase(dkim[:d]), String.downcase(dkim[:s])}

    case Store.call(store, :fetch, [id]) do
      :not_found -> generate(id, store)
      result -> stored(result)
    end
  end

  defp generate(id, store) do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    case Store.call(store, :put_new, [id, pem]) do
      :ok -> {:ok, pem, key}
      {:error, :already_exists} -> stored(Store.call(store, :fetch, [id]))
      result -> store_error(result)
    end
  rescue
    error -> {:error, {:dkim, {:generation, error.__struct__}}}
  end

  defp stored({:ok, pem}) do
    with {:ok, key} <- decode(pem), do: {:ok, pem, key}
  end

  defp stored(result), do: store_error(result)

  defp store_error({:error, reason}), do: {:error, {:dkim, {:store, reason}}}
  defp store_error(_), do: {:error, {:dkim, :invalid_store_response}}

  defp decode(pem) do
    with [entry] <- :public_key.pem_decode(pem),
         {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key <-
           :public_key.pem_entry_decode(entry) do
      {:ok, key}
    else
      _ -> {:error, {:dkim, :invalid_private_key}}
    end
  rescue
    _ -> {:error, {:dkim, :invalid_private_key}}
  catch
    _, _ -> {:error, {:dkim, :invalid_private_key}}
  end
end
