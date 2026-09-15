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
  @doc "Returns the first one-based byte position, or zero when absent."
  def strchr(binary, byte), do: strpos(binary, <<byte>>)

  @spec strrchr(binary(), byte()) :: non_neg_integer()
  @doc "Returns the last one-based byte position, or zero when absent."
  def strrchr(binary, byte), do: strrpos(binary, <<byte>>)

  @spec strpos(binary(), iodata()) :: non_neg_integer()
  @doc "Returns the first one-based pattern position, or zero when absent."
  def strpos(binary, pattern) do
    case :binary.match(binary, IO.iodata_to_binary(pattern)) do
      {index, _length} -> index + 1
      :nomatch -> 0
    end
  end

  @spec strrpos(binary(), iodata()) :: non_neg_integer()
  @doc "Returns the last one-based pattern position, or zero when absent."
  def strrpos(binary, pattern) do
    pattern = IO.iodata_to_binary(pattern)

    case :binary.match(reverse(binary), reverse(pattern)) do
      {index, length} -> byte_size(binary) - index - length + 1
      :nomatch -> 0
    end
  end

  @spec substr(binary(), integer()) :: binary()
  @doc "Extracts bytes using a one-based start; negative positions count from the end."
  def substr(<<>>, _start), do: <<>>

  def substr(binary, start) when start != 0 do
    offset = offset(binary, start)
    binary_part(binary, offset, byte_size(binary) - offset)
  end

  @spec substr(binary(), integer(), non_neg_integer()) :: binary()
  @doc "Extracts bytes using a one-based start; negative positions count from the end."
  def substr(<<>>, _start, _length), do: <<>>

  def substr(binary, start, length) when start != 0,
    do: binary_part(binary, offset(binary, start), length)

  @spec offset(binary(), integer()) :: non_neg_integer()
  defp offset(_binary, start) when start > 0, do: start - 1
  defp offset(binary, start), do: byte_size(binary) + start

  @spec split(binary(), binary()) :: [binary()]
  @doc "Splits bytes on a separator, dropping one trailing empty field."
  def split(binary, separator) do
    # Drop exactly one trailing empty field, as the original API does.
    case :binary.split(binary, separator, [:global]) |> Enum.reverse() do
      [<<>> | rest] -> Enum.reverse(rest)
      parts -> Enum.reverse(parts)
    end
  end

  @spec split(binary(), binary(), pos_integer()) :: [binary()]
  @doc "Splits bytes on a separator, dropping one trailing empty field."
  def split(binary, separator, count) when is_integer(count) and count > 0,
    do: split_parts(binary, separator, count, [])

  @spec split_parts(binary(), binary(), pos_integer(), [binary()]) :: [binary()]
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
  @doc "Removes one trailing CRLF, CR or LF sequence."
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
  @doc "Removes the requested byte from one or both ends."
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
  @doc "Lowercases ASCII bytes and leaves all other bytes unchanged."
  def to_lower(binary) do
    for <<byte <- binary>>, into: <<>> do
      <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>
    end
  end

  @spec to_upper(binary()) :: binary()
  @doc "Uppercases ASCII bytes and leaves all other bytes unchanged."
  def to_upper(binary) do
    for <<byte <- binary>>, into: <<>> do
      <<if(byte in ?a..?z, do: byte - 32, else: byte)>>
    end
  end

  @spec all((byte() -> boolean()), binary()) :: boolean()
  @doc "Checks whether every byte satisfies the predicate."
  def all(_fun, <<>>), do: true
  def all(fun, <<byte, rest::binary>>), do: fun.(byte) and all(fun, rest)

  @spec reverse(binary()) :: binary()
  @doc "Reverses the order of bytes."
  def reverse(binary),
    do: binary |> :binary.bin_to_list() |> Enum.reverse() |> :erlang.list_to_binary()

  @spec reverse_str_to_bin(charlist()) :: binary()
  @doc "Reverses a byte list and converts it to a binary."
  def reverse_str_to_bin(string), do: string |> Enum.reverse() |> :erlang.list_to_binary()

  @spec join([iodata()], iodata()) :: binary()
  @doc "Joins byte strings with the supplied separator."
  def join(parts, separator), do: parts |> Enum.intersperse(separator) |> IO.iodata_to_binary()

  @doc "Converts a nibble to an uppercase hexadecimal digit."
  @spec hex(0..15) :: byte()
  def hex(n) when n >= 10 do
    n + 65 - 10
  end

  def hex(n) do
    n + 48
  end

  @doc "Converts a hexadecimal digit to a nibble."
  @spec unhex(byte()) :: 0..15
  def unhex(c) when c >= 97 do
    c - 97 + 10
  end

  def unhex(c) when c >= 65 do
    c - 65 + 10
  end

  def unhex(c) do
    c - 48
  end

  @doc "Counts bytes that satisfy the predicate and bytes that do not."
  @spec partition_count_bytes((byte() -> boolean()), binary()) ::
          {non_neg_integer(), non_neg_integer()}
  def partition_count_bytes(fun, bin) do
    partition_count_bytes(fun, bin, {0, 0})
  end

  @spec partition_count_bytes(
          (byte() -> boolean()),
          binary(),
          {non_neg_integer(), non_neg_integer()}
        ) :: {non_neg_integer(), non_neg_integer()}
  defp partition_count_bytes(_fun, <<>>, partition_counts) do
    partition_counts
  end

  defp partition_count_bytes(fun, <<c, more::binary>>, {trues, falses}) do
    new_partition_counts =
      case fun.(c) do
        true -> {trues + 1, falses}
        false -> {trues, falses + 1}
      end

    partition_count_bytes(fun, more, new_partition_counts)
  end
end
