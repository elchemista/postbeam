defmodule Postbeam.SMTP.MIME.EncodedWord do
  @moduledoc false

  alias Postbeam.SMTP.Binary

  defguardp is_q_safe(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c" !*+-/"

  @doc false
  @spec rfc2047_utf8_encode(iodata()) :: binary()
  def rfc2047_utf8_encode(value) do
    rfc2047_utf8_encode(value, 0, " ")
  end

  @doc false
  @spec rfc2047_utf8_encode(iodata(), non_neg_integer(), binary()) :: binary()
  def rfc2047_utf8_encode(value, prefix_len, line_indent) when is_binary(value) do
    case ascii_printable?(value) do
      true ->
        value

      false ->
        {readable, encoded} =
          Binary.partition_count_bytes(
            fn c ->
              is_q_safe(c)
            end,
            value
          )

        enc = if readable >= encoded, do: :q, else: :b

        rfc2047_utf8_encode(enc, value, <<>>, prefix_len, line_indent)
    end
  end

  def rfc2047_utf8_encode(value, prefix_len, line_indent) do
    rfc2047_utf8_encode(:erlang.list_to_binary(value), prefix_len, line_indent)
  end

  @doc false
  @spec rfc2047_utf8_encode(:b | :q, binary(), binary(), non_neg_integer(), binary()) :: binary()
  def rfc2047_utf8_encode(_enc, <<>>, acc, _prefix_len, _line_indent) do
    acc
  end

  def rfc2047_utf8_encode(:b, more, acc, prefix_len, line_indent) do
    rfc2047_utf8_encode(:b, more, acc, <<>>, byte_size(line_indent), line_indent, 46 - prefix_len)
  end

  def rfc2047_utf8_encode(:q, more, acc, prefix_len, line_indent) do
    rfc2047_utf8_encode(:q, more, acc, <<>>, byte_size(line_indent), line_indent, 63 - prefix_len)
  end

  @doc false
  @spec rfc2047_utf8_encode(
          :b | :q,
          binary(),
          binary(),
          binary(),
          non_neg_integer(),
          binary(),
          integer()
        ) :: binary()
  def rfc2047_utf8_encode(enc, <<>>, acc, word_acc, _prefix_len, line_indent, _left) do
    rfc2047_append_word(acc, word_acc, enc, line_indent)
  end

  def rfc2047_utf8_encode(
        enc,
        <<c::utf8, more::binary>> = all,
        acc,
        word_acc,
        prefix_len,
        line_indent,
        left
      ) do
    bytes = <<c::utf8>>
    size = byte_size(bytes)

    reqd = if enc == :q and not is_q_safe(c), do: 3 * size, else: size

    case left >= reqd do
      true ->
        rfc2047_utf8_encode(
          enc,
          more,
          acc,
          <<word_acc::binary, bytes::binary>>,
          prefix_len,
          line_indent,
          left - reqd
        )

      false ->
        rfc2047_utf8_encode(
          enc,
          all,
          rfc2047_append_word(acc, word_acc, enc, line_indent),
          prefix_len,
          line_indent
        )
    end
  end

  @spec rfc2047_append_word(binary(), binary(), :b | :q, binary()) :: binary()
  defp rfc2047_append_word(acc, <<>>, _enc, _line_indent) do
    acc
  end

  defp rfc2047_append_word(<<>>, word, enc, _line_indent) do
    rfc2047_encode_word(word, enc)
  end

  defp rfc2047_append_word(acc, word, enc, line_indent) do
    <<acc::binary, 13, 10, line_indent::binary, rfc2047_encode_word(word, enc)::binary>>
  end

  @spec rfc2047_encode_word(binary(), :b | :q) :: binary()
  defp rfc2047_encode_word(word, :q) do
    <<"=?UTF-8?Q?", rfc2047_q_encode(word)::binary, "?=">>
  end

  defp rfc2047_encode_word(word, :b) do
    <<"=?UTF-8?B?", :base64.encode(word)::binary, "?=">>
  end

  @spec rfc2047_q_encode(binary()) :: binary()
  defp rfc2047_q_encode(<<>>) do
    <<>>
  end

  defp rfc2047_q_encode(<<32, more::binary>>) do
    <<95, rfc2047_q_encode(more)::binary>>
  end

  defp rfc2047_q_encode(<<c, more::binary>>) when is_q_safe(c) do
    <<c, rfc2047_q_encode(more)::binary>>
  end

  defp rfc2047_q_encode(<<n1::4, n2::4, more::binary>>) do
    <<61, Binary.hex(n1), Binary.hex(n2), rfc2047_q_encode(more)::binary>>
  end

  @spec ascii_printable?(binary()) :: boolean()
  defp ascii_printable?(<<>>) do
    true
  end

  defp ascii_printable?(<<h, t::binary>>) when h >= 32 and h <= 126 do
    ascii_printable?(t)
  end

  defp ascii_printable?(_) do
    false
  end
end
