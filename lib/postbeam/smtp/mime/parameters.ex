defmodule Postbeam.SMTP.MIME.Parameters do
  @moduledoc false

  alias Postbeam.SMTP.Binary

  @spec encode_parameters(list({binary(), binary()})) :: list(binary())
  @doc false
  def encode_parameters([[]]) do
    []
  end

  def encode_parameters(parameters) do
    Enum.flat_map(parameters, fn {name, value} ->
      {method, enc_len} = decide_param_encoding_method(value)
      encode_parameter(method, name, value, enc_len)
    end)
  end

  @spec encode_parameter(
          :plain | :quote | :encode | :encode_utf8,
          binary(),
          binary(),
          non_neg_integer()
        ) :: list(binary())
  defp encode_parameter(method, name, value, enc_len) do
    encode_parameter(method, name, 0, value, enc_len, [])
  end

  @spec encode_parameter(
          :plain | :quote | :encode | :encode_utf8,
          binary(),
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          [binary()]
        ) :: [binary()]
  defp encode_parameter(_method, _name, _index, <<>>, _enc_len, acc) do
    :lists.reverse(acc)
  end

  defp encode_parameter(:encode_utf8, name, 0, value, enc_len, _acc)
       when byte_size(name) + 9 + enc_len <= 76 do
    {encoded, <<>>} = encode_param_value(:encode, value, 67 - byte_size(name))
    [<<name::binary, "*=UTF-8''", encoded::binary>>]
  end

  defp encode_parameter(:encode_utf8, name, 0, value, enc_len, acc) do
    {encoded, more} = encode_param_value(:encode, value, 65 - byte_size(name))

    encode_parameter(:encode, name, 1, more, enc_len, [
      <<name::binary, "*0*=UTF-8''", encoded::binary>> | acc
    ])
  end

  defp encode_parameter(:encode, name, 0, value, enc_len, _acc)
       when byte_size(name) + 4 + enc_len <= 76 do
    {encoded, <<>>} = encode_param_value(:encode, value, 72 - byte_size(name))
    [<<name::binary, "*=''", encoded::binary>>]
  end

  defp encode_parameter(:encode, name, 0, value, enc_len, acc) do
    prefix = <<name::binary, 42, 48, 42>>
    {encoded, more} = encode_param_value(:encode, value, 73 - byte_size(prefix))

    encode_parameter(:encode, name, 1, more, enc_len, [
      <<prefix::binary, "=''", encoded::binary>> | acc
    ])
  end

  defp encode_parameter(:encode, name, index, value, enc_len, acc) do
    prefix = <<name::binary, 42, :erlang.integer_to_binary(index)::binary, 42>>
    {encoded, more} = encode_param_value(:encode, value, 75 - byte_size(prefix))

    encode_parameter(:encode, name, index + 1, more, enc_len, [
      <<prefix::binary, "=", encoded::binary>> | acc
    ])
  end

  defp encode_parameter(:quote, name, 0, value, enc_len, _acc)
       when byte_size(name) + 2 + enc_len + 1 <= 76 do
    {quoted, <<>>} = encode_param_value(:quote, value, 73 - byte_size(name))
    [<<name::binary, 61, 34, quoted::binary, 34>>]
  end

  defp encode_parameter(:quote, name, index, value, enc_len, acc) do
    prefix = <<name::binary, 42, :erlang.integer_to_binary(index)::binary>>
    {quoted, more} = encode_param_value(:quote, value, 73 - byte_size(prefix))

    encode_parameter(:quote, name, index + 1, more, enc_len, [
      <<prefix::binary, 61, 34, quoted::binary, 34>> | acc
    ])
  end

  defp encode_parameter(:plain, name, 0, value, enc_len, _acc)
       when byte_size(name) + 1 + enc_len <= 76 do
    {plain, <<>>} = encode_param_value(:plain, value, 75 - byte_size(name))
    [<<name::binary, 61, plain::binary>>]
  end

  defp encode_parameter(:plain, name, index, value, enc_len, acc) do
    prefix = <<name::binary, 42, :erlang.integer_to_binary(index)::binary>>
    {plain, more} = encode_param_value(:plain, value, 75 - byte_size(prefix))

    encode_parameter(:plain, name, index + 1, more, enc_len, [
      <<prefix::binary, 61, plain::binary>> | acc
    ])
  end

  @spec encode_param_value(:plain | :quote | :encode, binary(), integer()) :: {binary(), binary()}
  defp encode_param_value(:plain, value, len) do
    len1 = max(len, 1)

    case value do
      <<part::size(^len1)-bytes, more::binary>> -> {part, more}
      _ -> {value, <<>>}
    end
  end

  defp encode_param_value(:quote, value, len) do
    encode_param_value_quote(value, len, <<>>)
  end

  defp encode_param_value(:encode, value, len) do
    encode_param_value_encode(value, len, <<>>)
  end

  @spec encode_param_value_quote(binary(), integer(), binary()) :: {binary(), binary()}
  defp encode_param_value_quote(<<>>, _len, acc) do
    {acc, <<>>}
  end

  defp encode_param_value_quote(<<c, more::binary>> = all, len, acc) do
    case c === 34 or c === 92 do
      true when len >= 2 or acc === <<>> ->
        encode_param_value_quote(more, len - 2, <<acc::binary, 92, c>>)

      false when len >= 1 or acc === <<>> ->
        encode_param_value_quote(more, len - 1, <<acc::binary, c>>)

      _ ->
        {acc, all}
    end
  end

  @spec encode_param_value_encode(binary(), integer(), binary()) :: {binary(), binary()}
  defp encode_param_value_encode(<<>>, _len, acc) do
    {acc, <<>>}
  end

  defp encode_param_value_encode(<<c, more::binary>> = all, len, acc) do
    encoded = encode_parameter_byte(c)
    size = byte_size(encoded)

    if len >= size or acc == "" do
      encode_param_value_encode(more, len - size, acc <> encoded)
    else
      {acc, all}
    end
  end

  @spec encode_parameter_byte(byte()) :: binary()
  defp encode_parameter_byte(c) when c <= 31 or c >= 127 or c in ~c"()<>@,;:/[]?= *'%" do
    <<hi::4, lo::4>> = <<c>>
    <<?%, Binary.hex(hi), Binary.hex(lo)>>
  end

  defp encode_parameter_byte(c), do: <<c>>

  @spec decide_param_encoding_method(binary()) ::
          {:plain | :quote | :encode | :encode_utf8, non_neg_integer()}
  defp decide_param_encoding_method(value) do
    decide_param_encoding_method(value, :plain, 0, 0, 0)
  end

  @spec decide_param_encoding_method(
          binary(),
          :plain | :quote | :encode | :encode_utf8,
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:plain | :quote | :encode | :encode_utf8, non_neg_integer()}
  defp decide_param_encoding_method(<<>>, method, l_p, l_q, l_e) do
    l =
      case method do
        :plain -> l_p
        :quote -> l_q
        :encode -> l_e
        :encode_utf8 -> l_e
      end

    {method, l}
  end

  defp decide_param_encoding_method(<<c::utf8, rest::binary>>, method, l_p, l_q, l_e)
       when byte_size(<<c::utf8>>) > 1 do
    decide_param_encoding_method(
      rest,
      change_param_encoding_method(method, :encode_utf8),
      l_p,
      l_q,
      l_e + 3 * byte_size(<<c::utf8>>)
    )
  end

  defp decide_param_encoding_method(<<c, rest::binary>>, method, l_p, l_q, l_e)
       when c <= 31 or c >= 127 do
    decide_param_encoding_method(
      rest,
      change_param_encoding_method(method, :encode),
      l_p,
      l_q,
      l_e + 3
    )
  end

  defp decide_param_encoding_method(<<c, rest::binary>>, method, l_p, l_q, l_e)
       when c === 34 or c === 92 do
    decide_param_encoding_method(
      rest,
      change_param_encoding_method(method, :quote),
      l_p,
      l_q + 2,
      l_e + 3
    )
  end

  defp decide_param_encoding_method(<<c, rest::binary>>, method, l_p, l_q, l_e)
       when c in ~c"()<>@,;:/[]?= " do
    decide_param_encoding_method(
      rest,
      change_param_encoding_method(method, :quote),
      l_p,
      l_q + 1,
      l_e + 3
    )
  end

  defp decide_param_encoding_method(<<c, rest::binary>>, method, l_p, l_q, l_e)
       when c === 42 or c === 39 or c === 37 do
    decide_param_encoding_method(rest, method, l_p + 1, l_q + 1, l_e + 3)
  end

  defp decide_param_encoding_method(<<_, rest::binary>>, method, l_p, l_q, l_e) do
    decide_param_encoding_method(rest, method, l_p + 1, l_q + 1, l_e + 1)
  end

  @spec change_param_encoding_method(cur_method, new_method) :: method
        when cur_method: method,
             new_method: method,
             method: :plain | :quote | :encode | :encode_utf8
  defp change_param_encoding_method(method, method) do
    method
  end

  defp change_param_encoding_method(cur_method, new_method) do
    change_param_encoding_method([:encode_utf8, :encode, :quote], cur_method, new_method)
  end

  @spec change_param_encoding_method([atom()], atom(), atom()) :: atom()
  defp change_param_encoding_method([cur_method | _more], cur_method, _new_method) do
    cur_method
  end

  defp change_param_encoding_method([new_method | _more], _cur_method, new_method) do
    new_method
  end

  defp change_param_encoding_method([_ | more], cur_method, new_method) do
    change_param_encoding_method(more, cur_method, new_method)
  end

  defp change_param_encoding_method([], _cur_method, new_method) do
    new_method
  end
end
