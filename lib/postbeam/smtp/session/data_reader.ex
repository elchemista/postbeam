# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
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

  # Keep a short suffix between reads so framing never depends on TCP packet
  # boundaries. Completed chunks stay as iodata until the whole message arrives.
  def read(transport, socket, max_size, options) do
    mode = Keyword.get(options, :allow_bare_newlines, false)
    receive_data(transport, socket, max_size, mode, [], "", 0)
  end

  defp receive_data(transport, socket, max_size, mode, chunks, pending, size) do
    case transport.recv(socket, 0, 1000) do
      {:ok, packet} ->
        data = pending <> packet

        case terminator(data, chunks == []) do
          {offset, length} ->
            body = binary_part(data, 0, offset)
            rest = binary_part(data, offset + length, byte_size(data) - offset - length)

            with {:ok, chunk} <- normalize(body, mode),
                 :ok <- check_size(size + byte_size(chunk), max_size) do
              {:receive_data, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), rest}
            else
              {:error, reason} -> {:receive_data, {:error, reason}}
            end

          :nomatch ->
            {body, pending} = split_pending(data)

            with {:ok, chunk} <- normalize(body, mode),
                 :ok <- check_size(size + byte_size(chunk), max_size) do
              chunks = if chunk == "", do: chunks, else: [chunk | chunks]

              receive_data(
                transport,
                socket,
                max_size,
                mode,
                chunks,
                pending,
                size + byte_size(chunk)
              )
            else
              {:error, reason} -> {:receive_data, {:error, reason}}
            end
        end

      {:error, :timeout} ->
        receive_data(transport, socket, max_size, mode, chunks, pending, size)

      {:error, reason} ->
        {:receive_data, {:error, reason}}
    end
  end

  defp terminator(<<".\r\n", _::binary>>, true), do: {0, 3}
  defp terminator(data, _first_chunk), do: :binary.match(data, "\r\n.\r\n")

  defp split_pending(data) when byte_size(data) <= 4, do: {"", data}

  defp split_pending(data) do
    length = byte_size(data) - 4
    # Keep CRLF together for validation and repair, even at a chunk boundary.
    length = if :binary.at(data, length - 1) == ?\r, do: length - 1, else: length
    {binary_part(data, 0, length), binary_part(data, length, byte_size(data) - length)}
  end

  defp normalize(data, :ignore), do: {:ok, data}

  defp normalize(data, mode) do
    case {check_for_bare_crlf(data, 0), mode} do
      {false, _} -> {:ok, data}
      {true, :fix} -> {:ok, fix_bare_crlf(data, 0)}
      {true, :strip} -> {:ok, strip_bare_crlf(data, 0)}
      {true, _} -> {:error, :bare_newline}
    end
  end

  defp check_size(_size, :infinity), do: :ok
  defp check_size(size, max_size) when size <= max_size, do: :ok
  defp check_size(_size, _max_size), do: {:error, :size_exceeded}

  defp check_for_bare_crlf(bin, offset) do
    case {:re.run(bin, ~c"(?<!\r)\n", capture: :none, offset: offset),
          :re.run(bin, ~c"\r(?!\n)", capture: :none, offset: offset)} do
      {:match, _} -> true
      {_, :match} -> true
      _ -> false
    end
  end

  defp fix_bare_crlf(bin, offset) do
    options = [{:offset, offset}, {:return, :binary}, :global]

    :re.replace(
      :re.replace(bin, ~c"(?<!\r)\n", ~c"\r\n", options),
      ~c"\r(?!\n)",
      ~c"\r\n",
      options
    )
  end

  defp strip_bare_crlf(bin, offset) do
    options = [{:offset, offset}, {:return, :binary}, :global]
    :re.replace(:re.replace(bin, ~c"(?<!\r)\n", [], options), ~c"\r(?!\n)", [], options)
  end

  def check_bare_crlf(binary, _, :ignore, _) do
    binary
  end

  def check_bare_crlf(<<10, _rest::binary>> = bin, prev, op, 0 = _offset)
      when byte_size(prev) > 0 do
    lastchar = Postbeam.SMTP.Binary.substr(prev, -1)

    case lastchar do
      "\r" -> check_bare_crlf(bin, <<>>, op, 1)
      _ when op == false -> :error
      _ -> check_bare_crlf(bin, <<>>, op, 0)
    end
  end

  def check_bare_crlf(binary, _prev, op, offset) do
    last = Postbeam.SMTP.Binary.substr(binary, -1)

    case last do
      "\r" ->
        new_bin = Postbeam.SMTP.Binary.substr(binary, 1, byte_size(binary) - 1)

        case check_for_bare_crlf(new_bin, offset) do
          true when op == :fix ->
            :erlang.list_to_binary([fix_bare_crlf(new_bin, offset), ~c"\r"])

          true when op == :strip ->
            :erlang.list_to_binary([strip_bare_crlf(new_bin, offset), ~c"\r"])

          true ->
            :error

          false ->
            binary
        end

      _ ->
        case check_for_bare_crlf(binary, offset) do
          true when op == :fix -> fix_bare_crlf(binary, offset)
          true when op == :strip -> strip_bare_crlf(binary, offset)
          true -> :error
          false -> binary
        end
    end
  end
end
