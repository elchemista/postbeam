defmodule Postbeam.MXTest do
  use ExUnit.Case, async: true
  alias Postbeam.{MX, TestDNS}
  @options [resolver: TestDNS]

  for records <- [
        [{-1, "mx.test"}],
        [{65_536, "mx.test"}],
        [{"10", "mx.test"}],
        [{0, "mx.test.."}],
        [{0, "bad_name.test"}],
        [{1, "."}],
        [{0, "."}, {1, "mx.test"}],
        [:broken],
        [{1, 123}]
      ] do
    test "malformed MX set #{inspect(records)} is a routing error" do
      TestDNS.put("example.net", :mx, {:ok, unquote(Macro.escape(records))})
      assert {:error, {:invalid_mx, "example.net", _}} = MX.resolve("example.net", @options)
    end
  end

  test "normalizes host case and a single root suffix before deduplication" do
    TestDNS.put(
      "example.net",
      :mx,
      {:ok, [{30, ~c"MX.TEST."}, {10, "mx.test"}, {20, "backup.test"}]}
    )

    assert {:ok, ["mx.test", "backup.test"]} = MX.resolve("example.net", @options)
  end

  test "deduplicates A and AAAA addresses while preserving family order" do
    v4 = {127, 0, 0, 1}
    v6 = {0, 0, 0, 0, 0, 0, 0, 1}
    TestDNS.put("mx.test", :a, {:ok, [v4, v4]})
    TestDNS.put("mx.test", :aaaa, {:ok, [v6, v6]})
    assert {:ok, [^v4, ^v6]} = MX.addresses("mx.test", @options)
  end

  test "empty address sets retain both successful NODATA outcomes" do
    assert {:error, {:no_addresses, "mx.test", [ok: [], ok: []]}} =
             MX.addresses("mx.test", @options)
  end

  test "IPv4 remains usable when AAAA fails" do
    TestDNS.put("mx.test", :a, {:ok, [{127, 0, 0, 1}]})
    TestDNS.put("mx.test", :aaaa, {:error, :timeout})
    assert {:ok, [{127, 0, 0, 1}]} = MX.addresses("mx.test", @options)
  end
end
