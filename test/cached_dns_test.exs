defmodule Postbeam.CachedDNSTest do
  use ExUnit.Case, async: false

  alias Postbeam.{CachedDNS, Config, MX}
  import Postbeam.TestDNSServer, only: [dns: 1, dns: 2]

  @records %{{"example.net", :mx} => [{10, ~c"mx.test"}]}

  test "positive answers are reused by different caller processes" do
    owner = start_supervised!(CachedDNS)
    config = dns(@records, ttl: 60)
    assert {:ok, _} = Config.new(resolver: CachedDNS)
    assert {:ok, [{10, ~c"mx.test"}]} = CachedDNS.lookup("example.net", :mx, config)
    assert_receive {:dns_query, "example.net", :mx}

    results =
      1..100
      |> Task.async_stream(fn _ -> CachedDNS.lookup("example.net", :mx, config) end,
        max_concurrency: 20
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, {:ok, [{10, ~c"mx.test"}]}}))
    refute_receive {:dns_query, _, _}
    assert :ets.info(CachedDNS, :owner) == owner
    assert :ets.info(CachedDNS, :protection) == :protected
    assert :ets.info(CachedDNS, :read_concurrency)
  end

  test "reads bypass a busy owner and writes cannot block DNS indefinitely" do
    owner = start_supervised!(CachedDNS)
    config = dns(@records, ttl: 60)
    assert {:ok, _} = CachedDNS.lookup("example.net", :mx, config)
    assert_receive {:dns_query, _, _}
    :ok = :sys.suspend(owner)

    try do
      assert {:ok, _} = CachedDNS.lookup("example.net", :mx, config)
      refute_receive {:dns_query, _, _}
      assert {:error, :unavailable} = CachedDNS.clear()
      cold = dns(%{{"other.net", :mx} => [{10, ~c"other.test"}]}, ttl: 60)
      assert {:ok, [{10, ~c"other.test"}]} = CachedDNS.lookup("other.net", :mx, cold)
    after
      :ok = :sys.resume(owner)
    end
  end

  test "cache is optional and missing owner falls back to DNS" do
    config = dns(@records, ttl: 60)
    assert {:error, :unavailable} = CachedDNS.clear()

    for _ <- 1..2 do
      assert {:ok, [{10, ~c"mx.test"}]} = CachedDNS.lookup("example.net", :mx, config)
      assert_receive {:dns_query, "example.net", :mx}
    end
  end

  test "records expire and periodic cleanup frees entries" do
    start_supervised!({CachedDNS, max_ttl: 1, cleanup_interval: 20})
    config = dns(@records, ttl: 60)
    assert {:ok, _} = CachedDNS.lookup("example.net", :mx, config)
    assert_receive {:dns_query, _, _}
    # This checks an actual TTL deadline, independent of wall-clock adjustments.
    Process.sleep(1_100)
    assert :ets.info(CachedDNS, :size) == 0
    assert {:ok, _} = CachedDNS.lookup("example.net", :mx, config)
    assert_receive {:dns_query, _, _}
  end

  test "expired entries are not served even before background cleanup" do
    start_supervised!({CachedDNS, cleanup_interval: 60_000})
    config = dns(@records, ttl: 1)
    assert {:ok, _} = CachedDNS.lookup("example.net", :mx, config)
    assert_receive {:dns_query, _, _}
    Process.sleep(1_100)
    assert :ets.info(CachedDNS, :size) == 1
    assert {:ok, _} = CachedDNS.lookup("example.net", :mx, config)
    assert_receive {:dns_query, _, _}
  end

  test "TTL zero, NODATA and DNS errors are never cached" do
    start_supervised!(CachedDNS)
    config = dns(Map.merge(@records, %{{"missing.net", :mx} => :nxdomain}))

    for {domain, expected} <- [
          {"example.net", {:ok, [{10, ~c"mx.test"}]}},
          {"empty.net", {:ok, []}},
          {"missing.net", {:error, :nxdomain}}
        ] do
      for _ <- 1..2 do
        assert CachedDNS.lookup(domain, :mx, config) == expected
        assert_receive {:dns_query, ^domain, :mx}
      end
    end

    assert :ets.info(CachedDNS, :size) == 0
  end

  test "minimum TTL includes aliases and reserved high-bit TTLs are not cached" do
    start_supervised!(CachedDNS)

    records = %{
      {"alias.net", :mx} => [{:rr, :cname, ~c"target.net", 1}, {:rr, :mx, {10, ~c"mx.test"}, 60}],
      {"mixed.net", :mx} => [{:rr, :mx, {10, ~c"a.test"}, 60}, {:rr, :mx, {20, ~c"b.test"}, 10}],
      {"high.net", :mx} => [{:rr, :mx, {10, ~c"mx.test"}, 2_147_483_648}]
    }

    config = dns(records)
    assert {:ok, [{10, ~c"mx.test"}], 1} = MX.lookup_with_ttl("alias.net", :mx, config)
    assert {:ok, _, 10} = MX.lookup_with_ttl("mixed.net", :mx, config)

    for _ <- 1..2 do
      assert {:ok, _} = CachedDNS.lookup("high.net", :mx, config)
      assert_receive {:dns_query, "high.net", :mx}
    end

    assert :ets.info(CachedDNS, :size) == 0
  end

  test "Null MX stays a terminal routing error on cache hits" do
    start_supervised!(CachedDNS)
    config = dns(%{{"null.net", :mx} => [{0, ~c""}]}, ttl: 60) ++ [resolver: CachedDNS]
    for _ <- 1..2, do: assert({:error, {:null_mx, "null.net"}} = MX.resolve("null.net", config))
    assert_receive {:dns_query, "null.net", :mx}
    refute_receive {:dns_query, _, _}
  end

  test "query types and DNS configurations have separate cache entries" do
    start_supervised!(CachedDNS)
    first = dns(Map.put(@records, {"example.net", :a}, [{127, 0, 0, 1}]), ttl: 60)
    second = dns(%{{"example.net", :mx} => [{20, ~c"other.test"}]}, ttl: 60)
    assert {:ok, [{10, ~c"mx.test"}]} = CachedDNS.lookup("example.net", :mx, first)
    assert {:ok, [{127, 0, 0, 1}]} = CachedDNS.lookup("example.net", :a, first)
    assert {:ok, [{20, ~c"other.test"}]} = CachedDNS.lookup("example.net", :mx, second)
    assert :ets.info(CachedDNS, :size) == 3
  end

  test "concurrent misses cannot exceed the configured capacity" do
    start_supervised!({CachedDNS, max_entries: 2})
    records = Map.new(1..20, &{{"domain#{&1}.net", :mx}, [{10, ~c"mx.test"}]})
    config = dns(records, ttl: 60)

    results =
      Task.async_stream(
        1..20,
        fn n ->
          CachedDNS.lookup("domain#{n}.net", :mx, config)
        end,
        max_concurrency: 20
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, [_]}}, &1))
    assert :ets.info(CachedDNS, :size) == 2
    assert :ok = CachedDNS.clear()
    assert :ets.info(CachedDNS, :size) == 0
  end

  test "supervisor restarts the owner with an empty table after a crash" do
    owner = start_supervised!(CachedDNS)
    config = dns(@records, ttl: 60)
    assert {:ok, _} = CachedDNS.lookup("example.net", :mx, config)
    assert_receive {:dns_query, _, _}
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    replacement_owner = await_replacement(owner, 50)
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    children = Supervisor.which_children(supervisor)
    assert {CachedDNS, replacement, :worker, [CachedDNS]} = List.keyfind(children, CachedDNS, 0)
    refute replacement == owner
    assert replacement == replacement_owner
    assert :ets.info(CachedDNS, :owner) == replacement
    assert :ets.info(CachedDNS, :size) == 0
    assert {:ok, _} = CachedDNS.lookup("example.net", :mx, config)
    assert_receive {:dns_query, _, _}
  end

  test "invalid capacity and timer options fail startup" do
    Process.flag(:trap_exit, true)

    for options <- [
          [max_entries: 0],
          [max_ttl: -1],
          [cleanup_interval: 0],
          [cleanup_interval: 4_294_967_296]
        ] do
      assert {:error, :invalid_cache_options} = CachedDNS.start_link(options)
    end
  end

  defp await_replacement(_, 0), do: flunk("cache owner did not restart")

  defp await_replacement(previous, retries) do
    case :ets.info(CachedDNS, :owner) do
      owner when is_pid(owner) and owner != previous ->
        owner

      _ ->
        Process.sleep(10)
        await_replacement(previous, retries - 1)
    end
  end
end
