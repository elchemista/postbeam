defmodule Postbeam.KeyStore do
  @moduledoc """
  Persistence contract for managed RSA DKIM private keys.

  Adapters are a module or `{module, options}`. Keys are indexed by normalized
  `{domain, selector}`. `fetch/2` returns an unencrypted PEM or `:not_found`.
  `put_new/3` MUST atomically create only when absent, returning
  `{:error, :already_exists}` when another caller wins. Postbeam then reads the
  winner. Never overwrite keys: changing a published key breaks verification.

  Implement both callbacks for a database, secret manager or object store.
  Return safe error reasons without credentials or private key material.
  Generation happens only on `:not_found`; storage errors never trigger rotation.
  """
  @type id :: {String.t(), String.t()}
  @type adapter :: module() | {module(), keyword()}
  @doc "Reads a key; only `:not_found` permits generation. Error reasons must omit secrets."
  @callback fetch(id(), keyword()) :: {:ok, binary()} | :not_found | {:error, term()}
  @doc "Atomically creates a key, returning `{:error, :already_exists}` on conflict."
  @callback put_new(id(), binary(), keyword()) :: :ok | {:error, term()}
end
