defmodule Postbeam.Config do
  @moduledoc """
  Validates delivery options and merges application defaults.

  Precedence is library defaults, `config :postbeam`, then per-call options.
  Nested keyword lists are replaced as a whole. Pass `dkim: nil` to disable
  application-level signing for one delivery. Unknown options and duplicate
  keys are rejected. This module does not read private keys or open connections.

  `hostname` defaults to `"localhost"` for local experimentation; real senders
  should supply their public EHLO hostname. All timeouts are positive, finite
  milliseconds. `smtp_timeout` bounds each IP attempt, not the whole delivery.
  """

  @typedoc "STARTTLS policy; optional TLS can fall back to plaintext."
  @type tls :: :always | :if_available | :never
  @type milliseconds :: 1..4_294_967_295
  @type option ::
          {:hostname, String.t()}
          | {:tls, tls()}
          | {:tls_options, keyword()}
          | {:port, 1..65_535}
          | {:connect_timeout | :smtp_timeout | :dns_timeout, milliseconds()}
          | {:dns_options, keyword()}
          | {:dkim, keyword() | nil}
          | {:key_store, Postbeam.KeyStore.adapter()}
          | {:sent_store, Postbeam.SentStore.adapter() | nil}
          | {:resolver | :transport, module()}
  @type t :: [option()]
  @type error :: {:invalid, :config} | {:invalid_config, atom()}

  @defaults [
    hostname: "localhost",
    tls: :if_available,
    tls_options: [],
    port: 25,
    connect_timeout: 5_000,
    smtp_timeout: 60_000,
    dns_timeout: 5_000,
    dns_options: [],
    dkim: nil,
    key_store: Postbeam.KeyStore.File,
    sent_store: nil,
    resolver: Postbeam.MX,
    transport: Postbeam.SMTP
  ]

  @doc """
  Returns fully merged options or identifies the invalid option without its value.

      iex> {:ok, config} = Postbeam.Config.new(hostname: "mta.example.com")
      iex> {config[:hostname], config[:port]}
      {"mta.example.com", 25}

      iex> Postbeam.Config.new(smtp_timeout: :infinity)
      {:error, {:invalid_config, :smtp_timeout}}
  """
  @spec new(term()) :: {:ok, t()} | {:error, error()}
  def new(options) do
    with {:ok, options} <- keyword(options, :config) do
      config =
        @defaults |> Keyword.merge(Application.get_all_env(:postbeam)) |> Keyword.merge(options)

      case Enum.find(config, &invalid_option?/1) do
        nil -> {:ok, config}
        {key, _} -> {:error, {:invalid_config, key}}
      end
    end
  end

  @doc false
  @spec keyword(term(), atom()) :: {:ok, keyword()} | {:error, {:invalid, atom()}}
  def keyword(value, field) do
    if keyword?(value),
      do: {:ok, value},
      else: {:error, {:invalid, field}}
  end

  @doc false
  @spec domain?(term()) :: boolean()
  def domain?(value) when is_binary(value) do
    byte_size(value) in 1..253 and Enum.all?(String.split(value, "."), &label?/1)
  end

  def domain?(_), do: false

  @doc false
  @spec header?(term()) :: boolean()
  def header?(value),
    do: is_binary(value) and String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\z/, label)
  end

  defp invalid_option?({key, value}), do: not valid?(key, value)

  defp valid?(:hostname, value), do: domain?(value)
  defp valid?(:tls, value), do: value in [:always, :if_available, :never]
  defp valid?(:port, value), do: is_integer(value) and value in 1..65_535

  defp valid?(key, value) when key in [:connect_timeout, :smtp_timeout, :dns_timeout],
    do: is_integer(value) and value in 1..4_294_967_295

  defp valid?(key, value) when key in [:tls_options, :dns_options], do: keyword?(value)
  defp valid?(:resolver, value), do: adapter?(value, :lookup, 3)
  defp valid?(:transport, value), do: adapter?(value, :deliver, 3)
  defp valid?(:key_store, value), do: Postbeam.Store.valid?(value, fetch: 2, put_new: 3)
  defp valid?(:sent_store, nil), do: true
  defp valid?(:sent_store, value), do: Postbeam.Store.valid?(value, put: 2)
  defp valid?(:dkim, nil), do: true

  defp valid?(:dkim, value) do
    keyword?(value) and domain?(value[:d]) and domain?(value[:s]) and
      dkim_key?(value) and Enum.all?(value, &dkim_option?/1)
  end

  defp valid?(_, _), do: false

  defp dkim_option?({key, _}) when key in [:d, :s, :private_key], do: true
  defp dkim_option?({:a, algorithm}), do: algorithm in [:"rsa-sha256", :"ed25519-sha256"]
  defp dkim_option?({:c, {headers, :simple}}), do: headers in [:simple, :relaxed]

  defp dkim_option?({:h, headers}) do
    is_list(headers) and "from" in headers and Enum.all?(headers, &header_name?/1)
  end

  defp dkim_option?({:t, :now}), do: true
  defp dkim_option?({key, datetime}) when key in [:t, :x], do: datetime?(datetime)
  defp dkim_option?(_), do: false

  defp header_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[a-z0-9-]+\z/, name)

  defp datetime?({{year, month, day} = date, {hour, minute, second}}) do
    Enum.all?([year, month, day, hour, minute, second], &is_integer/1) and
      year >= 0 and :calendar.valid_date(date) and hour in 0..23 and minute in 0..59 and
      second in 0..59
  end

  defp datetime?(_), do: false

  defp dkim_key?(options) do
    if Keyword.has_key?(options, :private_key),
      do: key?(options[:private_key]),
      else: Keyword.get(options, :a, :"rsa-sha256") == :"rsa-sha256"
  end

  defp key?({:pem_plain, pem}), do: is_binary(pem) and byte_size(pem) > 0

  defp key?({:pem_encrypted, pem, password}),
    do: key?({:pem_plain, pem}) and is_list(password) and Enum.all?(password, &is_integer/1)

  defp key?(_), do: false

  defp keyword?(value),
    do: is_list(value) and Keyword.keyword?(value) and length(value) == map_size(Map.new(value))

  defp adapter?(module, function, arity),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)
end
