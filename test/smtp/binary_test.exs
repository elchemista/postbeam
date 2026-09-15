defmodule Postbeam.SMTP.BinaryTest do
  use ExUnit.Case, async: true
  alias Postbeam.SMTP.Binary, as: Bytes

  test "reverse searches include the first byte and overlapping matches" do
    assert Bytes.strrchr("a", ?a) == 1
    assert Bytes.strrchr("abc", ?a) == 1
    assert Bytes.strrchr(<<>>, ?a) == 0
    assert Bytes.strrpos("aaaa", "aa") == 3
    assert Bytes.strrpos("abc", ~c"ab") == 1
    assert Bytes.strrpos("abc", "abcd") == 0
  end

  test "chomp handles empty and single-byte input" do
    for {input, expected} <- [
          {"", ""},
          {"x", "x"},
          {"\r", ""},
          {"\n", ""},
          {"\r\n", ""},
          {"x\r\n", "x"},
          {"x\n\n", "x\n"}
        ] do
      assert Bytes.chomp(input) == expected
    end
  end

  test "ASCII case conversion preserves arbitrary payload bytes" do
    bytes = <<0, 255, 195, 169, ?A, ?z>>
    assert Bytes.to_lower(bytes) == <<0, 255, 195, 169, ?a, ?z>>
    assert Bytes.to_upper(bytes) == <<0, 255, 195, 169, ?A, ?Z>>
    assert Bytes.reverse(Bytes.reverse(bytes)) == bytes
  end

  test "split retains interior empty fields and supports a bounded remainder" do
    assert Bytes.split("a,,", ",") == ["a", ""]
    assert Bytes.split("a,b,c", ",", 2) == ["a", "b,c"]
    assert Bytes.split("abc", "", 2) == ["a", "bc"]
    assert Bytes.split("", ",", 2) == []
  end
end
