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

defmodule Postbeam.SMTP.Server do
  @moduledoc """
  Ranch listeners with a supervised `Postbeam.SMTP.Session` process per connection.

  Add `{Postbeam.SMTP.Server, {MyHandler, port: 2525}}` to your supervision tree.
  Use a distinct `:name` for each listener. `:num_acceptors` defaults to 10 and
  `:max_connections` to 1024 per Ranch connection supervisor; `:ranch_opts`
  exposes Ranch's remaining tuning options and takes precedence.
  """

  alias Postbeam.SMTP.Log
  alias Postbeam.SMTP.Session
  alias Postbeam.SMTP.Util

  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  @typep server_name() :: any()
  @type options() ::
          list(
            {:domain, charlist()}
            | {:address, :inet.ip4_address()}
            | {:family, :inet | :inet6}
            | {:port, :inet.port_number()}
            | {:protocol, :tcp | :ssl}
            | {:num_acceptors, pos_integer()}
            | {:max_connections, pos_integer() | :infinity}
            | {:name, term()}
            | {:ranch_opts, :ranch.opts()}
            | {:sessionoptions, Session.options()}
          )
  @spec start(server_name(), module(), options()) :: {:ok, pid()} | {:error, any()}
  @doc "Starts a named SMTP listener using the handler and options."
  def start(server_name, callback_module, options) when is_list(options) do
    case convert_options(callback_module, options) do
      {:ok, transport, transport_opts, protocol_opts} ->
        :ranch.start_listener(
          server_name,
          transport,
          transport_opts,
          Session,
          protocol_opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Builds a Ranch listener child specification for a supervision tree."
  @spec child_spec(server_name(), module(), options()) :: Supervisor.child_spec()
  def child_spec(server_name, callback_module, options) do
    case convert_options(callback_module, options) do
      {:ok, transport, transport_opts, protocol_opts} ->
        :ranch.child_spec(
          server_name,
          transport,
          transport_opts,
          Session,
          protocol_opts
        )

      {:error, reason} ->
        :erlang.error(reason)
    end
  end

  @doc "Starts a Ranch listener beneath your application's supervisor."
  @spec child_spec({module(), options()} | keyword()) :: Supervisor.child_spec()
  def child_spec({callback_module, options}) do
    name = Keyword.get(options, :name, {__MODULE__, callback_module})
    child_spec(name, callback_module, options)
  end

  def child_spec(options) when is_list(options) do
    child_spec({Keyword.fetch!(options, :handler), Keyword.delete(options, :handler)})
  end

  @spec convert_options(module(), options()) ::
          {:ok, module(), map(), {module(), Session.options()}} | {:error, :invalid_lmtp_port}
  defp convert_options(callback_module, options) do
    transport =
      case :proplists.get_value(:protocol, options, :tcp) do
        :tcp -> :ranch_tcp
        :ssl -> :ranch_ssl
      end

    family = :proplists.get_value(:family, options, :inet)
    address = :proplists.get_value(:address, options, {0, 0, 0, 0})
    port = :proplists.get_value(:port, options, 2525)
    hostname = Keyword.get_lazy(options, :domain, &Util.guess_fqdn/0)
    protocol_opts = :proplists.get_value(:sessionoptions, options, [])
    email_transfer_protocol = :proplists.get_value(:protocol, protocol_opts, :smtp)

    case {email_transfer_protocol, port} do
      {:lmtp, 25} ->
        Log.error(
          ~c"LMTP is different from SMTP, it MUST NOT be used on the TCP port 25",
          %{domain: [:postbeam, :server]}
        )

        {:error, :invalid_lmtp_port}

      _ ->
        protocol_opts1 = {callback_module, [{:hostname, hostname} | protocol_opts]}

        ranch_opts =
          :proplists.get_value(:ranch_opts, options, %{})
          |> Map.put_new(:num_acceptors, Keyword.get(options, :num_acceptors, 10))
          |> Map.put_new(:max_connections, Keyword.get(options, :max_connections, 1024))

        socket_opts = :maps.get(:socket_opts, ranch_opts, [])

        transport_opts =
          Map.merge(ranch_opts, %{
            socket_opts: [{:port, port}, {:ip, address}, {:keepalive, true}, family | socket_opts]
          })

        {:ok, transport, transport_opts, protocol_opts1}
    end
  end

  @spec start(module(), options()) :: {:ok, pid()} | :ignore | {:error, any()}
  @doc "Starts a named SMTP listener using the handler and options."
  def start(callback_module, options) when is_list(options) do
    start(__MODULE__, callback_module, options)
  end

  @spec start(atom()) :: {:ok, pid()} | :ignore | {:error, any()}
  @doc "Starts a named SMTP listener using the handler and options."
  def start(callback_module) do
    start(callback_module, [])
  end

  @spec stop(server_name()) :: :ok
  @doc "Stops the named listener and its connections."
  def stop(name) do
    :ranch.stop_listener(name)
  end

  @spec sessions(server_name()) :: list(pid())
  @doc "Lists connection processes owned by the listener."
  def sessions(name) do
    :ranch.procs(name, :connections)
  end
end
