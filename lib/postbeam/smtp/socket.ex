# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# Copyright 2009 Jack Danger Canty <code@jackcanty.com>. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

defmodule Postbeam.SMTP.Socket do
  @moduledoc "TCP and TLS operations through public OTP socket APIs."
  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  @typep protocol() :: :tcp | :ssl
  @typep address() :: :inet.ip_address() | charlist() | binary()
  @type socket() :: :ssl.sslsocket() | :gen_tcp.socket()
  @spec connect(protocol(), address(), pos_integer()) :: {:ok, socket()} | {:error, any()}
  def connect(protocol, address, port) do
    connect(protocol, address, port, [], :infinity)
  end

  @spec connect(protocol(), address(), pos_integer(), list()) :: {:ok, socket()} | {:error, any()}
  def connect(protocol, address, port, opts) do
    connect(protocol, address, port, opts, :infinity)
  end

  @spec connect(protocol(), address(), pos_integer(), list(), non_neg_integer() | :infinity) ::
          {:ok, socket()} | {:error, any()}
  def connect(:tcp, address, port, opts, time) do
    :gen_tcp.connect(address, port, tcp_connect_options(opts), time)
  end

  def connect(:ssl, address, port, opts, time) do
    :ssl.connect(
      address,
      port,
      opts |> ssl_connect_options() |> Postbeam.SMTP.TLS.client_options(),
      time
    )
  end

  @spec listen(protocol(), pos_integer()) :: {:ok, socket()} | {:error, any()}
  def listen(protocol, port) do
    listen(protocol, port, [])
  end

  @spec listen(protocol(), pos_integer(), list()) :: {:ok, socket()} | {:error, any()}
  def listen(:ssl, port, options) do
    :ssl.listen(port, options |> ssl_listen_options() |> Postbeam.SMTP.TLS.server_options())
  end

  def listen(:tcp, port, options) do
    :gen_tcp.listen(port, tcp_listen_options(options))
  end

  @spec accept(socket()) :: {:ok, socket()} | {:error, any()}
  def accept(socket) do
    accept(socket, :infinity)
  end

  @spec accept(socket(), pos_integer() | :infinity) :: {:ok, socket()} | {:error, any()}
  def accept(socket, timeout) when is_port(socket) do
    case :gen_tcp.accept(socket, timeout) do
      {:ok, new_socket} ->
        {:ok, opts} = :inet.getopts(socket, [:active, :keepalive, :packet, :reuseaddr])
        :inet.setopts(new_socket, opts)
        {:ok, new_socket}

      {:error, _} = error ->
        error
    end
  end

  def accept(socket, timeout) do
    case :ssl.transport_accept(socket, timeout) do
      {:ok, new_socket} -> :ssl.handshake(new_socket)
      {:error, _} = error -> error
    end
  end

  @spec send(socket(), binary() | charlist() | iolist()) :: :ok | {:error, any()}
  def send(socket, data) when is_port(socket) do
    :gen_tcp.send(socket, data)
  end

  def send(socket, data) do
    :ssl.send(socket, data)
  end

  @spec recv(socket(), non_neg_integer()) :: {:ok, any()} | {:error, any()}
  def recv(socket, var_length) do
    recv(socket, var_length, :infinity)
  end

  @spec recv(socket(), non_neg_integer(), non_neg_integer() | :infinity) ::
          {:ok, any()} | {:error, any()}
  def recv(socket, var_length, timeout) when is_port(socket) do
    :gen_tcp.recv(socket, var_length, timeout)
  end

  def recv(socket, var_length, timeout) do
    :ssl.recv(socket, var_length, timeout)
  end

  @spec controlling_process(socket(), pid()) :: :ok | {:error, any()}
  def controlling_process(socket, new_owner) when is_port(socket) do
    :gen_tcp.controlling_process(socket, new_owner)
  end

  def controlling_process(socket, new_owner) do
    :ssl.controlling_process(socket, new_owner)
  end

  @spec peername(socket()) :: {:ok, {:inet.ip_address(), non_neg_integer()}} | {:error, any()}
  def peername(socket) when is_port(socket) do
    :inet.peername(socket)
  end

  def peername(socket) do
    :ssl.peername(socket)
  end

  @spec close(socket()) :: :ok
  def close(socket) when is_port(socket) do
    :gen_tcp.close(socket)
  end

  def close(socket) do
    :ssl.close(socket)
  end

  @spec shutdown(socket(), :read | :write | :read_write) :: :ok | {:error, any()}
  def shutdown(socket, how) when is_port(socket) do
    :gen_tcp.shutdown(socket, how)
  end

  def shutdown(socket, how) do
    :ssl.shutdown(socket, how)
  end

  @spec active_once(socket()) :: :ok | {:error, any()}
  def active_once(socket) when is_port(socket) do
    :inet.setopts(socket, active: :once)
  end

  def active_once(socket) do
    :ssl.setopts(socket, active: :once)
  end

  @spec setopts(socket(), list()) :: :ok | {:error, any()}
  def setopts(socket, options) when is_port(socket) do
    :inet.setopts(socket, options)
  end

  def setopts(socket, options) do
    :ssl.setopts(socket, options)
  end

  @spec get_proto(any()) :: :tcp | :ssl
  def get_proto(socket) when is_port(socket) do
    :tcp
  end

  def get_proto(_socket) do
    :ssl
  end

  @spec begin_inet_async(socket()) :: any()
  def begin_inet_async(socket) do
    owner = self()
    ref = make_ref()

    spawn_link(fn ->
      result =
        if is_port(socket) do
          :gen_tcp.accept(socket)
        else
          :ssl.transport_accept(socket)
        end

      result =
        case result do
          {:ok, accepted} ->
            case controlling_process(accepted, owner) do
              :ok ->
                {:ok, accepted}

              {:error, _} = error ->
                close(accepted)
                error
            end

          error ->
            error
        end

      Kernel.send(owner, {:inet_async, socket, ref, result})
    end)

    {:ok, ref}
  end

  @spec handle_inet_async({:inet_async, socket(), any(), {:ok, socket()}}) :: {:ok, socket()}
  def handle_inet_async({:inet_async, listen_socket, _, {:ok, client_socket}}) do
    handle_inet_async(listen_socket, client_socket, [])
  end

  @spec handle_inet_async(socket(), socket()) :: {:ok, socket()}
  def handle_inet_async(listen_object, client_socket) do
    handle_inet_async(listen_object, client_socket, [])
  end

  @spec handle_inet_async(socket(), socket(), list()) :: {:ok, socket()}
  def handle_inet_async(listen_object, client_socket, options) do
    begin_inet_async(listen_object)

    if is_port(listen_object) do
      {:ok, client_socket}
    else
      :ssl.handshake(client_socket, options, 15_000)
    end
  end

  @spec to_ssl_server(socket()) :: {:ok, :ssl.sslsocket()} | {:error, any()}
  def to_ssl_server(socket) do
    to_ssl_server(socket, [])
  end

  @spec to_ssl_server(socket(), list()) :: {:ok, :ssl.sslsocket()} | {:error, any()}
  def to_ssl_server(socket, options) do
    to_ssl_server(socket, options, :infinity)
  end

  @spec to_ssl_server(socket(), list(), non_neg_integer() | :infinity) ::
          {:ok, :ssl.sslsocket()} | {:error, any()}
  def to_ssl_server(socket, options, timeout) when is_port(socket) do
    :ssl.handshake(socket, ssl_listen_options(options), timeout)
  end

  def to_ssl_server(_socket, _options, _timeout) do
    {:error, :already_ssl}
  end

  @spec to_ssl_client(socket()) :: {:ok, :ssl.sslsocket()} | {:error, :already_ssl}
  def to_ssl_client(socket) do
    to_ssl_client(socket, [])
  end

  @spec to_ssl_client(socket(), list()) :: {:ok, :ssl.sslsocket()} | {:error, :already_ssl}
  def to_ssl_client(socket, options) do
    to_ssl_client(socket, options, :infinity)
  end

  @spec to_ssl_client(socket(), list(), non_neg_integer() | :infinity) ::
          {:ok, :ssl.sslsocket()} | {:error, :already_ssl}
  def to_ssl_client(socket, options, timeout) when is_port(socket) do
    :ssl.connect(
      socket,
      options |> ssl_connect_options() |> Postbeam.SMTP.TLS.client_options(),
      timeout
    )
  end

  def to_ssl_client(_socket, _options, _timeout) do
    {:error, :already_ssl}
  end

  @spec type(socket()) :: protocol()
  def type(socket) when is_port(socket) do
    :tcp
  end

  def type(_socket) do
    :ssl
  end

  defp tcp_listen_options([format | options]) when format === :list or format === :binary do
    tcp_listen_options(options, format)
  end

  defp tcp_listen_options(options) do
    tcp_listen_options(options, :list)
  end

  defp tcp_listen_options(options, format) do
    parse_address([
      format
      | proplist_merge(options,
          active: false,
          backlog: 30,
          ip: {0, 0, 0, 0},
          keepalive: true,
          packet: :line,
          reuseaddr: true
        )
    ])
  end

  defp ssl_listen_options([format | options]) when format === :list or format === :binary do
    ssl_listen_options(options, format)
  end

  defp ssl_listen_options(options) do
    ssl_listen_options(options, :list)
  end

  defp ssl_listen_options(options, format) do
    parse_address([
      format
      | proplist_merge(options,
          active: false,
          backlog: 30,
          certfile: ~c"server.crt",
          depth: 0,
          keepalive: true,
          keyfile: ~c"server.key",
          packet: :line,
          reuse_sessions: false,
          reuseaddr: true
        )
    ])
  end

  defp tcp_connect_options([format | options]) when format === :list or format === :binary do
    tcp_connect_options(options, format)
  end

  defp tcp_connect_options(options) do
    tcp_connect_options(options, :list)
  end

  defp tcp_connect_options(options, format) do
    parse_address([
      format | proplist_merge(options, active: false, packet: :line, ip: {0, 0, 0, 0}, port: 0)
    ])
  end

  defp ssl_connect_options([format | options]) when format === :list or format === :binary do
    ssl_connect_options(options, format)
  end

  defp ssl_connect_options(options) do
    ssl_connect_options(options, :list)
  end

  defp ssl_connect_options(options, format) do
    parse_address([
      format
      | proplist_merge(options, active: false, depth: 0, packet: :line, ip: {0, 0, 0, 0}, port: 0)
    ])
  end

  defp proplist_merge(primary_list, default_list) do
    {primary_tuples, primary_other} = :lists.partition(fn x -> is_tuple(x) end, primary_list)
    {default_tuples, default_other} = :lists.partition(fn x -> is_tuple(x) end, default_list)

    merged_tuples =
      :lists.ukeymerge(1, :lists.keysort(1, primary_tuples), :lists.keysort(1, default_tuples))

    merged_other = :lists.umerge(:lists.sort(primary_other), :lists.sort(default_other))
    merged_tuples ++ merged_other
  end

  defp parse_address(options) do
    case :proplists.get_value(:ip, options) do
      x when is_tuple(x) ->
        options

      x when is_list(x) ->
        case :inet_parse.address(x) do
          {:error, _} = error -> :erlang.error(error)
          {:ok, ip_address} -> :proplists.delete(:ip, options) ++ [ip: ip_address]
        end

      _ ->
        options
    end
  end

  @deprecated "SSL sockets are opaque; use sockname/1 or peername/1 instead"
  def extract_port_from_socket(socket) when is_port(socket) do
    socket
  end

  def extract_port_from_socket(_socket) do
    raise ArgumentError, "SSL sockets do not expose a transport port"
  end

  @spec sockname(socket()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def sockname(socket) when is_port(socket) do
    :inet.sockname(socket)
  end

  def sockname(socket) do
    :ssl.sockname(socket)
  end
end
