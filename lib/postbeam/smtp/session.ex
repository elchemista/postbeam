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

defmodule Postbeam.SMTP.Session do
  @moduledoc "SMTP/LMTP session GenServer, started and supervised by Ranch.\n\nUse `Postbeam.SMTP.Server` to create listeners and `Postbeam.SMTP.Handler` for callbacks."
  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  use GenServer
  @behaviour :ranch_protocol
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
  @spec start_link(:ranch.ref(), module(), {module(), options()}) :: {:ok, pid()}
  def start_link(ref, transport, options) do
    {:ok, :proc_lib.spawn_link(Postbeam.SMTP.Session, :ranch_init, [{ref, transport, options}])}
  end

  def start_link(ref, _sock, transport, options) do
    start_link(ref, transport, options)
  end

  def ranch_init({ref, transport, {callback, opts}}) do
    {:ok, socket} = :ranch.handshake(ref)

    case init([ref, transport, socket, callback, opts]) do
      {:ok, state, timeout} -> :gen_server.enter_loop(Postbeam.SMTP.Session, [], state, timeout)
      {:stop, reason} -> :erlang.exit(reason)
      :ignore -> :ok
    end
  end

  @spec init(list()) :: {:ok, Postbeam.SMTP.Session.State.t(), 180_000} | {:stop, any()} | :ignore
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
         %Postbeam.SMTP.Session.State{
           socket: socket,
           transport: transport,
           module: module,
           ranch_ref: ref,
           protocol: protocol,
           options: options,
           callbackstate: callback_state
         }, 180_000}

      {:stop, reason, message} ->
        transport.send(socket, [message, ~c"\r\n"])
        transport.close(socket)
        {:stop, reason}

      :ignore ->
        transport.close(socket)
        :ignore
    end
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(request, _from, state) do
    {:reply, {:unknown_call, request}, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @spec handle_info(
          any(),
          Postbeam.SMTP.Session.State.t()
        ) ::
          {:noreply, Postbeam.SMTP.Session.State.t()}
          | {:stop, any(), Postbeam.SMTP.Session.State.t()}
  def handle_info({ref, response}, %Postbeam.SMTP.Session.State{reader: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    handle_info(response, %{state | reader: nil})
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %Postbeam.SMTP.Session.State{reader: %Task{ref: ref}} = state
      ) do
    state = %{state | reader: nil}
    send_reply(state, "451 Error receiving message\r\n")
    state = handle_error(:data_receive_error, reason, state)
    {:stop, {:data_receive_error, reason}, state}
  end

  def handle_info(
        {:receive_data, {:error, :size_exceeded}},
        %Postbeam.SMTP.Session.State{readmessage: true} = state
      ) do
    send_reply(state, ~c"552 Message too large\r\n")
    state = handle_error(:data_rejected, :size_exceeded, state)
    {:stop, :normal, state}
  end

  def handle_info(
        {:receive_data, {:error, :bare_newline}},
        %Postbeam.SMTP.Session.State{readmessage: true} = state
      ) do
    send_reply(state, ~c"451 Bare newline detected\r\n")
    state = handle_error(:data_rejected, :bare_newline, state)
    {:stop, :normal, state}
  end

  def handle_info(
        {:receive_data, {:error, other}},
        %Postbeam.SMTP.Session.State{readmessage: true} = state
      ) do
    state1 = handle_error(:data_receive_error, other, state)
    {:stop, {:error_receiving_data, other}, state1}
  end

  def handle_info(
        {:receive_data, body, rest},
        %Postbeam.SMTP.Session.State{
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

    setopts(state, packet: :line)
    data = :re.replace(body, "^\\.", <<>>, [:global, :multiline, return: :binary])
    %Postbeam.SMTP.Session.Envelope{from: from, to: to} = env

    case max_size === :infinity or byte_size(data) <= max_size do
      true ->
        {response_type, value, callback_state} =
          module.handle_DATA(from, to, data, old_callback_state)

        report_recipient(response_type, value, state)
        setopts(state, active: :once)

        {:noreply,
         %{
           state
           | readmessage: false,
             envelope: %Postbeam.SMTP.Session.Envelope{},
             callbackstate: callback_state
         }, 180_000}

      false ->
        send_reply(state, ~c"552 Message too large\r\n")
        setopts(state, active: :once)

        {:noreply, %{state | readmessage: false, envelope: %Postbeam.SMTP.Session.Envelope{}},
         180_000}
    end
  end

  def handle_info(
        {socket_type, socket, packet},
        %Postbeam.SMTP.Session.State{socket: socket, transport: transport, waitingauth: false} =
          state
      )
      when socket_type === :tcp or socket_type === :ssl do
    case handle_request(parse_request(packet), state) do
      {:ok,
       %Postbeam.SMTP.Session.State{options: options, readmessage: true, maxsize: max_size} =
           new_state} ->
        setopts(new_state, packet: :raw)

        reader =
          Task.Supervisor.async_nolink(
            Postbeam.SMTP.DataSupervisor,
            fn -> Postbeam.SMTP.Session.DataReader.read(transport, socket, max_size, options) end
          )

        {:noreply, %{new_state | reader: reader}, 180_000}

      {:ok, new_state} ->
        setopts(new_state, active: :once)
        {:noreply, new_state, 180_000}

      {:stop, reason, new_state} ->
        {:stop, reason, new_state}
    end
  end

  def handle_info(
        {socket_type, socket, packet},
        %Postbeam.SMTP.Session.State{socket: socket} = state
      )
      when socket_type === :tcp or socket_type === :ssl do
    request =
      Postbeam.SMTP.Binary.strip(
        Postbeam.SMTP.Binary.strip(
          Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.strip(packet, :right, 10), :right, 13),
          :right,
          32
        ),
        :left,
        32
      )

    Postbeam.SMTP.Log.debug(~c"Got SASL request ~p", [request], %{domain: [:postbeam, :server]})
    {:ok, new_state} = handle_sasl(:base64.decode(request), state)
    setopts(new_state, active: :once)
    {:noreply, new_state, 180_000}
  end

  def handle_info({kind, _socket}, state) when kind == :tcp_closed or kind == :ssl_closed do
    state1 = handle_error(kind, [], state)
    {:stop, :normal, state1}
  end

  def handle_info({kind, _socket, reason}, state) when kind == :ssl_error or kind == :tcp_error do
    state1 = handle_error(kind, reason, state)
    {:stop, :normal, state1}
  end

  def handle_info(
        :timeout,
        %Postbeam.SMTP.Session.State{socket: socket, transport: transport} = state
      ) do
    send_reply(state, ~c"421 Error: timeout exceeded\r\n")
    transport.close(socket)
    state1 = handle_error(:timeout, [], state)
    {:stop, :normal, state1}
  end

  def handle_info(
        info,
        %Postbeam.SMTP.Session.State{module: module, callbackstate: old_callback_state} = state
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
        Postbeam.SMTP.Log.debug(~c"Ignored message ~p", [info], %{domain: [:postbeam, :server]})
        {:noreply, state, 180_000}
    end
  end

  @spec terminate(
          any(),
          Postbeam.SMTP.Session.State.t()
        ) :: :ok
  def terminate(
        reason,
        %Postbeam.SMTP.Session.State{
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

  @spec code_change(
          any(),
          Postbeam.SMTP.Session.State.t(),
          any()
        ) :: {:ok, Postbeam.SMTP.Session.State.t()}
  def code_change(
        old_vsn,
        %Postbeam.SMTP.Session.State{module: module, callbackstate: callback_state} = state,
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

  @spec parse_request(binary()) :: {binary(), binary()}
  defp parse_request(packet) do
    request =
      Postbeam.SMTP.Binary.strip(
        Postbeam.SMTP.Binary.strip(
          Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.strip(packet, :right, 10), :right, 13),
          :right,
          32
        ),
        :left,
        32
      )

    case Postbeam.SMTP.Binary.strchr(request, 32) do
      0 ->
        Postbeam.SMTP.Log.debug(~c"got a ~s request", [request], %{domain: [:postbeam, :server]})
        {Postbeam.SMTP.Binary.to_upper(request), <<>>}

      index ->
        verb = Postbeam.SMTP.Binary.substr(request, 1, index - 1)

        parameters =
          Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.substr(request, index + 1), :left, 32)

        Postbeam.SMTP.Log.debug(~c"got a ~s request with parameters ~s", [verb, parameters], %{
          domain: [:postbeam, :server]
        })

        {Postbeam.SMTP.Binary.to_upper(verb), parameters}
    end
  end

  @spec handle_request(
          {binary(), binary()},
          Postbeam.SMTP.Session.State.t()
        ) ::
          {:ok, Postbeam.SMTP.Session.State.t()} | {:stop, any(), Postbeam.SMTP.Session.State.t()}
  defp handle_request({<<>>, _any}, state) do
    send_reply(state, ~c"500 Error: bad syntax\r\n")
    {:ok, state}
  end

  defp handle_request({command, <<>>}, state)
       when command == "HELO" or command == "EHLO" or command == "LHLO" do
    send_reply(state, [~c"501 Syntax: ", command, ~c" hostname\r\n"])
    {:ok, state}
  end

  defp handle_request({"LHLO", _any}, %Postbeam.SMTP.Session.State{protocol: :smtp} = state) do
    send_reply(state, ~c"500 Error: SMTP should send HELO or EHLO instead of LHLO\r\n")
    {:ok, state}
  end

  defp handle_request({msg, _any}, %Postbeam.SMTP.Session.State{protocol: :lmtp} = state)
       when msg == "HELO" or msg == "EHLO" do
    send_reply(state, ~c"500 Error: LMTP should replace HELO and EHLO with LHLO\r\n")
    {:ok, state}
  end

  defp handle_request(
         {"HELO", var_hostname},
         %Postbeam.SMTP.Session.State{
           options: options,
           module: module,
           callbackstate: old_callback_state
         } = state
       ) do
    case module.handle_HELO(var_hostname, old_callback_state) do
      {:ok, max_size, callback_state} when max_size === :infinity or is_integer(max_size) ->
        data = [~c"250 ", hostname(options), ~c"\r\n"]
        send_reply(state, data)

        {:ok,
         %{
           state
           | maxsize: max_size,
             envelope: %Postbeam.SMTP.Session.Envelope{},
             callbackstate: callback_state
         }}

      {:ok, callback_state} ->
        data = [~c"250 ", hostname(options), ~c"\r\n"]
        send_reply(state, data)

        {:ok,
         %{state | envelope: %Postbeam.SMTP.Session.Envelope{}, callbackstate: callback_state}}

      {:error, message, callback_state} ->
        send_reply(state, [message, ~c"\r\n"])
        {:ok, %{state | callbackstate: callback_state}}
    end
  end

  defp handle_request(
         {msg, var_hostname},
         %Postbeam.SMTP.Session.State{
           options: options,
           module: module,
           callbackstate: old_callback_state,
           tls: tls
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
        send_reply(state, data)
        {:ok, %{state | extensions: [], callbackstate: callback_state}}

      {:ok, extensions, callback_state} ->
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
          case tls do
            true -> :lists.delete({~c"STARTTLS", true}, extensions1)
            false -> extensions1
          end

        response = format_extensions([hostname(options) | extensions2])
        send_reply(state, response)

        {:ok,
         %{
           state
           | extensions: extensions2,
             maxsize: max_size,
             envelope: %Postbeam.SMTP.Session.Envelope{},
             callbackstate: callback_state
         }}

      {:error, message, callback_state} ->
        send_reply(state, [message, ~c"\r\n"])
        {:ok, %{state | callbackstate: callback_state}}
    end
  end

  defp handle_request(
         {"AUTH" = c, _args},
         %Postbeam.SMTP.Session.State{envelope: :undefined, protocol: protocol} = state
       ) do
    send_reply(state, [~c"503 Error: send ", lhlo_if_lmtp(protocol, ~c"EHLO"), ~c" first\r\n"])
    state1 = handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request(
         {"AUTH", args},
         %Postbeam.SMTP.Session.State{
           extensions: extensions,
           envelope: envelope,
           options: options
         } =
           state
       ) do
    {auth_type, parameters} =
      case Postbeam.SMTP.Binary.strchr(args, 32) do
        0 ->
          {args, false}

        index ->
          {Postbeam.SMTP.Binary.substr(args, 1, index - 1),
           Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.substr(args, index + 1), :left, 32)}
      end

    case has_extension(extensions, ~c"AUTH") do
      false ->
        send_reply(state, ~c"502 Error: AUTH not implemented\r\n")
        {:ok, state}

      {true, available_types} ->
        case :lists.member(
               :string.to_upper(:erlang.binary_to_list(auth_type)),
               :string.tokens(available_types, ~c" ")
             ) do
          false ->
            send_reply(state, ~c"504 Unrecognized authentication type\r\n")
            {:ok, state}

          true ->
            case Postbeam.SMTP.Binary.to_upper(auth_type) do
              "LOGIN" ->
                send_reply(state, ~c"334 VXNlcm5hbWU6\r\n")
                {:ok, %{state | waitingauth: :login, envelope: %{envelope | auth: {<<>>, <<>>}}}}

              "PLAIN" when parameters !== false ->
                case Postbeam.SMTP.Binary.split(:base64.decode(parameters), <<0>>) do
                  [_identity, username, password] -> try_auth(:plain, username, password, state)
                  [username, password] -> try_auth(:plain, username, password, state)
                  _ -> {:ok, state}
                end

              "PLAIN" ->
                send_reply(state, ~c"334\r\n")
                {:ok, %{state | waitingauth: :plain, envelope: %{envelope | auth: {<<>>, <<>>}}}}

              "CRAM-MD5" ->
                :application.ensure_started(:crypto)
                string = Postbeam.SMTP.Util.get_cram_string(hostname(options))
                send_reply(state, [~c"334 ", string, ~c"\r\n"])

                {:ok,
                 %{
                   state
                   | waitingauth: :"cram-md5",
                     authdata: :base64.decode(string),
                     envelope: %{envelope | auth: {<<>>, <<>>}}
                 }}
            end
        end
    end
  end

  defp handle_request(
         {"MAIL" = c, _args},
         %Postbeam.SMTP.Session.State{envelope: :undefined, protocol: protocol} = state
       ) do
    send_reply(state, [
      ~c"503 Error: send ",
      lhlo_if_lmtp(protocol, ~c"HELO/EHLO"),
      ~c" first\r\n"
    ])

    state1 = handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request(
         {"MAIL", args},
         %Postbeam.SMTP.Session.State{
           module: module,
           envelope: envelope0,
           callbackstate: old_callback_state,
           extensions: extensions,
           maxsize: max_size
         } = state
       ) do
    case envelope0.from do
      :undefined ->
        case Postbeam.SMTP.Binary.strpos(Postbeam.SMTP.Binary.to_upper(args), "FROM:") do
          1 ->
            address = Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.substr(args, 6), :left, 32)

            case parse_encoded_address(address, has_extension(extensions, ~c"SMTPUTF8") !== false) do
              :error ->
                send_reply(state, ~c"501 Bad sender address syntax\r\n")
                {:ok, state}

              {parsed_address, <<>>} ->
                Postbeam.SMTP.Log.debug(
                  ~c"From address ~s (parsed as ~s)",
                  [address, parsed_address],
                  %{domain: [:postbeam, :server]}
                )

                case module.handle_MAIL(parsed_address, old_callback_state) do
                  {:ok, callback_state} ->
                    send_reply(state, ~c"250 sender Ok\r\n")

                    {:ok,
                     %{
                       state
                       | envelope: %{envelope0 | from: parsed_address},
                         callbackstate: callback_state
                     }}

                  {:error, message, callback_state} ->
                    send_reply(state, [message, ~c"\r\n"])
                    {:ok, %{state | callbackstate: callback_state}}
                end

              {parsed_address, extra_info} ->
                Postbeam.SMTP.Log.debug(
                  ~c"From address ~s (parsed as ~s) with extra info ~s",
                  [address, parsed_address, extra_info],
                  %{domain: [:postbeam, :server]}
                )

                options =
                  for x <- Postbeam.SMTP.Binary.split(extra_info, " "),
                      into: [],
                      do: Postbeam.SMTP.Binary.to_upper(x)

                Postbeam.SMTP.Log.debug(~c"options are ~p", [options], %{
                  domain: [:postbeam, :server]
                })

                f = fn
                  _, {:error, message} ->
                    {:error, message}

                  <<"SIZE=", size::binary>>,
                  %Postbeam.SMTP.Session.State{envelope: envelope} = inner_state
                  when max_size === :infinity ->
                    %{
                      inner_state
                      | envelope: %{envelope | expectedsize: :erlang.binary_to_integer(size)}
                    }

                  <<"SIZE=", size::binary>>,
                  %Postbeam.SMTP.Session.State{envelope: envelope} = inner_state ->
                    case :erlang.binary_to_integer(size) > max_size do
                      true ->
                        {:error,
                         [
                           ~c"552 Estimated message length ",
                           size,
                           ~c" exceeds limit of ",
                           :erlang.integer_to_binary(max_size),
                           ~c"\r\n"
                         ]}

                      false ->
                        %{
                          inner_state
                          | envelope: %{envelope | expectedsize: :erlang.binary_to_integer(size)}
                        }
                    end

                  <<"BODY=", body_type::binary>>,
                  %Postbeam.SMTP.Session.State{
                    envelope: %Postbeam.SMTP.Session.Envelope{flags: flags} = envelope
                  } = inner_state ->
                    case has_extension(extensions, ~c"8BITMIME") do
                      {true, _} ->
                        flag =
                          :maps.get(body_type, %{"8BITMIME" => :"8bitmime", "7BIT" => :"7bit"})

                        %{inner_state | envelope: %{envelope | flags: [flag | flags]}}

                      false ->
                        {:error, ~c"555 Unsupported option BODY\r\n"}
                    end

                  "SMTPUTF8",
                  %Postbeam.SMTP.Session.State{
                    envelope: %Postbeam.SMTP.Session.Envelope{flags: flags} = envelope
                  } = inner_state ->
                    case has_extension(extensions, ~c"SMTPUTF8") do
                      {true, _} ->
                        %{inner_state | envelope: %{envelope | flags: [:smtputf8 | flags]}}

                      false ->
                        {:error, ~c"555 Unsupported option SMTPUTF8\r\n"}
                    end

                  x, inner_state ->
                    case module.handle_MAIL_extension(x, old_callback_state) do
                      {:ok, callback_state} -> %{inner_state | callbackstate: callback_state}
                      :error -> {:error, [~c"555 Unsupported option: ", extra_info, ~c"\r\n"]}
                    end
                end

                case :lists.foldl(f, state, options) do
                  {:error, message} ->
                    Postbeam.SMTP.Log.debug(~c"error: ~s", [message], %{
                      domain: [:postbeam, :server]
                    })

                    send_reply(state, message)
                    {:ok, state}

                  %Postbeam.SMTP.Session.State{envelope: envelope} = new_state ->
                    Postbeam.SMTP.Log.debug(~c"OK", %{domain: [:postbeam, :server]})

                    case module.handle_MAIL(
                           parsed_address,
                           state.callbackstate
                         ) do
                      {:ok, callback_state} ->
                        send_reply(state, ~c"250 sender Ok\r\n")

                        {:ok,
                         %{
                           state
                           | envelope: %{envelope | from: parsed_address},
                             callbackstate: callback_state
                         }}

                      {:error, message, callback_state} ->
                        send_reply(state, [message, ~c"\r\n"])
                        {:ok, %{new_state | callbackstate: callback_state}}
                    end
                end
            end

          _else ->
            send_reply(state, ~c"501 Syntax: MAIL FROM:<address>\r\n")
            {:ok, state}
        end

      _other ->
        send_reply(state, ~c"503 Error: Nested MAIL command\r\n")
        {:ok, state}
    end
  end

  defp handle_request(
         {"RCPT" = c, _args},
         %Postbeam.SMTP.Session.State{envelope: :undefined} = state
       ) do
    send_reply(state, ~c"503 Error: need MAIL command\r\n")
    state1 = handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request(
         {"RCPT", args},
         %Postbeam.SMTP.Session.State{
           envelope: envelope,
           module: module,
           callbackstate: old_callback_state,
           extensions: extensions
         } = state
       ) do
    case Postbeam.SMTP.Binary.strpos(Postbeam.SMTP.Binary.to_upper(args), "TO:") do
      1 ->
        address = Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.substr(args, 4), :left, 32)

        case parse_encoded_address(address, has_extension(extensions, ~c"SMTPUTF8") !== false) do
          :error ->
            send_reply(state, ~c"501 Bad recipient address syntax\r\n")
            {:ok, state}

          {<<>>, _} ->
            send_reply(state, ~c"501 Bad recipient address syntax\r\n")
            {:ok, state}

          {parsed_address, <<>>} ->
            Postbeam.SMTP.Log.debug(
              ~c"To address ~s (parsed as ~s)",
              [address, parsed_address],
              %{
                domain: [:postbeam, :server]
              }
            )

            case module.handle_RCPT(parsed_address, old_callback_state) do
              {:ok, callback_state} ->
                send_reply(state, ~c"250 recipient Ok\r\n")

                {:ok,
                 %{
                   state
                   | envelope: %{envelope | to: envelope.to ++ [parsed_address]},
                     callbackstate: callback_state
                 }}

              {:error, message, callback_state} ->
                send_reply(state, [message, ~c"\r\n"])
                {:ok, %{state | callbackstate: callback_state}}
            end

          {parsed_address, extra_info} ->
            Postbeam.SMTP.Log.debug(
              ~c"To address ~s (parsed as ~s) with extra info ~s",
              [address, parsed_address, extra_info],
              %{domain: [:postbeam, :server]}
            )

            send_reply(state, [~c"555 Unsupported option: ", extra_info, ~c"\r\n"])
            {:ok, state}
        end

      _else ->
        send_reply(state, ~c"501 Syntax: RCPT TO:<address>\r\n")
        {:ok, state}
    end
  end

  defp handle_request(
         {"DATA" = c, <<>>},
         %Postbeam.SMTP.Session.State{envelope: :undefined, protocol: protocol} = state
       ) do
    send_reply(state, [
      ~c"503 Error: send ",
      lhlo_if_lmtp(protocol, ~c"HELO/EHLO"),
      ~c" first\r\n"
    ])

    state1 = handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request(
         {"DATA" = c, <<>>},
         %Postbeam.SMTP.Session.State{envelope: envelope} = state
       ) do
    case {envelope.from, envelope.to} do
      {:undefined, _} ->
        send_reply(state, ~c"503 Error: need MAIL command\r\n")
        state1 = handle_error(:out_of_order, c, state)
        {:ok, state1}

      {_, []} ->
        send_reply(state, ~c"503 Error: need RCPT command\r\n")
        state1 = handle_error(:out_of_order, c, state)
        {:ok, state1}

      _else ->
        send_reply(state, ~c"354 enter mail, end with line containing only '.'\r\n")

        Postbeam.SMTP.Log.debug(~c"switching to data read mode", [], %{
          domain: [:postbeam, :server]
        })

        {:ok, %{state | readmessage: true}}
    end
  end

  defp handle_request(
         {"RSET", _any},
         %Postbeam.SMTP.Session.State{
           envelope: envelope,
           module: module,
           callbackstate: old_callback_state
         } = state
       ) do
    send_reply(state, ~c"250 Ok\r\n")

    new_envelope =
      case envelope do
        :undefined -> :undefined
        _something -> %Postbeam.SMTP.Session.Envelope{}
      end

    {:ok,
     %{state | envelope: new_envelope, callbackstate: module.handle_RSET(old_callback_state)}}
  end

  defp handle_request({"NOOP", _any}, state) do
    send_reply(state, ~c"250 Ok\r\n")
    {:ok, state}
  end

  defp handle_request({"QUIT", _any}, state) do
    try_send(state, ~c"221 Bye\r\n")
    {:stop, :normal, state}
  end

  defp handle_request(
         {"VRFY", address},
         %Postbeam.SMTP.Session.State{
           module: module,
           callbackstate: old_callback_state,
           extensions: extensions
         } = state
       ) do
    case parse_encoded_address(address, has_extension(extensions, ~c"SMTPUTF8") !== false) do
      {parsed_address, <<>>} ->
        case module.handle_VRFY(parsed_address, old_callback_state) do
          {:ok, reply, callback_state} ->
            send_reply(state, [~c"250 ", reply, ~c"\r\n"])
            {:ok, %{state | callbackstate: callback_state}}

          {:error, message, callback_state} ->
            send_reply(state, [message, ~c"\r\n"])
            {:ok, %{state | callbackstate: callback_state}}
        end

      _other ->
        send_reply(state, ~c"501 Syntax: VRFY username/address\r\n")
        {:ok, state}
    end
  end

  defp handle_request(
         {"STARTTLS", <<>>},
         %Postbeam.SMTP.Session.State{
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
        send_reply(state, ~c"220 OK\r\n")
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
               Postbeam.SMTP.TLS.server_options([{:packet, :line}, {:mode, :list} | tls_opts2]),
               5000
             ) do
          {:ok, new_socket} ->
            Postbeam.SMTP.Log.debug(~c"SSL negotiation successful", %{
              domain: [:postbeam, :server]
            })

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
            Postbeam.SMTP.Log.info(~c"SSL handshake failed : ~p", [reason], %{
              domain: [:postbeam, :server]
            })

            send_reply(state, ~c"454 TLS negotiation failed\r\n")
            state1 = handle_error(:ssl_handshake_error, reason, state)
            {:ok, state1}
        end

      false ->
        send_reply(state, ~c"500 Command unrecognized\r\n")
        {:ok, state}
    end
  end

  defp handle_request({"STARTTLS" = c, <<>>}, state) do
    send_reply(state, ~c"500 TLS already negotiated\r\n")
    state1 = handle_error(:out_of_order, c, state)
    {:ok, state1}
  end

  defp handle_request({"STARTTLS", _args}, state) do
    send_reply(state, ~c"501 Syntax error (no parameters allowed)\r\n")
    {:ok, state}
  end

  defp handle_request(
         {verb, args},
         %Postbeam.SMTP.Session.State{module: module, callbackstate: old_callback_state} = state
       ) do
    callback_state =
      case module.handle_other(verb, args, old_callback_state) do
        {:noreply, c_state1} ->
          c_state1

        {message, c_state1} ->
          send_reply(state, [message, ~c"\r\n"])
          c_state1
      end

    {:ok, %{state | callbackstate: callback_state}}
  end

  defp handle_sasl(
         user_digest,
         %Postbeam.SMTP.Session.State{
           waitingauth: :"cram-md5",
           envelope: %Postbeam.SMTP.Session.Envelope{auth: {<<>>, <<>>}},
           authdata: auth_data
         } = state
       ) do
    case Postbeam.SMTP.Binary.split(user_digest, " ") do
      [username, digest] ->
        try_auth(:"cram-md5", username, {digest, auth_data}, %{state | authdata: :undefined})

      _ ->
        {:ok, %{state | waitingauth: false, authdata: :undefined}}
    end
  end

  defp handle_sasl(
         user_pass,
         %Postbeam.SMTP.Session.State{
           waitingauth: :plain,
           envelope: %Postbeam.SMTP.Session.Envelope{auth: {<<>>, <<>>}}
         } = state
       ) do
    case Postbeam.SMTP.Binary.split(user_pass, <<0>>) do
      [_identity, username, password] -> try_auth(:plain, username, password, state)
      [username, password] -> try_auth(:plain, username, password, state)
      _ -> {:ok, %{state | waitingauth: false}}
    end
  end

  defp handle_sasl(
         username,
         %Postbeam.SMTP.Session.State{
           waitingauth: :login,
           envelope: %Postbeam.SMTP.Session.Envelope{auth: {<<>>, <<>>}}
         } = state
       ) do
    envelope = state.envelope
    send_reply(state, ~c"334 UGFzc3dvcmQ6\r\n")
    new_state = %{state | envelope: %{envelope | auth: {username, <<>>}}}
    {:ok, new_state}
  end

  defp handle_sasl(
         password,
         %Postbeam.SMTP.Session.State{
           waitingauth: :login,
           envelope: %Postbeam.SMTP.Session.Envelope{auth: {username, <<>>}}
         } = state
       ) do
    try_auth(:login, username, password, state)
  end

  @spec handle_error(
          error_class(),
          any(),
          Postbeam.SMTP.Session.State.t()
        ) :: Postbeam.SMTP.Session.State.t()
  defp handle_error(
         kind,
         details,
         %Postbeam.SMTP.Session.State{module: module, callbackstate: old_callback_state} = state
       ) do
    case :erlang.function_exported(module, :handle_error, 3) do
      true ->
        case module.handle_error(kind, details, old_callback_state) do
          {:ok, callback_state} ->
            %{state | callbackstate: callback_state}

          {:stop, reason, callback_state} ->
            throw({:stop, reason, %{state | callbackstate: callback_state}})
        end

      false ->
        state
    end
  end

  @spec parse_encoded_address(binary(), boolean()) :: {binary(), binary()} | :error
  defp parse_encoded_address(<<>>, _) do
    :error
  end

  defp parse_encoded_address(<<"<@", address::binary>>, utf8) do
    case Postbeam.SMTP.Binary.strchr(address, 58) do
      0 ->
        :error

      index ->
        parse_encoded_address(
          Postbeam.SMTP.Binary.substr(address, index + 1),
          [],
          %Postbeam.SMTP.Session.AddressState{quotes: false, ab: true, utf8: utf8}
        )
    end
  end

  defp parse_encoded_address(<<"<", address::binary>>, utf8) do
    parse_encoded_address(address, [], %Postbeam.SMTP.Session.AddressState{
      quotes: false,
      ab: true,
      utf8: utf8
    })
  end

  defp parse_encoded_address(<<" ", address::binary>>, utf8) do
    parse_encoded_address(address, utf8)
  end

  defp parse_encoded_address(address, utf8) do
    parse_encoded_address(address, [], %Postbeam.SMTP.Session.AddressState{
      quotes: false,
      ab: false,
      utf8: utf8
    })
  end

  @spec parse_encoded_address(
          binary(),
          list(),
          Postbeam.SMTP.Session.AddressState.t()
        ) :: {binary(), binary()} | :error
  defp parse_encoded_address(<<>>, acc, %Postbeam.SMTP.Session.AddressState{ab: false}) do
    {:unicode.characters_to_binary(:lists.reverse(acc)), <<>>}
  end

  defp parse_encoded_address(<<>>, _acc, %Postbeam.SMTP.Session.AddressState{ab: true}) do
    :error
  end

  defp parse_encoded_address(_, acc, _) when length(acc) > 320 do
    :error
  end

  defp parse_encoded_address(<<"\\", h, tail::binary>>, acc, flags) do
    parse_encoded_address(tail, [h | acc], flags)
  end

  defp parse_encoded_address(
         <<"\"", tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{quotes: false} = f
       ) do
    parse_encoded_address(tail, acc, %{f | quotes: true})
  end

  defp parse_encoded_address(
         <<"\"", tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{quotes: true} = f
       ) do
    parse_encoded_address(tail, acc, %{f | quotes: false})
  end

  defp parse_encoded_address(<<">", tail::binary>>, acc, %Postbeam.SMTP.Session.AddressState{
         quotes: false,
         ab: true
       }) do
    {:unicode.characters_to_binary(:lists.reverse(acc)),
     Postbeam.SMTP.Binary.strip(tail, :left, 32)}
  end

  defp parse_encoded_address(<<">", _tail::binary>>, _acc, %Postbeam.SMTP.Session.AddressState{
         quotes: false,
         ab: false
       }) do
    :error
  end

  defp parse_encoded_address(<<" ", tail::binary>>, acc, %Postbeam.SMTP.Session.AddressState{
         quotes: false,
         ab: false
       }) do
    {:unicode.characters_to_binary(:lists.reverse(acc)),
     Postbeam.SMTP.Binary.strip(tail, :left, 32)}
  end

  defp parse_encoded_address(<<" ", _tail::binary>>, _acc, %Postbeam.SMTP.Session.AddressState{
         quotes: false,
         ab: true
       }) do
    :error
  end

  defp parse_encoded_address(
         <<h::utf8, tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{utf8: true} = f
       )
       when h > 127 do
    parse_encoded_address(tail, [h | acc], f)
  end

  defp parse_encoded_address(
         <<h, tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{quotes: false} = f
       )
       when h >= 48 and h <= 57 do
    parse_encoded_address(tail, [h | acc], f)
  end

  defp parse_encoded_address(
         <<h, tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{quotes: false} = f
       )
       when h >= 64 and h <= 90 do
    parse_encoded_address(tail, [h | acc], f)
  end

  defp parse_encoded_address(
         <<h, tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{quotes: false} = f
       )
       when h >= 97 and h <= 122 do
    parse_encoded_address(tail, [h | acc], f)
  end

  defp parse_encoded_address(
         <<h, tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{quotes: false} = f
       )
       when h === 45 or h === 46 or h === 95 do
    parse_encoded_address(tail, [h | acc], f)
  end

  defp parse_encoded_address(
         <<h, tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{quotes: false} = f
       )
       when h === 43 or h === 33 or h === 35 or h === 36 or h === 37 or h === 38 or h === 39 or
              h === 42 or h === 61 or h === 47 or h === 63 or h === 94 or h === 96 or h === 123 or
              h === 124 or h === 125 or h === 126 do
    parse_encoded_address(tail, [h | acc], f)
  end

  defp parse_encoded_address(_, _acc, %Postbeam.SMTP.Session.AddressState{quotes: false}) do
    :error
  end

  defp parse_encoded_address(
         <<h, tail::binary>>,
         acc,
         %Postbeam.SMTP.Session.AddressState{quotes: true} = f
       ) do
    parse_encoded_address(tail, [h | acc], f)
  end

  @spec has_extension(list({charlist(), charlist()}), charlist()) :: {true, charlist()} | false
  defp has_extension(extensions, ext) do
    Postbeam.SMTP.Log.debug(~c"extensions ~p", [extensions], %{domain: [:postbeam, :server]})

    case :proplists.get_value(ext, extensions) do
      :undefined -> false
      value -> {true, value}
    end
  end

  @spec try_auth(
          :login | :plain | :"cram-md5",
          binary(),
          binary() | {binary(), binary()},
          Postbeam.SMTP.Session.State.t()
        ) :: {:ok, Postbeam.SMTP.Session.State.t()}
  defp try_auth(
         auth_type,
         username,
         credential,
         %Postbeam.SMTP.Session.State{
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
            send_reply(state, ~c"235 Authentication successful.\r\n")

            {:ok,
             %{
               new_state
               | callbackstate: callback_state,
                 envelope: %{envelope | auth: {username, credential}}
             }}

          _other ->
            send_reply(state, ~c"535 Authentication failed.\r\n")
            {:ok, new_state}
        end

      false ->
        Postbeam.SMTP.Log.warning(
          ~c"Please define handle_AUTH/4 in your server module or remove AUTH from your module extensions",
          %{domain: [:postbeam, :server]}
        )

        send_reply(state, ~c"535 authentication failed (#5.7.1)\r\n")
        {:ok, new_state}
    end
  end

  defp try_send(%Postbeam.SMTP.Session.State{transport: transport, socket: sock}, data) do
    transport.send(sock, data)
    :ok
  end

  defp send_reply(%Postbeam.SMTP.Session.State{transport: transport, socket: sock} = st, data) do
    case transport.send(sock, data) do
      :ok ->
        :ok

      {:error, err} ->
        st1 = handle_error(:send_error, err, st)
        throw({:stop, {:send_error, err}, st1})
    end
  end

  defp setopts(%Postbeam.SMTP.Session.State{transport: transport, socket: sock} = st, opts) do
    case transport.setopts(sock, opts) do
      :ok ->
        :ok

      {:error, err} ->
        st1 = handle_error(:setopts_error, err, st)
        throw({:stop, {:setopts_error, err}, st1})
    end
  end

  defp hostname(opts) do
    :proplists.get_value(:hostname, opts, Postbeam.SMTP.Util.guess_FQDN())
  end

  defp lhlo_if_lmtp(protocol, fallback) do
    case protocol == :lmtp do
      true -> ~c"LHLO"
      false -> fallback
    end
  end

  @spec report_recipient(
          :ok | :error | :multiple,
          charlist() | list({:ok | :error, charlist()}),
          Postbeam.SMTP.Session.State.t()
        ) :: any()
  defp report_recipient(:ok, reference, state) do
    send_reply(state, [~c"250 ", reference, ~c"\r\n"])
  end

  defp report_recipient(:error, message, state) do
    send_reply(state, [message, ~c"\r\n"])
  end

  defp report_recipient(:multiple, _any, %Postbeam.SMTP.Session.State{protocol: :smtp} = state) do
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

  defp format_extensions([{e, true}]) do
    [~c"250 ", e, ~c"\r\n"]
  end

  defp format_extensions([{e, v}]) do
    [~c"250 ", e, ~c" ", v, ~c"\r\n"]
  end

  defp format_extensions([line]) do
    [~c"250 ", line, ~c"\r\n"]
  end

  defp format_extensions([{e, true} | more]) do
    [~c"250-", e, ~c"\r\n" | format_extensions(more)]
  end

  defp format_extensions([{e, v} | more]) do
    [~c"250-", e, ~c" ", v, ~c"\r\n" | format_extensions(more)]
  end

  defp format_extensions([line | more]) do
    [~c"250-", line, ~c"\r\n" | format_extensions(more)]
  end
end
