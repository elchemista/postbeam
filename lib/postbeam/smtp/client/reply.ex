defmodule Postbeam.SMTP.Client.Reply do
  @moduledoc false

  alias Postbeam.SMTP.Socket

  @spec read_possible_multiline_reply(Socket.socket()) :: {:ok, binary()}
  @doc false
  def read_possible_multiline_reply(socket) do
    case Socket.recv(socket, 0, 1_200_000) do
      {:ok, <<a, b, c, separator, _::binary>> = packet}
      when a in ?0..?9 and b in ?0..?9 and c in ?0..?9 and separator in [?-, ?\s] ->
        if separator == ?- do
          read_multiline_reply(socket, <<a, b, c>>, [packet])
        else
          {:ok, packet}
        end

      {:ok, packet} ->
        quit(socket)
        throw({:unexpected_response, packet})

      error ->
        quit(socket)
        throw({:network_failure, error})
    end
  end

  @spec read_multiline_reply(Socket.socket(), binary(), list(binary())) ::
          {:ok, binary()}
  defp read_multiline_reply(socket, code, acc) do
    case Socket.recv(socket, 0, 1_200_000) do
      {:ok, <<^code::binary-size(3), ?\s, _::binary>> = packet} ->
        {:ok, [packet | acc] |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, <<^code::binary-size(3), ?-, _::binary>> = packet} ->
        read_multiline_reply(socket, code, [packet | acc])

      {:ok, packet} ->
        quit(socket)
        throw({:unexpected_response, Enum.reverse([packet | acc])})

      error ->
        quit(socket)
        throw({:network_failure, error})
    end
  end

  @doc false
  @spec rset_or_quit(Socket.socket()) :: :ok
  def rset_or_quit(socket) do
    :ok = Socket.send(socket, ~c"RSET\r\n")

    case read_possible_multiline_reply(socket) do
      {:ok, <<"250", _rest::binary>>} -> :ok
      {:ok, _msg} -> quit(socket)
    end
  end

  @doc false
  @spec quit(Socket.socket()) :: :ok
  def quit(socket) do
    Socket.send(socket, ~c"QUIT\r\n")
    Socket.close(socket)
    :ok
  end
end
