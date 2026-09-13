defmodule Postbeam.MessageTest do
  use ExUnit.Case, async: true
  alias Postbeam.{Config, Message}

  @fields %{
    from: "Sender@example.com",
    to: "Recipient@example.net",
    subject: "Hello",
    text: "Body"
  }

  for {name, value} <- [
        {"display name", "User <user@example.net>"},
        {"quoted local part", "\"user name\"@example.net"},
        {"domain literal", "user@[127.0.0.1]"},
        {"extra at sign", "user@@example.net"},
        {"empty local part", "@example.net"},
        {"empty domain", "user@"},
        {"leading local dot", ".user@example.net"},
        {"trailing local dot", "user.@example.net"},
        {"long local part", String.duplicate("a", 65) <> "@example.net"},
        {"long DNS label", "user@" <> String.duplicate("a", 64) <> ".net"},
        {"domain underscore", "user@my_domain.net"},
        {"trailing DNS hyphen", "user@example-.net"},
        {"raw IDN", "user@caffè.net"},
        {"invalid UTF-8", <<255, "@example.net">>},
        {"NUL", "user\0@example.net"},
        {"address too long",
         String.duplicate("a", 64) <> "@" <> String.duplicate("b.", 94) <> "net"}
      ] do
    test "rejects #{name} in both addresses" do
      for field <- [:from, :to] do
        assert {:error, {:invalid, ^field}} = Message.new(Map.put(@fields, field, unquote(value)))
      end
    end
  end

  test "supports dot-atom punctuation and punycode while preserving local-part case" do
    address = "User.!#$%&'*+-/=?^_`{|}~@XN--CAFF-8OA.NET"
    assert {:ok, message} = Message.new(%{@fields | to: address})
    assert message.to == "User.!#$%&'*+-/=?^_`{|}~@xn--caff-8oa.net"
    assert message.domain == "xn--caff-8oa.net"
  end

  test "accepts maximum local and domain-label lengths" do
    local = String.duplicate("x", 64)
    domain = String.duplicate("a", 63) <> ".net"
    assert {:ok, _} = Message.new(%{@fields | to: local <> "@" <> domain})
  end

  test "malformed containers, structs and duplicate fields return validation errors" do
    for input <- [nil, "message", ["from"], [{"from", "a@example.com"}], Date.utc_today()] do
      assert {:error, {:invalid, :message}} = Message.new(input)
    end

    assert {:error, {:invalid, :message}} =
             Message.new(Map.to_list(@fields) ++ [to: "other@example.net"])

    assert {:error, {:unknown_field, "from"}} = Message.new(%{"from" => "a@example.com"})
  end

  test "all ASCII header control bytes are rejected" do
    for byte <- Enum.to_list(0..31) ++ [127] do
      assert {:error, {:invalid, :subject}} =
               Message.new(%{@fields | subject: "a" <> <<byte>> <> "b"})
    end
  end

  test "large Unicode bodies and subjects round-trip without long wire lines" do
    body = String.duplicate("Caffè ☕\n", 2_000)
    {:ok, config} = Config.new([])
    {:ok, message} = Message.new(%{@fields | subject: String.duplicate("☕", 100), text: body})
    {:ok, encoded} = Message.encode(message, config)
    assert {"text", "plain", headers, _, ^body} = :mimemail.decode(encoded.data, encoding: :none)
    assert {"Content-Transfer-Encoding", "base64"} in headers
    assert Enum.all?(String.split(encoded.data, "\r\n"), &(byte_size(&1) <= 998))
    assert Enum.all?(:binary.bin_to_list(encoded.data), &(&1 < 128))
  end

  test "independent encodings get distinct IDs and validation does not pre-encode" do
    {:ok, config} = Config.new([])
    {:ok, message} = Message.new(@fields)
    assert message.data == nil
    assert message.message_id == nil
    {:ok, first} = Message.encode(message, config)
    {:ok, second} = Message.encode(message, config)
    refute first.message_id == second.message_id
    assert first.data =~ first.message_id
    assert second.data =~ second.message_id
  end
end
