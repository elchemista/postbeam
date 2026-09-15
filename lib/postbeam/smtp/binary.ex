# Copyright 2009 Andrew Thompson <andrew@hijacked.us>. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#   1. Redistributions of source code must retain the above copyright notice,
#      this list of conditions and the following disclaimer.
#   2. Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE FREEBSD PROJECT ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
# EVENT SHALL THE FREEBSD PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

defmodule Postbeam.SMTP.Binary do
  @moduledoc """
  Byte-oriented helpers for mail protocols and MIME payloads.

  Positions use the historical one-based API; a missing match is `0`.
  These functions deliberately leave non-ASCII bytes unchanged.
  """

  @spec strchr(binary(), byte()) :: non_neg_integer()
  def strchr(binary, byte), do: strpos(binary, <<byte>>)

  @spec strrchr(binary(), byte()) :: non_neg_integer()
  def strrchr(binary, byte), do: strrpos(binary, <<byte>>)

  @spec strpos(binary(), iodata()) :: non_neg_integer()
  def strpos(binary, pattern) do
    case :binary.match(binary, IO.iodata_to_binary(pattern)) do
      {index, _length} -> index + 1
      :nomatch -> 0
    end
  end

  @spec strrpos(binary(), iodata()) :: non_neg_integer()
  def strrpos(binary, pattern) do
    pattern = IO.iodata_to_binary(pattern)

    case :binary.match(reverse(binary), reverse(pattern)) do
      {index, length} -> byte_size(binary) - index - length + 1
      :nomatch -> 0
    end
  end

  @spec substr(binary(), integer()) :: binary()
  def substr(<<>>, _start), do: <<>>

  def substr(binary, start) when start != 0 do
    offset = offset(binary, start)
    binary_part(binary, offset, byte_size(binary) - offset)
  end

  @spec substr(binary(), integer(), non_neg_integer()) :: binary()
  def substr(<<>>, _start, _length), do: <<>>

  def substr(binary, start, length) when start != 0,
    do: binary_part(binary, offset(binary, start), length)

  defp offset(_binary, start) when start > 0, do: start - 1
  defp offset(binary, start), do: byte_size(binary) + start

  @spec split(binary(), binary()) :: [binary()]
  def split(binary, separator) do
    # Drop exactly one trailing empty field, as the original API does.
    case :binary.split(binary, separator, [:global]) |> Enum.reverse() do
      [<<>> | rest] -> Enum.reverse(rest)
      parts -> Enum.reverse(parts)
    end
  end

  @spec split(binary(), binary(), pos_integer()) :: [binary()]
  def split(binary, separator, count) when is_integer(count) and count > 0,
    do: split_parts(binary, separator, count, [])

  defp split_parts(<<>>, _separator, _count, acc), do: Enum.reverse(acc)
  defp split_parts(binary, _separator, 1, acc), do: Enum.reverse([binary | acc])

  defp split_parts(<<byte, rest::binary>>, <<>>, count, acc),
    do: split_parts(rest, <<>>, count - 1, [<<byte>> | acc])

  defp split_parts(binary, separator, count, acc) do
    case :binary.split(binary, separator) do
      [head, rest] -> split_parts(rest, separator, count - 1, [head | acc])
      [rest] -> Enum.reverse([rest | acc])
    end
  end

  @spec chomp(binary()) :: binary()
  def chomp(binary) do
    size = byte_size(binary)

    cond do
      size >= 2 and binary_part(binary, size - 2, 2) == "\r\n" ->
        binary_part(binary, 0, size - 2)

      size > 0 and :binary.last(binary) in [?\r, ?\n] ->
        binary_part(binary, 0, size - 1)

      true ->
        binary
    end
  end

  @spec strip(binary(), :left | :right | :both, byte()) :: binary()
  def strip(binary, direction \\ :both, byte \\ ?\s)
  def strip(<<>>, _direction, _byte), do: <<>>
  def strip(binary, :both, byte), do: binary |> strip(:left, byte) |> strip(:right, byte)
  def strip(<<byte, rest::binary>>, :left, byte), do: strip(rest, :left, byte)
  def strip(binary, :left, _byte), do: binary

  def strip(binary, :right, byte) do
    if :binary.last(binary) == byte,
      do: strip(binary_part(binary, 0, byte_size(binary) - 1), :right, byte),
      else: binary
  end

  @spec to_lower(binary()) :: binary()
  def to_lower(binary) do
    for <<byte <- binary>>, into: <<>> do
      <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>
    end
  end

  @spec to_upper(binary()) :: binary()
  def to_upper(binary) do
    for <<byte <- binary>>, into: <<>> do
      <<if(byte in ?a..?z, do: byte - 32, else: byte)>>
    end
  end

  @spec all((byte() -> boolean()), binary()) :: boolean()
  def all(_fun, <<>>), do: true
  def all(fun, <<byte, rest::binary>>), do: fun.(byte) and all(fun, rest)

  @spec reverse(binary()) :: binary()
  def reverse(binary),
    do: binary |> :binary.bin_to_list() |> Enum.reverse() |> :erlang.list_to_binary()

  @spec reverse_str_to_bin(charlist()) :: binary()
  def reverse_str_to_bin(string), do: string |> Enum.reverse() |> :erlang.list_to_binary()

  @spec join([iodata()], iodata()) :: binary()
  def join(parts, separator), do: parts |> Enum.intersperse(separator) |> IO.iodata_to_binary()
end
