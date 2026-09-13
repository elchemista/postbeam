defmodule Postbeam.CachedDNS do
  @moduledoc """
  Optional, node-local ETS cache for the default DNS resolver.

  Add `{Postbeam.CachedDNS, max_entries: 10_000}` to your application's supervisor
  and select `resolver: Postbeam.CachedDNS` when delivering. Reads access a
  protected ETS table directly; the supervised owner serializes only cache
  writes, eviction and periodic cleanup. DNS queries run in the calling process.

  Only positive MX/A/AAAA answers with nonzero TTLs are cached, including Null MX.
  NODATA and errors are never cached. Lifetimes include CNAME TTLs and are capped
  by `max_ttl` (seconds). Keys separate query types and explicit `dns_options`.
  Clear the cache after changing system-wide resolver settings.

  Cache loss, absence or write timeout falls back to ordinary DNS. Concurrent
  misses may perform duplicate queries. The table has a strict entry-count
  limit, not a byte limit, and is neither persistent nor shared between nodes.
  """

  use GenServer
  @behaviour Postbeam.MX

  alias Postbeam.{Config, MX}

  @type option ::
          {:max_entries, pos_integer()}
          | {:max_ttl, pos_integer()}
          | {:cleanup_interval, Config.milliseconds()}
  @typep state :: %{
           max_entries: pos_integer(),
           max_ttl: pos_integer(),
           cleanup_interval: pos_integer()
         }
  @typep key :: {String.t(), MX.record_type(), keyword()}
  @call_timeout 50

  @doc """
  Starts the ETS owner. Normally invoked by the consuming application's supervisor.

  Options: `max_entries` (10,000), `max_ttl` (3,600 seconds), and
  `cleanup_interval` (60,000 milliseconds). All must be positive integers;
  `cleanup_interval` must fit an OTP timer. The registered name and child ID are
  `Postbeam.CachedDNS`; start at most one instance per node.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc "Uses cached positive answers or queries `Postbeam.MX.lookup_with_ttl/3` on a miss."
  @impl MX
  @spec lookup(String.t(), MX.record_type(), Config.t()) :: MX.lookup_result()
  def lookup(domain, type, config) do
    key = {String.downcase(domain), type, Keyword.get(config, :dns_options, [])}

    case fetch(key) do
      {:ok, _} = hit -> hit
      :miss -> query(key, domain, type, config)
    end
  end

  @doc "Clears this node's cache. Returns an error if the owner is unavailable or busy."
  @spec clear() :: :ok | {:error, :unavailable}
  def clear, do: request(:clear)

  @impl GenServer
  def init(options) do
    options =
      Keyword.validate!(options, max_entries: 10_000, max_ttl: 3_600, cleanup_interval: 60_000)

    if valid_options?(options) do
      _table = :ets.new(__MODULE__, [:named_table, :protected, :set, read_concurrency: true])
      state = Map.new(options)
      schedule_cleanup(state)
      {:ok, state}
    else
      {:stop, :invalid_cache_options}
    end
  end

  @impl GenServer
  def handle_call({:put, key, records, deadline}, _from, state) do
    now = now()

    if deadline > now do
      evict_if_full(key, state.max_entries)
      true = :ets.insert(__MODULE__, {key, records, min(deadline, now + state.max_ttl * 1_000)})
    end

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    true = :ets.delete_all_objects(__MODULE__)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    _count = :ets.select_delete(__MODULE__, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now()}], [true]}])
    schedule_cleanup(state)
    {:noreply, state}
  end

  @spec fetch(key()) :: {:ok, [MX.dns_record()]} | :miss
  defp fetch(key) do
    now = now()

    case :ets.lookup(__MODULE__, key) do
      [{^key, records, deadline}] when deadline > now -> {:ok, records}
      _ -> :miss
    end
  rescue
    # The owner may be absent or restarting between lookup and table access.
    ArgumentError -> :miss
  end

  defp query(key, domain, type, config) do
    started = now()

    case MX.lookup_with_ttl(domain, type, config) do
      {:ok, records, ttl} ->
        # The DNS answer remains usable even when the cache cannot accept it.
        _cache_write =
          if records != [] and ttl > 0 do
            request({:put, key, records, started + ttl * 1_000})
          end

        {:ok, records}

      {:error, _} = error ->
        error
    end
  end

  @spec request(term()) :: :ok | {:error, :unavailable}
  defp request(message) do
    GenServer.call(__MODULE__, message, @call_timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp evict_if_full(key, max_entries) do
    if not :ets.member(__MODULE__, key) and :ets.info(__MODULE__, :size) >= max_entries do
      true = :ets.delete(__MODULE__, :ets.first(__MODULE__))
    end
  end

  defp valid_options?(options) do
    Enum.all?(options, fn {_, value} -> is_integer(value) and value > 0 end) and
      options[:cleanup_interval] <= 4_294_967_295
  end

  @spec schedule_cleanup(state()) :: reference()
  defp schedule_cleanup(state), do: Process.send_after(self(), :cleanup, state.cleanup_interval)

  defp now, do: System.monotonic_time(:millisecond)
end
