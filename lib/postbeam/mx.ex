defmodule Postbeam.MX do
  @moduledoc """
  Recipient routing and the DNS adapter contract.

  Set `resolver: MyDNS` to supply `lookup/3`. A successful empty list means
  NODATA; DNS failures must remain errors. Options include `dns_timeout` and
  `dns_options` (passed to OTP's resolver). Implementations must honor timeouts.
  """

  alias Postbeam.Config

  @type record_type :: :mx | :a | :aaaa
  @type dns_record :: {0..65_535, String.t() | charlist()} | :inet.ip_address()
  @type lookup_result :: {:ok, [dns_record()]} | {:error, term()}
  @type dns_error :: {:dns, String.t(), record_type(), term()}
  @type routing_error :: dns_error() | {:null_mx, String.t()} | {:invalid_mx, String.t(), list()}
  @type address_error ::
          {:no_addresses, String.t(), [{:ok, [:inet.ip_address()]} | {:error, dns_error()}]}

  @doc """
  Resolves records through the configured adapter.

  Return MX records as `{priority, hostname}` pairs and A/AAAA records as IP
  tuples. `{:ok, []}` means a successful NODATA response; return DNS failures
  as errors. Implementations must honor `:dns_timeout` and must not perform
  SMTP delivery. This callback permits caching or private DNS implementations.
  """
  @callback lookup(String.t(), record_type(), Config.t()) :: lookup_result()

  @doc """
  Returns deduplicated, lowercase MX hostnames, sorting priorities and shuffling ties.

  Only a successful empty MX response activates implicit MX. A sole Null MX
  returns `{:error, {:null_mx, domain}}`; mixed or malformed MX sets are errors.
  Address resolution is deferred until the SMTP adapter attempts each host.
  """
  @spec resolve(String.t(), Config.t()) ::
          {:ok, nonempty_list(String.t())} | {:error, routing_error()}
  def resolve(domain, config) do
    with {:ok, records} <- query(domain, :mx, config) do
      route(records, domain)
    end
  end

  @doc """
  Resolves A then AAAA, deduplicating addresses without reordering them.

  A usable address from either family is sufficient even if the other query
  fails. If neither succeeds, both query outcomes are retained in the error.
  Each family uses a separate DNS timeout.
  """
  @spec addresses(String.t(), Config.t()) ::
          {:ok, nonempty_list(:inet.ip_address())} | {:error, address_error()}
  def addresses(host, config) do
    results = Enum.map([:a, :aaaa], &query(host, &1, config))
    addresses = for {:ok, values} <- results, address <- values, do: address

    case Enum.uniq(addresses) do
      [] -> {:error, {:no_addresses, host, results}}
      addresses -> {:ok, addresses}
    end
  end

  @doc "Default DNS adapter, backed by `:inet_res.resolve/5`."
  @spec lookup(String.t(), record_type(), Config.t()) :: lookup_result()
  def lookup(domain, type, config) do
    case lookup_with_ttl(domain, type, config) do
      {:ok, records, _ttl} -> {:ok, records}
      {:error, _} = error -> error
    end
  end

  @doc """
  Returns DNS records and their minimum TTL in seconds for caching adapters.

  CNAME lifetimes in the answer also limit this TTL. Empty answers and TTLs
  with the reserved high bit set get a zero lifetime. No negative caching is
  performed. `lookup/3` keeps the original adapter contract without TTL metadata.
  """
  @spec lookup_with_ttl(String.t(), record_type(), Config.t()) ::
          {:ok, [dns_record()], non_neg_integer()} | {:error, term()}
  def lookup_with_ttl(domain, type, config) do
    case :inet_res.resolve(
           String.to_charlist(domain),
           :in,
           type,
           Keyword.get(config, :dns_options, []),
           Keyword.get(config, :dns_timeout, 5_000)
         ) do
      {:ok, response} ->
        answers =
          for record <- :inet_dns.msg(response, :anlist),
              :inet_dns.rr(record, :class) == :in,
              :inet_dns.rr(record, :type) in [type, :cname],
              do: record

        records =
          for record <- answers,
              :inet_dns.rr(record, :type) == type,
              do: :inet_dns.rr(record, :data)

        {:ok, records, minimum_ttl(answers)}

      {:error, _} = error ->
        error
    end
  end

  defp minimum_ttl(answers) do
    answers
    |> Enum.map(fn answer ->
      ttl = :inet_dns.rr(answer, :ttl)
      if ttl in 0..2_147_483_647, do: ttl, else: 0
    end)
    |> Enum.min(fn -> 0 end)
  end

  @spec query(String.t(), record_type(), Config.t()) ::
          {:ok, [dns_record()]} | {:error, dns_error()}
  defp query(domain, type, config) do
    resolver = Keyword.get(config, :resolver, __MODULE__)

    case resolver.lookup(domain, type, config) do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, {:dns, domain, type, reason}}
    end
  end

  defp route([], domain), do: {:ok, [domain]}

  defp route(records, domain) do
    records = Enum.map(records, &normalize_record/1)

    cond do
      Enum.uniq(records) == [{0, ""}] ->
        {:error, {:null_mx, domain}}

      not Enum.all?(records, &valid_record?/1) ->
        {:error, {:invalid_mx, domain, records}}

      true ->
        {:ok,
         records
         |> Enum.shuffle()
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map(&elem(&1, 1))
         |> Enum.uniq()}
    end
  end

  defp normalize_record({priority, host}) when is_binary(host) or is_list(host) do
    {priority, host |> to_string() |> String.replace_suffix(".", "") |> String.downcase()}
  end

  defp normalize_record(record), do: record

  defp valid_record?({priority, host}),
    do: is_integer(priority) and priority in 0..65_535 and Config.domain?(host)

  defp valid_record?(_), do: false
end
