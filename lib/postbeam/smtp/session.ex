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

defmodule Postbeam.SMTP.Session do
  @moduledoc "SMTP/LMTP session GenServer, started and supervised by Ranch.\n\nUse `Postbeam.SMTP.Server` to create listeners and `Postbeam.SMTP.Handler` for callbacks."

  alias Postbeam.SMTP.Binary
  alias Postbeam.SMTP.DataSupervisor
  alias Postbeam.SMTP.Log
  alias Postbeam.SMTP.Session.Address
  alias Postbeam.SMTP.Session.DataReader
  alias Postbeam.SMTP.Session.Envelope
  alias Postbeam.SMTP.Session.Response
  alias Postbeam.SMTP.Session.State
  alias Postbeam.SMTP.Session.Transaction
  alias Postbeam.SMTP.TLS
  alias Postbeam.SMTP.Util
  alias Task.Supervisor

  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  use GenServer
  @behaviour :ranch_protocol
  @timeout 180_000
  @typep tls_opt() :: :ssl.tls_server_option()
  @type options() ::
          list(
            {:callbackoptions, any()}
            | {:certfile, :file.name_all()}
            | {:keyfile, :file.name_all()}
            | {:allow_bare_newlines, false | :ignore | :fix | :strip}
            | {:hostname, :inet.hostname()}
            | {:protocol, :smtp | :lmtp}
            | {:tls_options, list(tls_opt())}
          )
  @type error_class() ::
          :tcp_closed
          | :tcp_error
          | :ssl_closed
          | :ssl_error
          | :data_rejected
          | :timeout
          | :out_of_order
          | :ssl_handshake_error
          | :send_error
          | :setopts_error
          | :data_receive_error
  @type protocol_message() :: charlist() | iodata()
  @impl :ranch_protocol
  @spec start_link(:ranch.ref(), module(), {module(), options()}) :: {:ok, pid()}
  @doc false
  def start_link(ref, transport, options) do
    {:ok, :proc_lib.spawn_link(__MODULE__, :ranch_init, [{ref, transport, options}])}
  end

  @doc false
  @spec start_link(:ranch.ref(), term(), module(), {module(), options()}) :: {:ok, pid()}
  def start_link(ref, _sock, transport, options) do
    start_link(ref, transport, options)
  end

  @doc false
  @spec ranch_init({:ranch.ref(), module(), {module(), options()}}) :: :ok
  def ranch_init({ref, transport, {callback, opts}}) do
    {:ok, socket} = :ranch.handshake(ref)

    case init([ref, transport, socket, callback, opts]) do
      {:ok, state, timeout} -> :gen_server.enter_loop(__MODULE__, [], state, timeout)
      {:stop, reason} -> :erlang.exit(reason)
      :ignore -> :ok
    end
  end

  @impl GenServer
  @spec init(list()) :: {:ok, State.t(), timeout()} | {:stop, any()} | :ignore
  @doc false
  def init([ref, transport, socket, module, options]) do
    protocol = :proplists.get_value(:protocol, options, :smtp)

    peer_name =
      case transport.peername(socket) do
        {:ok, {ip_address, _port}} -> ip_address
        {:error, _} -> :error
      end

    case peer_name !== :error and
           module.init(
             hostname(options),
             :proplists.get_value(:sessioncount, options, 0),
             peer_name,
             :proplists.get_value(:callbackoptions, options, [])
           ) do
      false ->
        transport.close(socket)
        :ignore

      {:ok, banner, callback_state} ->
        transport.send(socket, [~c"220 ", banner, ~c"\r\n"])
        :ok = transport.setopts(socket, [{:active, :once}, {:packet, :line}, :binary])

        {:ok,
         %State{
           socket: socket,
           transport: transport,
           module: module,
           ranch_ref: ref,
           protocol: protocol,
           options: options,
           callbackstate: callback_state
         }, @timeout}

      {:stop, reason, message} ->
        transport.send(socket, [message, ~c"\r\n"])
        transport.close(socket)
        {:stop, reason}

      :ignore ->
        transport.close(socket)
        :ignore
    end
  end

  @impl GenServer
  @doc false
  @spec handle_call(term(), GenServer.from(), State.t()) ::
          {:reply, term(), State.t()} | {:stop, :normal, :ok, State.t()}
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(request, _from, state) do
    {:reply, {:unknown_call, request}, state}
  end

  @impl GenServer
  @doc false
  @spec handle_cast(term(), State.t()) :: {:noreply, State.t()}
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  @spec handle_info(
          any(),
          State.t()
        ) ::
          {:noreply, State.t()}
          | {:stop, any(), State.t()}
  @doc false
  def handle_info({ref, response}, %State{reader: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    handle_info(response, %{state | reader: nil})
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{reader: %Task{ref: ref}} = state
      ) do
    state = %{state | reader: nil}
    Response.send_reply(state, "451 Error receiving message\r\n")
    state = Response.handle_error(:data_receive_error, reason, state)
    {:stop, {:data_receive_error, reason}, state}
  end

  def handle_info(
        {:receive_data, {:error, :size_exceeded}},
        %State{readmessage: true} = state
      ) do
    Response.send_reply(state, ~c"552 Message too large\r\n")
    state = Response.handle_error(:data_rejected, :size_exceeded, state)
    {:stop, :normal, state}
  end

  def handle_info(
        {:receive_data, {:error, :bare_newline}},
        %State{readmessage: true} = state
      ) do
    Response.send_reply(state, ~c"451 Bare newline detected\r\n")
    state = Response.handle_error(:data_rejected, :bare_newline, state)
    {:stop, :normal, state}
  end

  def handle_info(
        {:receive_data, {:error, other}},
        %State{readmessage: true} = state
      ) do
    state1 = Response.handle_error(:data_receive_error, other, state)
    {:stop, {:error_receiving_data, other}, state1}
  end

  def handle_info(
        {:receive_data, body, rest},
        %State{
          socket: socket,
          transport: transport,
          readmessage: true,
          envelope: env,
          module: module,
          callbackstate: old_callback_state,
          maxsize: max_size
        } = state
      ) do
    case rest do
      <<>> -> :ok
      _ -> Kernel.send(self(), {transport.name(), socket, rest})
    end

    Response.setopts(state, packet: :line)
    data = :re.replace(body, "^\\.", <<>>, [:global, :multiline, return: :binary])
    %Envelope{from: from, to: to} = env

    case max_size === :infinity or byte_size(data) <= max_size do
      true ->
        {response_type, value, callback_state} =
          module.handle_DATA(from, to, data, old_callback_state)

        report_recipient(response_type, value, state)
        Response.setopts(state, active: :once)

        {:noreply,
         %{
           state
           | readmessage: false,
             envelope: %Envelope{},
             callbackstate: callback_state
         }, @timeout}

      false ->
        Response.send_reply(state, ~c"552 Message too large\r\n")
        Response.setopts(state, active: :once)

        {:noreply, %{state | readmessage: false, envelope: %Envelope{}}, @timeout}
    end
  end

  def handle_info(
        {socket_type, socket, packet},
        %State{socket: socket, transport: transport, waitingauth: false} =
          state
      )
      when socket_type === :tcp or socket_type === :ssl do
    case handle_request(parse_request(packet), state) do
      {:ok,
       %State{options: options, readmessage: true, maxsize: max_size} =
           new_state} ->
        Response.setopts(new_state, packet: :raw)

        reader =
          Supervisor.async_nolink(
            DataSupervisor,
            fn -> DataReader.read(transport, socket, max_size, options) end
          )

        {:noreply, %{new_state | reader: reader}, @timeout}

      {:ok, new_state} ->
        Response.setopts(new_state, active: :once)
        {:noreply, new_state, @timeout}

      {:stop, reason, new_state} ->
        {:stop, reason, new_state}
    end
  end

  def handle_info(
        {socket_type, socket, packet},
        %State{socket: socket} = state
      )
      when socket_type === :tcp or socket_type === :ssl do
    request = trim_request(packet)

    {:ok, new_state} = handle_sasl(:base64.decode(request), state)
    Response.setopts(new_state, active: :once)
    {:noreply, new_state, @timeout}
  end

  def handle_info({kind, _socket}, state) when kind == :tcp_closed or kind == :ssl_closed do
    state1 = Response.handle_error(kind, [], state)
    {:stop, :normal, state1}
  end

  def handle_info({kind, _socket, reason}, state) when kind == :ssl_error or kind == :tcp_error do
    state1 = Response.handle_error(kind, reason, state)
    {:stop, :normal, state1}
  end

  def handle_info(
        :timeout,
        %State{socket: socket, transport: transport} = state
      ) do
    Response.send_reply(state, ~c"421 Error: timeout exceeded\r\n")
    transport.close(socket)
    state1 = Response.handle_error(:timeout, [], state)
    {:stop, :normal, state1}
  end

  def handle_info(
        info,
        %State{module: module, callbackstate: old_callback_state} = state
      ) do
    case :erlang.function_exported(module, :handle_info, 2) do
      true ->
        case module.handle_info(info, old_callback_state) do
          {:noreply, new_callback_state} ->
            {:noreply, %{state | callbackstate: new_callback_state}}

          {:noreply, new_callback_state, action} ->
            {:noreply, %{state | callbackstate: new_callback_state}, action}

          {:stop, reason, new_callback_state} ->
            {:stop, reason, %{state | callbackstate: new_callback_state}}
        end

      false ->
        {:noreply, state, @timeout}
    end
  end

  @impl GenServer
  @spec terminate(
          any(),
          State.t()
        ) :: :ok
  @doc false
  def terminate(
        reason,
        %State{
          socket: socket,
          transport: transport,
          module: module,
          callbackstate: callback_state,
          reader: reader
        }
      ) do
    if reader do
      Task.shutdown(reader, :brutal_kill)
    end

    :ok = transport.close(socket)
    module.terminate(reason, callback_state)
  end

  @impl GenServer
  @spec code_change(
          any(),
          State.t(),
          any()
        ) :: {:ok, State.t()}
  @doc false
  def code_change(
        old_vsn,
        %State{module: module, callbackstate: callback_state} = state,
        extra
      ) do
    new_state =
      case (try do
              module.code_change(old_vsn, callback_state, extra)
            catch
              :throw, term -> term
              :exit, reason -> {:EXIT, reason}
              :error, reason -> {:EXIT, {reason, __STACKTRACE__}}
            end) do
        {:ok, new_callback_state} -> new_callback_state
        _ -> callback_state
      end

    {:ok, %{state | callbackstate: new_state}}
  end

  @spec trim_request(binary()) :: binary()
  defp trim_request(packet) do
    packet
    |> Binary.strip(:right, ?\n)
    |> Binary.strip(:right, ?\r)
    |> Binary.strip(:right, ?\s)
    |> Binary.strip(:left, ?\s)
  end

  @spec parse_request(binary()) :: {binary(), binary()}
  defp parse_request(packet) do
    request = trim_request(packet)

    case Binary.strchr(request, 32) do
      0 ->
        {Binary.to_upper(request), <<>>}

      index ->
        verb = Binary.substr(request, 1, index - 1)

        parameters =
          Binary.strip(Binary.substr(request, index + 1), :left, 32)

        {Binary.to_upper(verb), parameters}
    end
  end

  @spec handle_request(
          {binary(), binary()},
          State.t()
        ) ::
          {:ok, State.t()} | {:stop, any(), State.t()}
  defp handle_request({<<>>, _any}, state) do
    Response.send_reply(state, ~c"500 Error: bad syntax\r\n")
    {:ok, state}
  end

  defp handle_request({command, <<>>}, state)
       when command == "HELO" or command == "EHLO" or command == "LHLO" do
    Response.send_reply(state, [~c"501 Syntax: ", command, ~c" hostname\r\n"])
    {:ok, state}
  end

  defp handle_request({"LHLO", _any}, %State{protocol: :smtp} = state) do
    Response.send_reply(state, ~c"500 Error: SMTP should send HELO or EHLO instead of LHLO\r\n")
    {:ok, state}
  end

  defp handle_request({msg, _any}, %State{protocol: :lmtp} = state)
       when msg == "HELO" or msg == "EHLO" do
    Response.send_reply(state, ~c"500 Error: LMTP should replace HELO and EHLO with LHLO\r\n")
    {:ok, state}
  end

  defp handle_request(
         {"HELO", var_hostname},
         %State{
           options: options,
           module: module,
           callbackstate: old_callback_state
         } = state
       ) do
    case module.handle_HELO(var_hostname, old_callback_state) do
      {:ok, max_size, callback_state} when max_size === :infinity or is_integer(max_size) ->
        data = [~c"250 ", hostname(options), ~c"\r\n"]
        Response.send_reply(state, data)

        {:ok,
         %{
           state
           | maxsize: max_size,
             envelope: %Envelope{},
             callbackstate: callback_state
         }}

      {:ok, callback_state} ->
        data = [~c"250 ", hostname(options), ~c"\r\n"]
        Response.send_reply(state, data)

        {:ok, %{state | envelope: %Envelope{}, callbackstate: callback_state}}

      {:error, message, callback_state} ->
        Response.send_reply(state, [message, ~c"\r\n"])
        {:ok, %{state | callbackstate: callback_state}}
    end
  end

  defp handle_request(
         {msg, var_hostname},
         %State{
           options: options,
           module: module,
           callbackstate: old_callback_state
         } = state
       )
       when msg == "EHLO" or msg == "LHLO" do
    case module.handle_EHLO(
           var_hostname,
           [
             {~c"SIZE", :erlang.integer_to_list(10_485_760)},
             {~c"8BITMIME", true},
             {~c"PIPELINING", true},
             {~c"SMTPUTF8", true}
           ],
           old_callback_state
         ) do
      {:ok, [], callback_state} ->
        data = [~c"250 ", hostname(options), ~c"\r\n"]
        Response.send_reply(state, data)
        {:ok, %{state | extensions: [], callbackstate: callback_state}}

      {:ok, extensions, callback_state} ->
        {extensions2, max_size} = greeting_extensions(extensions, state)

        response = format_extensions([hostname(options) | extensions2])
        Response.send_reply(state, response)

        {:ok,
         %{
           state
           | extensions: extensions2,
             maxsize: max_size,
             envelope: %Envelope{},
             callbackstate: callback_state
         }}

      {:error, message, callback_state} ->
        Response.send_reply(state, [message, ~c"\r\n"])
        {:ok, %{state | callbackstate: callback_state}}
    end
  end

  defp handle_request(
         {"AUTH" = c, _args},
         %State{envelope: :undefined, protocol: protocol} = state
       ) do
    Response.send_reply(state, [
      ~c"503 Error: send ",
      lhlo_if_lmtp(protocol, ~c"EHLO"),
      ~c" first\r\n"
    ])

    state1 = Response.handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request({"AUTH", args}, state) do
    {auth_type, parameters} = parse_request(args)
    parameters = if parameters == "", do: false, else: parameters

    case has_extension(state.extensions, ~c"AUTH") do
      false -> Response.reply(state, "502 Error: AUTH not implemented\r\n")
      {true, available} -> authenticate(auth_type, parameters, available, state)
    end
  end

  defp handle_request(
         {"MAIL" = c, _args},
         %State{envelope: :undefined, protocol: protocol} = state
       ) do
    Response.send_reply(state, [
      ~c"503 Error: send ",
      lhlo_if_lmtp(protocol, ~c"HELO/EHLO"),
      ~c" first\r\n"
    ])

    state1 = Response.handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request({"MAIL", args}, state), do: Transaction.mail(args, state)

  defp handle_request(
         {"RCPT" = c, _args},
         %State{envelope: :undefined} = state
       ) do
    Response.send_reply(state, ~c"503 Error: need MAIL command\r\n")
    state1 = Response.handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request({"RCPT", args}, state), do: Transaction.recipient(args, state)

  defp handle_request(
         {"DATA" = c, <<>>},
         %State{envelope: :undefined, protocol: protocol} = state
       ) do
    Response.send_reply(state, [
      ~c"503 Error: send ",
      lhlo_if_lmtp(protocol, ~c"HELO/EHLO"),
      ~c" first\r\n"
    ])

    state1 = Response.handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request(
         {"DATA" = c, <<>>},
         %State{envelope: envelope} = state
       ) do
    case {envelope.from, envelope.to} do
      {:undefined, _} ->
        Response.send_reply(state, ~c"503 Error: need MAIL command\r\n")
        state1 = Response.handle_error(:out_of_order, c, state)
        {:ok, state1}

      {_, []} ->
        Response.send_reply(state, ~c"503 Error: need RCPT command\r\n")
        state1 = Response.handle_error(:out_of_order, c, state)
        {:ok, state1}

      _else ->
        Response.send_reply(state, ~c"354 enter mail, end with line containing only '.'\r\n")

        {:ok, %{state | readmessage: true}}
    end
  end

  defp handle_request(
         {"RSET", _any},
         %State{
           envelope: envelope,
           module: module,
           callbackstate: old_callback_state
         } = state
       ) do
    Response.send_reply(state, ~c"250 Ok\r\n")

    new_envelope =
      case envelope do
        :undefined -> :undefined
        _something -> %Envelope{}
      end

    {:ok,
     %{state | envelope: new_envelope, callbackstate: module.handle_RSET(old_callback_state)}}
  end

  defp handle_request({"NOOP", _any}, state) do
    Response.send_reply(state, ~c"250 Ok\r\n")
    {:ok, state}
  end

  defp handle_request({"QUIT", _any}, state) do
    try_send(state, ~c"221 Bye\r\n")
    {:stop, :normal, state}
  end

  defp handle_request(
         {"VRFY", address},
         %State{
           module: module,
           callbackstate: old_callback_state,
           extensions: extensions
         } = state
       ) do
    case Address.parse_encoded_address(
           address,
           has_extension(extensions, ~c"SMTPUTF8") !== false
         ) do
      {parsed_address, <<>>} ->
        case module.handle_VRFY(parsed_address, old_callback_state) do
          {:ok, reply, callback_state} ->
            Response.send_reply(state, [~c"250 ", reply, ~c"\r\n"])
            {:ok, %{state | callbackstate: callback_state}}

          {:error, message, callback_state} ->
            Response.send_reply(state, [message, ~c"\r\n"])
            {:ok, %{state | callbackstate: callback_state}}
        end

      _other ->
        Response.send_reply(state, ~c"501 Syntax: VRFY username/address\r\n")
        {:ok, state}
    end
  end

  defp handle_request(
         {"STARTTLS", <<>>},
         %State{
           socket: socket,
           module: module,
           tls: false,
           extensions: extensions,
           callbackstate: old_callback_state,
           options: options
         } = state
       ) do
    case has_extension(extensions, ~c"STARTTLS") do
      {true, _} ->
        Response.send_reply(state, ~c"220 OK\r\n")
        tls_opts0 = :proplists.get_value(:tls_options, options, [])

        tls_opts1 =
          case :proplists.get_value(:certfile, options) do
            :undefined -> tls_opts0
            cert_file -> [{:certfile, cert_file} | tls_opts0]
          end

        tls_opts2 =
          case :proplists.get_value(:keyfile, options) do
            :undefined -> tls_opts1
            key_file -> [{:keyfile, key_file} | tls_opts1]
          end

        {:ok, active: false} = :inet.getopts(socket, [:active])

        case :ranch_ssl.handshake(
               socket,
               TLS.server_options([{:packet, :line}, {:mode, :list} | tls_opts2]),
               5000
             ) do
          {:ok, new_socket} ->
            :ranch_ssl.setopts(new_socket, [{:packet, :line}, :binary])

            {:ok,
             %{
               state
               | socket: new_socket,
                 transport: :ranch_ssl,
                 envelope: :undefined,
                 authdata: :undefined,
                 waitingauth: false,
                 readmessage: false,
                 tls: true,
                 callbackstate: module.handle_STARTTLS(old_callback_state)
             }}

          {:error, reason} ->
            Log.info(~c"SSL handshake failed : ~p", [reason], %{
              domain: [:postbeam, :server]
            })

            Response.send_reply(state, ~c"454 TLS negotiation failed\r\n")
            state1 = Response.handle_error(:ssl_handshake_error, reason, state)
            {:ok, state1}
        end

      false ->
        Response.send_reply(state, ~c"500 Command unrecognized\r\n")
        {:ok, state}
    end
  end

  defp handle_request({"STARTTLS" = c, <<>>}, state) do
    Response.send_reply(state, ~c"500 TLS already negotiated\r\n")
    state1 = Response.handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request({"STARTTLS", _args}, state) do
    Response.send_reply(state, ~c"501 Syntax error (no parameters allowed)\r\n")
    {:ok, state}
  end

  defp handle_request(
         {verb, args},
         %State{module: module, callbackstate: old_callback_state} = state
       ) do
    callback_state =
      case module.handle_other(verb, args, old_callback_state) do
        {:noreply, c_state1} ->
          c_state1

        {message, c_state1} ->
          Response.send_reply(state, [message, ~c"\r\n"])
          c_state1
      end

    {:ok, %{state | callbackstate: callback_state}}
  end

  @spec greeting_extensions(list(), State.t()) :: {list(), non_neg_integer() | :infinity}
  defp greeting_extensions(extensions, state) do
    extensions_upper = :lists.map(fn {x, y} -> {:string.to_upper(x), y} end, extensions)

    {extensions1, max_size} =
      case :lists.keyfind(~c"SIZE", 1, extensions_upper) do
        {~c"SIZE", ~c"0"} ->
          {:lists.keydelete(~c"SIZE", 1, extensions_upper), :infinity}

        {~c"SIZE", max_size_string} when is_list(max_size_string) ->
          {extensions_upper, :erlang.list_to_integer(max_size_string)}

        false ->
          {extensions_upper, state.maxsize}
      end

    extensions2 =
      case state.tls do
        true -> :lists.delete({~c"STARTTLS", true}, extensions1)
        false -> extensions1
      end

    {extensions2, max_size}
  end

  @spec authenticate(binary(), binary() | false, charlist(), State.t()) :: {:ok, State.t()}
  defp authenticate(type, parameters, available, state) do
    if :erlang.binary_to_list(type) in :string.tokens(available, ~c" ") do
      begin_auth(type, parameters, state)
    else
      Response.reply(state, "504 Unrecognized authentication type\r\n")
    end
  end

  @spec begin_auth(binary(), binary() | false, State.t()) :: {:ok, State.t()}
  defp begin_auth("LOGIN", _parameters, state),
    do: auth_challenge(:login, "334 VXNlcm5hbWU6\r\n", state)

  defp begin_auth("PLAIN", false, state), do: auth_challenge(:plain, "334\r\n", state)

  defp begin_auth("PLAIN", parameters, state) do
    case Binary.split(:base64.decode(parameters), <<0>>) do
      [_identity, username, password] -> try_auth(:plain, username, password, state)
      [username, password] -> try_auth(:plain, username, password, state)
      _ -> {:ok, state}
    end
  end

  defp begin_auth("CRAM-MD5", _parameters, state) do
    :application.ensure_started(:crypto)
    challenge = Util.get_cram_string(hostname(state.options))
    {:ok, updated} = auth_challenge(:"cram-md5", ["334 ", challenge, "\r\n"], state)
    {:ok, %{updated | authdata: :base64.decode(challenge)}}
  end

  @spec auth_challenge(:login | :plain | :"cram-md5", iodata(), State.t()) :: {:ok, State.t()}
  defp auth_challenge(method, reply, state) do
    Response.send_reply(state, reply)
    {:ok, %{state | waitingauth: method, envelope: %{state.envelope | auth: {"", ""}}}}
  end

  @spec handle_sasl(binary(), State.t()) :: {:ok, State.t()}
  defp handle_sasl(
         user_digest,
         %State{
           waitingauth: :"cram-md5",
           envelope: %Envelope{auth: {<<>>, <<>>}},
           authdata: auth_data
         } = state
       ) do
    case Binary.split(user_digest, " ") do
      [username, digest] ->
        try_auth(:"cram-md5", username, {digest, auth_data}, %{state | authdata: :undefined})

      _ ->
        {:ok, %{state | waitingauth: false, authdata: :undefined}}
    end
  end

  defp handle_sasl(
         user_pass,
         %State{
           waitingauth: :plain,
           envelope: %Envelope{auth: {<<>>, <<>>}}
         } = state
       ) do
    case Binary.split(user_pass, <<0>>) do
      [_identity, username, password] -> try_auth(:plain, username, password, state)
      [username, password] -> try_auth(:plain, username, password, state)
      _ -> {:ok, %{state | waitingauth: false}}
    end
  end

  defp handle_sasl(
         username,
         %State{
           waitingauth: :login,
           envelope: %Envelope{auth: {<<>>, <<>>}}
         } = state
       ) do
    envelope = state.envelope
    Response.send_reply(state, ~c"334 UGFzc3dvcmQ6\r\n")
    new_state = %{state | envelope: %{envelope | auth: {username, <<>>}}}
    {:ok, new_state}
  end

  defp handle_sasl(
         password,
         %State{
           waitingauth: :login,
           envelope: %Envelope{auth: {username, <<>>}}
         } = state
       ) do
    try_auth(:login, username, password, state)
  end

  @spec has_extension(list({charlist(), charlist()}), charlist()) :: {true, charlist()} | false
  defp has_extension(extensions, ext) do
    case :proplists.get_value(ext, extensions) do
      :undefined -> false
      value -> {true, value}
    end
  end

  @spec try_auth(
          :login | :plain | :"cram-md5",
          binary(),
          binary() | {binary(), binary()},
          State.t()
        ) :: {:ok, State.t()}
  defp try_auth(
         auth_type,
         username,
         credential,
         %State{
           module: module,
           envelope: envelope,
           callbackstate: old_callback_state
         } = state
       ) do
    new_state = %{state | waitingauth: false, envelope: %{envelope | auth: {<<>>, <<>>}}}

    case :erlang.function_exported(module, :handle_AUTH, 4) do
      true ->
        case module.handle_AUTH(auth_type, username, credential, old_callback_state) do
          {:ok, callback_state} ->
            Response.send_reply(state, ~c"235 Authentication successful.\r\n")

            {:ok,
             %{
               new_state
               | callbackstate: callback_state,
                 envelope: %{envelope | auth: {username, credential}}
             }}

          _other ->
            Response.send_reply(state, ~c"535 Authentication failed.\r\n")
            {:ok, new_state}
        end

      false ->
        Log.warning(
          ~c"Please define handle_AUTH/4 in your server module or remove AUTH from your module extensions",
          %{domain: [:postbeam, :server]}
        )

        Response.send_reply(state, ~c"535 authentication failed (#5.7.1)\r\n")
        {:ok, new_state}
    end
  end

  @spec try_send(State.t(), iodata()) :: :ok
  defp try_send(%State{transport: transport, socket: sock}, data) do
    transport.send(sock, data)
    :ok
  end

  @spec hostname(options()) :: :inet.hostname()
  defp hostname(opts) do
    :proplists.get_value(:hostname, opts, Util.guess_FQDN())
  end

  @spec lhlo_if_lmtp(:smtp | :lmtp, charlist()) :: charlist()
  defp lhlo_if_lmtp(protocol, fallback) do
    case protocol == :lmtp do
      true -> ~c"LHLO"
      false -> fallback
    end
  end

  @spec report_recipient(
          :ok | :error | :multiple,
          charlist() | list({:ok | :error, charlist()}),
          State.t()
        ) :: any()
  defp report_recipient(:ok, reference, state) do
    Response.send_reply(state, [~c"250 ", reference, ~c"\r\n"])
  end

  defp report_recipient(:error, message, state) do
    Response.send_reply(state, [message, ~c"\r\n"])
  end

  defp report_recipient(:multiple, _any, %State{protocol: :smtp} = state) do
    msg = ~c"SMTP should report a single delivery status for all the recipients"
    throw({:stop, {:handle_DATA_error, msg}, state})
  end

  defp report_recipient(:multiple, [], _state) do
    :ok
  end

  defp report_recipient(:multiple, [{response_type, value} | rest], state) do
    report_recipient(response_type, value, state)
    report_recipient(:multiple, rest, state)
  end

  @spec format_extensions(nonempty_list(iodata() | {iodata(), iodata() | true})) :: iodata()
  defp format_extensions([line]), do: ["250 ", extension_line(line), "\r\n"]

  defp format_extensions([line | more]) do
    ["250-", extension_line(line), "\r\n" | format_extensions(more)]
  end

  @spec extension_line(iodata() | {iodata(), iodata() | true}) :: iodata()
  defp extension_line({name, true}), do: name
  defp extension_line({name, value}), do: [name, " ", value]
  defp extension_line(line), do: line
end
