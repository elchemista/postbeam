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

defmodule Postbeam.SMTP.Session.DataReader do
  @moduledoc false

  alias Postbeam.SMTP.Binary

  defstruct [:transport, :socket, :max_size, :mode, chunks: [], pending: "", size: 0]

  @typep mode :: false | :ignore | :fix | :strip
  @typep t :: %__MODULE__{
           transport: module(),
           socket: term(),
           max_size: non_neg_integer() | :infinity,
           mode: mode(),
           chunks: [binary()],
           pending: binary(),
           size: non_neg_integer()
         }
  @typep result :: {:receive_data, binary(), binary()} | {:receive_data, {:error, term()}}

  @doc false
  @spec read(module(), term(), non_neg_integer() | :infinity, keyword()) :: result()
  def read(transport, socket, max_size, options) do
    receive_data(%__MODULE__{
      transport: transport,
      socket: socket,
      max_size: max_size,
      mode: Keyword.get(options, :allow_bare_newlines, false)
    })
  end

  @spec receive_data(t()) :: result()
  defp receive_data(state) do
    case state.transport.recv(state.socket, 0, 1000) do
      {:ok, packet} -> consume_packet(state, state.pending <> packet)
      {:error, :timeout} -> receive_data(state)
      {:error, reason} -> {:receive_data, {:error, reason}}
    end
  end

  @spec consume_packet(t(), binary()) :: result()
  defp consume_packet(state, data) do
    case terminator(data, state.chunks == []) do
      {offset, length} ->
        <<body::binary-size(^offset), _terminator::binary-size(^length), rest::binary>> = data
        finish(append_chunk(state, body), rest)

      :nomatch ->
        {body, pending} = split_pending(data)
        continue(append_chunk(%{state | pending: pending}, body))
    end
  end

  @spec append_chunk(t(), binary()) :: {:ok, t()} | {:error, :bare_newline | :size_exceeded}
  defp append_chunk(state, body) do
    with {:ok, chunk} <- normalize(body, state.mode),
         size = state.size + byte_size(chunk),
         :ok <- check_size(size, state.max_size) do
      chunks = if chunk == "", do: state.chunks, else: [chunk | state.chunks]
      {:ok, %{state | chunks: chunks, size: size}}
    end
  end

  @spec finish({:ok, t()} | {:error, term()}, binary()) :: result()
  defp finish({:ok, state}, rest) do
    {:receive_data, state.chunks |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp finish({:error, reason}, _rest), do: {:receive_data, {:error, reason}}

  @spec continue({:ok, t()} | {:error, term()}) :: result()
  defp continue({:ok, state}), do: receive_data(state)
  defp continue({:error, reason}), do: {:receive_data, {:error, reason}}

  @spec terminator(binary(), boolean()) :: :nomatch | {non_neg_integer(), pos_integer()}
  defp terminator(<<".\r\n", _::binary>>, true), do: {0, 3}
  defp terminator(data, _first_chunk), do: :binary.match(data, "\r\n.\r\n")

  @spec split_pending(binary()) :: {binary(), binary()}
  defp split_pending(data) when byte_size(data) <= 4, do: {"", data}

  defp split_pending(data) do
    length = byte_size(data) - 4
    # Keep CRLF together for validation and repair, even at a chunk boundary.
    length = if :binary.at(data, length - 1) == ?\r, do: length - 1, else: length
    {binary_part(data, 0, length), binary_part(data, length, byte_size(data) - length)}
  end

  @spec normalize(binary(), mode()) :: {:ok, binary()} | {:error, :bare_newline}
  defp normalize(data, :ignore), do: {:ok, data}

  defp normalize(data, mode) do
    case {check_for_bare_crlf?(data, 0), mode} do
      {false, _} -> {:ok, data}
      {true, :fix} -> {:ok, fix_bare_crlf(data, 0)}
      {true, :strip} -> {:ok, strip_bare_crlf(data, 0)}
      {true, _} -> {:error, :bare_newline}
    end
  end

  @spec check_size(non_neg_integer(), non_neg_integer() | :infinity) ::
          :ok | {:error, :size_exceeded}
  defp check_size(_size, :infinity), do: :ok
  defp check_size(size, max_size) when size <= max_size, do: :ok
  defp check_size(_size, _max_size), do: {:error, :size_exceeded}

  @spec check_for_bare_crlf?(binary(), non_neg_integer()) :: boolean()
  defp check_for_bare_crlf?(bin, offset) do
    case {:re.run(bin, ~c"(?<!\r)\n", capture: :none, offset: offset),
          :re.run(bin, ~c"\r(?!\n)", capture: :none, offset: offset)} do
      {:match, _} -> true
      {_, :match} -> true
      _ -> false
    end
  end

  @spec fix_bare_crlf(binary(), non_neg_integer()) :: binary()
  defp fix_bare_crlf(bin, offset), do: replace_bare_crlf(bin, offset, "\r\n")

  @spec strip_bare_crlf(binary(), non_neg_integer()) :: binary()
  defp strip_bare_crlf(bin, offset), do: replace_bare_crlf(bin, offset, "")

  @spec replace_bare_crlf(binary(), non_neg_integer(), binary()) :: binary()
  defp replace_bare_crlf(bin, offset, replacement) do
    options = [{:offset, offset}, {:return, :binary}, :global]

    bin
    |> :re.replace(~c"(?<!\r)\n", replacement, options)
    |> :re.replace(~c"\r(?!\n)", replacement, options)
  end

  @doc false
  @spec check_bare_crlf(binary(), binary(), mode(), non_neg_integer()) :: binary() | :error
  def check_bare_crlf(binary, _, :ignore, _) do
    binary
  end

  def check_bare_crlf(<<10, _rest::binary>> = bin, prev, op, 0 = _offset)
      when byte_size(prev) > 0 do
    lastchar = Binary.substr(prev, -1)

    case lastchar do
      "\r" -> check_bare_crlf(bin, <<>>, op, 1)
      _ when op == false -> :error
      _ -> check_bare_crlf(bin, <<>>, op, 0)
    end
  end

  def check_bare_crlf(binary, _prev, mode, offset) do
    # Defer a final CR until its following byte is available in the next packet.
    {body, pending} = split_trailing_cr(binary)

    case repair(body, mode, offset) do
      :error -> :error
      repaired -> repaired <> pending
    end
  end

  @spec split_trailing_cr(binary()) :: {binary(), binary()}
  defp split_trailing_cr(binary) do
    if String.ends_with?(binary, "\r") do
      {binary_part(binary, 0, byte_size(binary) - 1), "\r"}
    else
      {binary, ""}
    end
  end

  @spec repair(binary(), mode(), non_neg_integer()) :: binary() | :error
  defp repair(binary, mode, offset) do
    case {check_for_bare_crlf?(binary, offset), mode} do
      {false, _} -> binary
      {true, :fix} -> fix_bare_crlf(binary, offset)
      {true, :strip} -> strip_bare_crlf(binary, offset)
      {true, _} -> :error
    end
  end
end
