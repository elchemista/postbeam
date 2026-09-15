defmodule Postbeam.SMTP.UtilTest do
  use ExUnit.Case, async: true

  test "RFC 5322 offsets include half-hour and quarter-hour zones" do
    for {seconds, expected} <- [
          {0, "+0000"},
          {3600, "+0100"},
          {19_800, "+0530"},
          {20_700, "+0545"},
          {-12_600, "-0330"},
          {-900, "-0015"}
        ] do
      assert Postbeam.SMTP.Util.format_zone(seconds) == expected
    end
  end

  test "invalid UTF-8 in an address returns an error" do
    assert {:error, _} = Postbeam.SMTP.Util.parse_rfc5322_addresses(<<255, "@example.com">>)
  end
end
