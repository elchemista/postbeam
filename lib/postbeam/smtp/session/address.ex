defmodule Postbeam.SMTP.Session.Address do
  @moduledoc false

  alias Postbeam.SMTP.Binary
  alias Postbeam.SMTP.Session.AddressState

  @spec parse_encoded_address(binary(), boolean()) :: {binary(), binary()} | :error
  @doc false
  def parse_encoded_address(<<>>, _) do
    :error
  end

  def parse_encoded_address(<<"<@", address::binary>>, utf8) do
    case Binary.strchr(address, 58) do
      0 ->
        :error

      index ->
        parse_encoded_address(
          Binary.substr(address, index + 1),
          [],
          %AddressState{quotes: false, ab: true, utf8: utf8}
        )
    end
  end

  def parse_encoded_address(<<"<", address::binary>>, utf8) do
    parse_encoded_address(address, [], %AddressState{
      quotes: false,
      ab: true,
      utf8: utf8
    })
  end

  def parse_encoded_address(<<" ", address::binary>>, utf8) do
    parse_encoded_address(address, utf8)
  end

  def parse_encoded_address(address, utf8) do
    parse_encoded_address(address, [], %AddressState{
      quotes: false,
      ab: false,
      utf8: utf8
    })
  end

  @spec parse_encoded_address(
          binary(),
          list(),
          AddressState.t()
        ) :: {binary(), binary()} | :error
  @doc false
  def parse_encoded_address(<<>>, acc, %AddressState{ab: false}) do
    {:unicode.characters_to_binary(:lists.reverse(acc)), <<>>}
  end

  def parse_encoded_address(<<>>, _acc, %AddressState{ab: true}) do
    :error
  end

  def parse_encoded_address(_, acc, _) when length(acc) > 320 do
    :error
  end

  def parse_encoded_address(<<"\\", h, tail::binary>>, acc, flags) do
    parse_encoded_address(tail, [h | acc], flags)
  end

  def parse_encoded_address(<<"\"", tail::binary>>, acc, %AddressState{quotes: quotes} = flags) do
    parse_encoded_address(tail, acc, %{flags | quotes: not quotes})
  end

  def parse_encoded_address(<<">", tail::binary>>, acc, %AddressState{
        quotes: false,
        ab: true
      }) do
    {:unicode.characters_to_binary(:lists.reverse(acc)), Binary.strip(tail, :left, 32)}
  end

  def parse_encoded_address(<<">", _tail::binary>>, _acc, %AddressState{
        quotes: false,
        ab: false
      }) do
    :error
  end

  def parse_encoded_address(<<" ", tail::binary>>, acc, %AddressState{
        quotes: false,
        ab: false
      }) do
    {:unicode.characters_to_binary(:lists.reverse(acc)), Binary.strip(tail, :left, 32)}
  end

  def parse_encoded_address(<<" ", _tail::binary>>, _acc, %AddressState{
        quotes: false,
        ab: true
      }) do
    :error
  end

  def parse_encoded_address(
        <<h::utf8, tail::binary>>,
        acc,
        %AddressState{utf8: true} = f
      )
      when h > 127 do
    parse_encoded_address(tail, [h | acc], f)
  end

  def parse_encoded_address(<<h, tail::binary>>, acc, %AddressState{quotes: false} = flags)
      when h in ?0..?9 or h in ?@..?Z or h in ?a..?z or h in ~c"-._+!#$%&'*=/?^`{|}~" do
    parse_encoded_address(tail, [h | acc], flags)
  end

  def parse_encoded_address(_, _acc, %AddressState{quotes: false}) do
    :error
  end

  def parse_encoded_address(
        <<h, tail::binary>>,
        acc,
        %AddressState{quotes: true} = f
      ) do
    parse_encoded_address(tail, [h | acc], f)
  end
end
