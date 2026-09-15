defmodule Postbeam.SMTP.MIME.TransferEncoding do
  @moduledoc false

  alias Postbeam.SMTP.Binary

  defguardp is_hex(c) when c in ?0..?9 or c in ?A..?F or c in ?a..?f

  @doc false
  @spec decode_base64(iodata()) :: binary()
  def decode_base64(body) do
    :base64.mime_decode(body)
  end

  @doc false
  @spec decode_quoted_printable(binary()) :: binary()
  def decode_quoted_printable(body) do
    decode_quoted_printable(body, false, <<>>, <<>>)
  end

  @spec decode_quoted_printable(binary(), boolean(), binary(), binary()) :: binary()
  defp decode_quoted_printable(<<>>, _has_soft_eol, _w_s_ps, acc) do
    acc
  end

  defp decode_quoted_printable(<<13, 10, more::binary>>, true, _w_s_ps, acc) do
    decode_quoted_printable(more, false, <<>>, acc)
  end

  defp decode_quoted_printable(<<c, more::binary>>, true, _w_s_ps, acc)
       when c === 32 or c === 9 do
    decode_quoted_printable(more, true, <<>>, acc)
  end

  defp decode_quoted_printable(_body, true, _w_s_ps, _acc) do
    throw(:badchar)
  end

  defp decode_quoted_printable(<<13, 10, more::binary>>, false, _w_s_ps, acc) do
    decode_quoted_printable(more, false, <<>>, <<acc::binary, 13, 10>>)
  end

  defp decode_quoted_printable(<<c, more::binary>>, false, w_s_ps, acc)
       when c === 32 or c === 9 do
    decode_quoted_printable(more, false, <<w_s_ps::binary, c>>, acc)
  end

  defp decode_quoted_printable(<<61, c1, c2, more::binary>>, false, w_s_ps, acc)
       when is_hex(c1) and is_hex(c2) do
    decode_quoted_printable(
      more,
      false,
      <<>>,
      <<acc::binary, w_s_ps::binary, Binary.unhex(c1)::4, Binary.unhex(c2)::4>>
    )
  end

  defp decode_quoted_printable(<<61, more::binary>>, false, w_s_ps, acc) do
    decode_quoted_printable(more, true, <<>>, <<acc::binary, w_s_ps::binary>>)
  end

  defp decode_quoted_printable(<<c, more::binary>>, false, w_s_ps, acc) do
    decode_quoted_printable(more, false, <<>>, <<acc::binary, w_s_ps::binary, c>>)
  end

  @doc false
  @spec encode_body(binary() | :undefined, iodata()) :: iodata()
  def encode_body(:undefined, body) do
    body
  end

  def encode_body(type, body) do
    case Binary.to_lower(type) do
      "quoted-printable" ->
        [inner_body] = body
        encode_quoted_printable(inner_body)

      "base64" ->
        [inner_body] = body
        wrap_to_76(:base64.encode(inner_body))

      _ ->
        body
    end
  end

  @spec wrap_to_76(binary()) :: [binary()]
  defp wrap_to_76(string) do
    [wrap_to_76(string, [])]
  end

  @spec wrap_to_76(binary(), [binary()]) :: binary()
  defp wrap_to_76(<<>>, acc) do
    :erlang.list_to_binary(:lists.reverse(acc))
  end

  defp wrap_to_76(<<head::size(76)-binary, tail::binary>>, acc) do
    wrap_to_76(tail, ["\r\n", head | acc])
  end

  defp wrap_to_76(head, acc) do
    :erlang.list_to_binary(:lists.reverse(["\r\n", head | acc]))
  end

  @doc false
  @spec encode_quoted_printable(binary()) :: [binary()]
  def encode_quoted_printable(body) do
    [encode_quoted_printable(body, <<>>, 0, false, <<>>, 0)]
  end

  @spec encode_quoted_printable(
          binary(),
          binary(),
          non_neg_integer(),
          boolean(),
          binary(),
          non_neg_integer()
        ) :: binary()
  defp encode_quoted_printable(<<>>, acc, _line_len, _has_wsp, word_acc, _word_len) do
    <<acc::binary, word_acc::binary>>
  end

  defp encode_quoted_printable(
         <<13, 10, more::binary>>,
         acc,
         _line_len,
         _has_wsp,
         word_acc,
         _word_len
       ) do
    encode_quoted_printable(more, <<acc::binary, word_acc::binary, 13, 10>>, 0, false, <<>>, 0)
  end

  defp encode_quoted_printable(<<c>>, acc, line_len, _has_wsp, word_acc, word_len)
       when c === 32 or c === 9 do
    enc = encode_quoted_printable_char(c, true)

    case line_len + word_len + 3 > 76 do
      true -> <<acc::binary, word_acc::binary, 61, 13, 10, enc::binary>>
      false -> <<acc::binary, word_acc::binary, enc::binary>>
    end
  end

  defp encode_quoted_printable(
         <<c, 13, 10, more::binary>>,
         acc,
         line_len,
         _has_wsp,
         word_acc,
         word_len
       )
       when c === 32 or c === 9 do
    enc = encode_quoted_printable_char(c, true)

    case line_len + word_len + 3 > 76 do
      true ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, 61, 13, 10, enc::binary, 13, 10>>,
          0,
          false,
          <<>>,
          0
        )

      false ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, enc::binary, 13, 10>>,
          0,
          false,
          <<>>,
          0
        )
    end
  end

  defp encode_quoted_printable(<<c, more::binary>>, acc, line_len, has_wsp, word_acc, word_len) do
    enc = encode_quoted_printable_char(c, false)
    enc_len = byte_size(enc)

    case line_len + word_len + enc_len > 75 do
      true when c === 32 or c === 9 ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, 61, 13, 10, enc::binary>>,
          enc_len,
          true,
          <<>>,
          0
        )

      true when has_wsp and word_len + enc_len <= 75 ->
        encode_quoted_printable(
          more,
          <<acc::binary, 61, 13, 10, word_acc::binary, enc::binary>>,
          word_len + enc_len,
          false,
          <<>>,
          0
        )

      true ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, 61, 13, 10, enc::binary>>,
          enc_len,
          false,
          <<>>,
          0
        )

      false when c === 32 or c === 9 ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, enc::binary>>,
          line_len + word_len + enc_len,
          true,
          <<>>,
          0
        )

      false ->
        encode_quoted_printable(
          more,
          acc,
          line_len,
          has_wsp,
          <<word_acc::binary, enc::binary>>,
          word_len + enc_len
        )
    end
  end

  @spec encode_quoted_printable_char(byte(), boolean()) :: binary()
  defp encode_quoted_printable_char(c, true) do
    <<61, Binary.hex(div(c, 16)), Binary.hex(rem(c, 16))>>
  end

  defp encode_quoted_printable_char(32, false) do
    <<32>>
  end

  defp encode_quoted_printable_char(9, false) do
    <<9>>
  end

  defp encode_quoted_printable_char(61, _force) do
    <<61, 51, 68>>
  end

  defp encode_quoted_printable_char(c, _force) when c <= 32 or c >= 127 do
    encode_quoted_printable_char(c, true)
  end

  defp encode_quoted_printable_char(c, false) do
    <<c>>
  end
end
