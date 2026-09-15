# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Readability.PredicateFunctionNames
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

defmodule Postbeam.SMTP.Client do
  @moduledoc """
  SMTP and LMTP delivery with blocking, supervised asynchronous and bounded batch APIs.

  `send/2` preserves the original linked-process contract. Use `send_async/2` to
  isolate delivery failures, or `send_many/3` to consume a stream of results with
  bounded concurrency. `open/1`, `deliver/2` and `close/1` reuse a connection for
  sequential deliveries in the calling process.

  Options are keyword lists. Set `:relay`, and use `tls: :always` when encryption
  is required. Both STARTTLS and implicit TLS verify certificates by default;
  `:tls_options` can supply a private CA and server name.
  """
  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  require Record
  @type email_address() :: charlist() | binary()
  @type email() ::
          {email_address(), nonempty_list(email_address()),
           charlist() | binary() | (-> charlist() | binary())}
  @type options() ::
          list(
            {:ssl, boolean()}
            | {:link, boolean()}
            | {:tls, :always | :never | :if_available}
            | {:tls_options, list()}
            | {:sockopts, list(:gen_tcp.connect_option())}
            | {:port, :inet.port_number()}
            | {:timeout, timeout()}
            | {:relay, :inet.ip_address() | :inet.hostname() | binary()}
            | {:no_mx_lookups, boolean()}
            | {:auth, :always | :never | :if_available}
            | {:hostname, charlist()}
            | {:retries, non_neg_integer()}
            | {:username, charlist()}
            | {:password, charlist()}
            | {:trace_fun, (charlist(), list(any()) -> any())}
            | {:on_transaction_error, :quit | :reset}
            | {:protocol, :smtp | :lmtp}
          )
  @typep extensions() :: list({binary(), binary()})
  Record.defrecordp(:smtp_client_socket, :smtp_client_socket,
    socket: :undefined,
    host: :undefined,
    extensions: :undefined,
    options: :undefined
  )

  @opaque smtp_client_socket() ::
            record(:smtp_client_socket,
              socket: :undefined | Postbeam.SMTP.Socket.socket(),
              host: :undefined | charlist(),
              extensions: :undefined | list(),
              options: :undefined | list()
            )
  @type callback() :: ({:exit, any()} | smtp_session_error() | {:ok, binary()} -> any())
  @typep permanent_failure_reason() :: binary() | :auth_failed | :ssl_not_started
  @typep temporary_failure_reason() :: binary() | :tls_failed
  @type validate_options_error() :: :no_relay | :invalid_port | :no_credentials
  @type failure() ::
          {:temporary_failure, temporary_failure_reason()}
          | {:permanent_failure, permanent_failure_reason()}
          | {:missing_requirement, :auth | :tls}
          | {:unexpected_response, binary() | list(binary())}
          | {:network_failure, {:error, :timeout | :inet.posix()}}
  @typep smtp_host() :: :inet.hostname()
  @type host_failure() ::
          {:temporary_failure, smtp_host(), temporary_failure_reason()}
          | {:permanent_failure, smtp_host(), permanent_failure_reason()}
          | {:missing_requirement, smtp_host(), :auth | :tls}
          | {:unexpected_response, smtp_host(), binary() | list(binary())}
          | {:network_failure, smtp_host(), {:error, :timeout | :inet.posix()}}
  @type smtp_session_error() ::
          {:error, :no_more_hosts | :send,
           {:permanent_failure, smtp_host(), permanent_failure_reason()}}
          | {:error, :retries_exceeded | :send, host_failure()}
  @doc "Starts a supervised delivery linked to the caller; returns `{:error, :max_children}` at capacity."
  @spec send(email(), options()) ::
          {:ok, pid()} | {:error, term()}
  def send(email, options) do
    __MODULE__.send(email, options, :undefined)
  end

  @spec send(email(), options(), callback() | :undefined) ::
          {:ok, pid()} | {:error, term()}
  def send(email, options, callback) do
    new_options = normalize_options(options)

    case check_options(new_options) do
      :ok ->
        Postbeam.SMTP.Delivery.start(
          fn ->
            try do
              send_it(email, new_options)
            catch
              :exit, reason when is_function(callback, 1) -> callback.({:exit, reason})
            else
              {:error, _type, _reason} = error when is_function(callback, 1) -> callback.(error)
              {:error, _type, _reason} = error -> :erlang.exit(error)
              receipt when is_function(callback, 1) -> callback.({:ok, receipt})
              _receipt -> :ok
            end
          end,
          Keyword.get(new_options, :link, true)
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Starts a supervised delivery without linking failures to the caller."
  def send_async(email, options, callback \\ :undefined) do
    __MODULE__.send(email, Keyword.put(options, :link, false), callback)
  end

  @doc """
  Lazily sends messages concurrently, with at most `:max_concurrency` deliveries per stream.

  Results use `Task.async_stream/3` tuples. A failed or timed-out delivery does not
  crash the caller. `options` are SMTP options; `stream_options` control concurrency,
  ordering and timeout. Each task opens its own connection and is never restarted.
  """
  def send_many(emails, options, stream_options \\ []) do
    stream_options =
      Keyword.merge(
        [
          max_concurrency: System.schedulers_online(),
          ordered: true,
          timeout: 60_000,
          on_timeout: :kill_task
        ],
        stream_options
      )

    Task.Supervisor.async_stream_nolink(
      Postbeam.SMTP.ClientSupervisor,
      emails,
      fn email -> send_blocking(email, options) end,
      stream_options
    )
  end

  defp normalize_options(options) do
    defaults = [
      ssl: false,
      tls: :if_available,
      tls_options: [],
      auth: :if_available,
      retries: 1,
      on_transaction_error: :quit,
      protocol: :smtp
    ]

    defaults
    |> Keyword.merge(options)
    |> Keyword.put_new_lazy(:hostname, &Postbeam.SMTP.Util.guess_fqdn/0)
  end

  @doc "Delivers in the calling process and returns the server receipt or an error tuple."
  @spec send_blocking(email(), options()) ::
          binary()
          | nonempty_list({binary(), binary()})
          | smtp_session_error()
          | {:error, term()}
  def send_blocking(email, options) do
    new_options = normalize_options(options)

    case check_options(new_options) do
      :ok -> send_it(email, new_options)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Opens and authenticates a reusable connection owned by the calling process."
  @spec open(options()) ::
          {:ok, smtp_client_socket()}
          | smtp_session_error()
          | {:error, :bad_option, validate_options_error()}
  def open(options) do
    new_options = normalize_options(options)

    case check_options(new_options) do
      :ok ->
        try_smtp_sessions(smtp_hosts(new_options), new_options, [])

      {:error, reason} ->
        {:error, :bad_option, reason}
    end
  end

  @doc "Sends one message over a connection returned by `open/1`."
  @spec deliver(smtp_client_socket(), email()) ::
          {:ok, binary() | nonempty_list({binary(), binary()})} | {:error, failure()}
  def deliver(smtp_client_socket([]) = smtp_client_socket, email) do
    smtp_client_socket(socket: socket, extensions: extensions, options: options) =
      smtp_client_socket

    try do
      receipt = try_sending_it(email, socket, extensions, options)
      {:ok, receipt}
    catch
      :throw, fail_msg -> {:error, fail_msg}
    end
  end

  @doc "Sends QUIT and closes a reusable connection."
  @spec close(smtp_client_socket()) :: :ok
  def close(smtp_client_socket(socket: socket)) do
    quit(socket)
  end

  @spec send_it(email(), options()) :: binary() | smtp_session_error()
  defp send_it(email, options) do
    case try_smtp_sessions(smtp_hosts(options), options, []) do
      {:error, _, _} = error ->
        error

      {:ok, client_socket} ->
        smtp_client_socket(socket: socket, host: host, extensions: extensions, options: options1) =
          client_socket

        try do
          try_sending_it(email, socket, extensions, options1)
        catch
          :throw, {failure_type, message} -> {:error, :send, {failure_type, host, message}}
        after
          quit(socket)
        end
    end
  end

  defp smtp_hosts(options) do
    relay = Keyword.fetch!(options, :relay)
    relay = if is_binary(relay), do: String.to_charlist(relay), else: relay

    records =
      if is_tuple(relay) or Keyword.get(options, :no_mx_lookups, false) do
        []
      else
        Postbeam.SMTP.Util.mxlookup(relay)
      end

    trace(options, ~c"MX records for ~p are ~p~n", [relay, records])
    if records == [], do: [{0, relay}], else: records
  end

  @spec try_smtp_sessions(nonempty_list({non_neg_integer(), charlist()}), options(), list()) ::
          {:ok, smtp_client_socket()} | smtp_session_error()
  defp try_smtp_sessions([{_distance, host} | _tail] = hosts, options, retry_list) do
    try do
      {:ok, open_smtp_session(host, options)}
    catch
      :throw, fail_msg -> handle_smtp_throw(fail_msg, hosts, options, retry_list)
    end
  end

  @spec handle_smtp_throw(failure(), list({non_neg_integer(), smtp_host()}), options(), list()) ::
          {:ok, smtp_client_socket()} | smtp_session_error()
  defp handle_smtp_throw(
         {:permanent_failure, message},
         [{_distance, host} | _tail],
         _options,
         _retry_list
       ) do
    {:error, :no_more_hosts, {:permanent_failure, host, message}}
  end

  defp handle_smtp_throw(
         {:temporary_failure, :tls_failed},
         [{_distance, host} | _tail] = hosts,
         options,
         retry_list
       ) do
    case :proplists.get_value(:tls, options) do
      :if_available ->
        no_tls_options = [{:tls, :never} | :proplists.delete(:tls, options)]

        try do
          open_smtp_session(host, no_tls_options)
        catch
          :throw, fail_msg -> handle_smtp_throw(fail_msg, hosts, options, retry_list)
        else
          res -> {:ok, res}
        end

      _ ->
        try_next_host({:temporary_failure, :tls_failed}, hosts, options, retry_list)
    end
  end

  defp handle_smtp_throw(fail_msg, hosts, options, retry_list) do
    try_next_host(fail_msg, hosts, options, retry_list)
  end

  defp try_next_host(
         {failure_type, message},
         [{_distance, host} | _tail] = hosts,
         options,
         retry_list
       ) do
    retries = :proplists.get_value(:retries, options)
    retry_count = :proplists.get_value(host, retry_list)

    case fetch_next_host(retries, retry_count, hosts, retry_list, options) do
      {[], _new_retry_list} -> {:error, :retries_exceeded, {failure_type, host, message}}
      {new_hosts, new_retry_list} -> try_smtp_sessions(new_hosts, options, new_retry_list)
    end
  end

  defp fetch_next_host(retries, retry_count, [{_distance, host} | tail], retry_list, options)
       when is_integer(retry_count) and retry_count >= retries do
    trace(options, ~c"retries for ~s exceeded (~p of ~p)~n", [host, retry_count, retries])
    {tail, :lists.keydelete(host, 1, retry_list)}
  end

  defp fetch_next_host(retries, retry_count, [{distance, host} | tail], retry_list, options)
       when is_integer(retry_count) do
    trace(options, ~c"scheduling ~p for retry (~p of ~p)~n", [host, retry_count, retries])

    {tail ++ [{distance, host}],
     :lists.keydelete(host, 1, retry_list) ++ [{host, retry_count + 1}]}
  end

  defp fetch_next_host(0, _retry_count, [{_distance, host} | tail], retry_list, _options) do
    {tail, :lists.keydelete(host, 1, retry_list)}
  end

  defp fetch_next_host(retries, _retry_count, [{distance, host} | tail], retry_list, options) do
    trace(options, ~c"scheduling ~p for retry (~p of ~p)~n", [host, 1, retries])
    {tail ++ [{distance, host}], :lists.keydelete(host, 1, retry_list) ++ [{host, 1}]}
  end

  @spec open_smtp_session(charlist(), options()) :: smtp_client_socket()
  defp open_smtp_session(host, options) do
    {:ok, socket, _host2, banner} = connect(host, options)
    trace(options, ~c"connected to ~p; banner was ~s~n", [host, banner])
    {:ok, extensions} = try_ehlo(socket, options)
    trace(options, ~c"Extensions are ~p~n", [extensions])

    {socket2, extensions2} =
      if Postbeam.SMTP.Socket.get_proto(socket) == :ssl do
        {socket, extensions}
      else
        try_starttls(socket, options, extensions)
      end

    trace(options, ~c"Extensions are ~p~n", [extensions2])
    authed = try_auth(socket2, options, :proplists.get_value("AUTH", extensions2))
    trace(options, ~c"Authentication status is ~p~n", [authed])
    smtp_client_socket(socket: socket2, host: host, extensions: extensions2, options: options)
  end

  @spec try_sending_it(email(), Postbeam.SMTP.Socket.socket(), extensions(), options()) ::
          binary() | nonempty_list({binary(), binary()})
  defp try_sending_it({from, to, body}, socket, extensions, options) do
    try_mail_from(from, socket, extensions, options)
    try_rcpt_to(to, socket, extensions, options)

    case :proplists.get_value(:protocol, options) do
      :smtp -> try_data(body, socket, extensions, options)
      :lmtp -> try_lmtp_data(body, to, socket, extensions, options)
    end
  end

  @spec try_mail_from(email_address(), Postbeam.SMTP.Socket.socket(), extensions(), options()) ::
          true
  defp try_mail_from(from, socket, extensions, options) when is_binary(from) do
    try_mail_from(:erlang.binary_to_list(from), socket, extensions, options)
  end

  defp try_mail_from(~c"<" ++ _ = from, socket, _extensions, options) do
    on_tx_error = :proplists.get_value(:on_transaction_error, options)
    Postbeam.SMTP.Socket.send(socket, [~c"MAIL FROM:", from, ~c"\r\n"])

    case read_possible_multiline_reply(socket) do
      {:ok, <<"250", _rest::binary>>} ->
        true

      {:ok, <<"4", _rest::binary>> = msg} when on_tx_error === :reset ->
        rset_or_quit(socket)
        throw({:temporary_failure, msg})

      {:ok, <<"4", _rest::binary>> = msg} ->
        quit(socket)
        throw({:temporary_failure, msg})

      {:ok, <<"5", _rest::binary>> = msg} when on_tx_error === :reset ->
        trace(options, ~c"Mail FROM rejected: ~p~n", [msg])
        :ok = rset_or_quit(socket)
        throw({:permanent_failure, msg})

      {:ok, msg} ->
        trace(options, ~c"Mail FROM rejected: ~p~n", [msg])
        quit(socket)
        throw({:permanent_failure, msg})
    end
  end

  defp try_mail_from(from, socket, extension, options) do
    try_mail_from(~c"<" ++ from ++ ~c">", socket, extension, options)
  end

  @spec try_rcpt_to(list(email_address()), Postbeam.SMTP.Socket.socket(), extensions(), options()) ::
          true
  defp try_rcpt_to([], _socket, _extensions, _options) do
    true
  end

  defp try_rcpt_to([to | tail], socket, extensions, options) when is_binary(to) do
    try_rcpt_to([:erlang.binary_to_list(to) | tail], socket, extensions, options)
  end

  defp try_rcpt_to([~c"<" ++ _ = to | tail], socket, extensions, options) do
    on_tx_error = :proplists.get_value(:on_transaction_error, options)
    Postbeam.SMTP.Socket.send(socket, [~c"RCPT TO:", to, ~c"\r\n"])

    case read_possible_multiline_reply(socket) do
      {:ok, <<"250", _rest::binary>>} ->
        try_rcpt_to(tail, socket, extensions, options)

      {:ok, <<"251", _rest::binary>>} ->
        try_rcpt_to(tail, socket, extensions, options)

      {:ok, <<"4", _rest::binary>> = msg} when on_tx_error === :reset ->
        rset_or_quit(socket)
        throw({:temporary_failure, msg})

      {:ok, <<"4", _rest::binary>> = msg} ->
        quit(socket)
        throw({:temporary_failure, msg})

      {:ok, <<"5", _rest::binary>> = msg} when on_tx_error === :reset ->
        rset_or_quit(socket)
        throw({:permanent_failure, msg})

      {:ok, msg} ->
        quit(socket)
        throw({:permanent_failure, msg})
    end
  end

  defp try_rcpt_to([to | tail], socket, extensions, options) do
    try_rcpt_to([~c"<" ++ to ++ ~c">" | tail], socket, extensions, options)
  end

  @spec try_data(binary() | function(), Postbeam.SMTP.Socket.socket(), extensions(), options()) ::
          binary()
  defp try_data(body, socket, extensions, options) when is_function(body) do
    try_data(body.(), socket, extensions, options)
  end

  defp try_data(body, socket, _extensions, options) do
    on_tx_error = :proplists.get_value(:on_transaction_error, options)
    Postbeam.SMTP.Socket.send(socket, ~c"DATA\r\n")

    case read_possible_multiline_reply(socket) do
      {:ok, <<"354", _rest::binary>>} ->
        escaped_body = :re.replace(body, "^\\.", "..", [:global, :multiline, return: :binary])
        Postbeam.SMTP.Socket.send(socket, [escaped_body, ~c"\r\n.\r\n"])

        case read_possible_multiline_reply(socket) do
          {:ok, <<"250 ", receipt::binary>>} ->
            receipt

          {:ok, <<"4", _rest2::binary>> = msg} when on_tx_error === :reset ->
            throw({:temporary_failure, msg})

          {:ok, <<"4", _rest2::binary>> = msg} ->
            quit(socket)
            throw({:temporary_failure, msg})

          {:ok, <<"5", _rest2::binary>> = msg} when on_tx_error === :reset ->
            throw({:permanent_failure, msg})

          {:ok, msg} ->
            quit(socket)
            throw({:permanent_failure, msg})
        end

      {:ok, <<"4", _rest::binary>> = msg} when on_tx_error === :reset ->
        rset_or_quit(socket)
        throw({:temporary_failure, msg})

      {:ok, <<"4", _rest::binary>> = msg} ->
        quit(socket)
        throw({:temporary_failure, msg})

      {:ok, <<"5", _rest::binary>> = msg} when on_tx_error === :reset ->
        rset_or_quit(socket)
        throw({:permanent_failure, msg})

      {:ok, msg} ->
        quit(socket)
        throw({:permanent_failure, msg})
    end
  end

  @spec try_lmtp_data(
          binary() | function(),
          nonempty_list(binary()),
          Postbeam.SMTP.Socket.socket(),
          extensions(),
          options()
        ) :: binary() | nonempty_list({email_address(), binary() | charlist()})
  defp try_lmtp_data(body, to, socket, extensions, options) when is_function(body) do
    try_lmtp_data(body.(), to, socket, extensions, options)
  end

  defp try_lmtp_data(body, to, socket, _extensions, options) do
    on_tx_error = :proplists.get_value(:on_transaction_error, options)
    Postbeam.SMTP.Socket.send(socket, ~c"DATA\r\n")

    case read_possible_multiline_reply(socket) do
      {:ok, <<"354", _rest::binary>>} ->
        escaped_body = :re.replace(body, "^\\.", "..", [:global, :multiline, return: :binary])
        Postbeam.SMTP.Socket.send(socket, [escaped_body, ~c"\r\n.\r\n"])

        :lists.map(
          fn recipient ->
            {:ok, receipt} = read_possible_multiline_reply(socket)
            {recipient, receipt}
          end,
          to
        )

      {:ok, <<"4", _rest::binary>> = msg} when on_tx_error === :reset ->
        rset_or_quit(socket)
        throw({:temporary_failure, msg})

      {:ok, <<"4", _rest::binary>> = msg} ->
        quit(socket)
        throw({:temporary_failure, msg})

      {:ok, <<"5", _rest::binary>> = msg} when on_tx_error === :reset ->
        rset_or_quit(socket)
        throw({:permanent_failure, msg})

      {:ok, msg} ->
        quit(socket)
        throw({:permanent_failure, msg})
    end
  end

  @spec try_auth(Postbeam.SMTP.Socket.socket(), options(), list(charlist())) :: boolean()
  defp try_auth(socket, options, []) do
    case :proplists.get_value(:auth, options) do
      :always ->
        quit(socket)
        throw({:missing_requirement, :auth})

      _ ->
        false
    end
  end

  defp try_auth(socket, options, :undefined) do
    case :proplists.get_value(:auth, options) do
      :always ->
        quit(socket)
        throw({:missing_requirement, :auth})

      _ ->
        false
    end
  end

  defp try_auth(socket, options, auth_types) do
    case :erlang.and(
           :erlang.and(
             :proplists.is_defined(:username, options),
             :proplists.is_defined(:password, options)
           ),
           :proplists.get_value(:auth, options) !== :never
         ) do
      false ->
        case :proplists.get_value(:auth, options) do
          :always ->
            quit(socket)
            throw({:missing_requirement, :auth})

          _ ->
            false
        end

      true ->
        username = to_binary(:proplists.get_value(:username, options))
        password = to_binary(:proplists.get_value(:password, options))
        trace(options, ~c"Auth types: ~p~n", [auth_types])
        types = :re.split(auth_types, ~c" ", [{:return, :list}, :trim])

        case do_auth(socket, username, password, types, options) do
          false ->
            case :proplists.get_value(:auth, options) do
              :always ->
                quit(socket)
                throw({:permanent_failure, :auth_failed})

              _ ->
                false
            end

          true ->
            true
        end
    end
  end

  defp to_binary(string) when is_binary(string) do
    string
  end

  defp to_binary(string) when is_list(string) do
    :erlang.list_to_binary(string)
  end

  @spec do_auth(Postbeam.SMTP.Socket.socket(), binary(), binary(), list(charlist()), options()) ::
          boolean()
  defp do_auth(socket, username, password, types, options) do
    fixed_types = for x <- types, into: [], do: :string.to_upper(x)
    trace(options, ~c"Fixed types: ~p~n", [fixed_types])

    allowed_types =
      for x <- [~c"CRAM-MD5", ~c"LOGIN", ~c"PLAIN", ~c"XOAUTH2"],
          :lists.member(x, fixed_types),
          into: [],
          do: x

    trace(options, ~c"available authentication types, in order of preference: ~p~n", [
      allowed_types
    ])

    do_auth_each(socket, username, password, allowed_types, options)
  end

  @spec do_auth_each(
          Postbeam.SMTP.Socket.socket(),
          binary(),
          binary(),
          list(charlist()),
          options()
        ) ::
          boolean()
  defp do_auth_each(_socket, _username, _password, [], _options) do
    false
  end

  defp do_auth_each(socket, username, password, [~c"CRAM-MD5" | tail], options) do
    Postbeam.SMTP.Socket.send(socket, ~c"AUTH CRAM-MD5\r\n")

    case read_possible_multiline_reply(socket) do
      {:ok, <<"334 ", rest::binary>>} ->
        seed64 =
          Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.strip(rest, :right, 10), :right, 13)

        seed = :base64.decode(seed64)
        digest = Postbeam.SMTP.Util.compute_cram_digest(password, seed)
        string = :base64.encode(:erlang.list_to_binary([username, ~c" ", digest]))
        Postbeam.SMTP.Socket.send(socket, [string, ~c"\r\n"])

        case read_possible_multiline_reply(socket) do
          {:ok, <<"235", _rest::binary>>} ->
            trace(options, ~c"authentication accepted~n", [])
            true

          {:ok, msg} ->
            trace(options, ~c"authentication rejected: ~s~n", [msg])
            do_auth_each(socket, username, password, tail, options)
        end

      {:ok, something} ->
        trace(options, ~c"got ~s~n", [something])
        do_auth_each(socket, username, password, tail, options)
    end
  end

  defp do_auth_each(socket, username, password, [~c"XOAUTH2" | tail], options) do
    str =
      :base64.encode(
        :erlang.list_to_binary([~c"user=", username, 1, ~c"auth=Bearer ", password, 1, 1])
      )

    Postbeam.SMTP.Socket.send(socket, [~c"AUTH XOAUTH2 ", str, ~c"\r\n"])

    case read_possible_multiline_reply(socket) do
      {:ok, <<"235", _rest::binary>>} -> true
      {:ok, _msg} -> do_auth_each(socket, username, password, tail, options)
    end
  end

  defp do_auth_each(socket, username, password, [~c"LOGIN" | tail], options) do
    Postbeam.SMTP.Socket.send(socket, ~c"AUTH LOGIN\r\n")
    {:ok, prompt} = read_possible_multiline_reply(socket)

    case is_auth_username_prompt(prompt) do
      true ->
        trace(options, ~c"username prompt~n", [])
        u = :base64.encode(username)
        Postbeam.SMTP.Socket.send(socket, [u, ~c"\r\n"])
        {:ok, prompt2} = read_possible_multiline_reply(socket)

        case is_auth_password_prompt(prompt2) do
          true ->
            trace(options, ~c"password prompt~n", [])
            p = :base64.encode(password)
            Postbeam.SMTP.Socket.send(socket, [p, ~c"\r\n"])

            case read_possible_multiline_reply(socket) do
              {:ok, <<"235 ", _rest::binary>>} ->
                trace(options, ~c"authentication accepted~n", [])
                true

              {:ok, msg} ->
                trace(options, ~c"password rejected: ~s", [msg])
                do_auth_each(socket, username, password, tail, options)
            end

          false ->
            trace(options, ~c"username rejected: ~s", [prompt2])
            do_auth_each(socket, username, password, tail, options)
        end

      false ->
        trace(options, ~c"got ~s~n", [prompt])
        do_auth_each(socket, username, password, tail, options)
    end
  end

  defp do_auth_each(socket, username, password, [~c"PLAIN" | tail], options) do
    auth_string = :base64.encode(<<0, username::binary, 0, password::binary>>)
    Postbeam.SMTP.Socket.send(socket, [~c"AUTH PLAIN ", auth_string, ~c"\r\n"])

    case read_possible_multiline_reply(socket) do
      {:ok, <<"235", _rest::binary>>} ->
        trace(options, ~c"authentication accepted~n", [])
        true

      var_else ->
        trace(options, ~c"authentication rejected ~p~n", [var_else])
        do_auth_each(socket, username, password, tail, options)
    end
  end

  defp do_auth_each(socket, username, password, [type | tail], options) do
    trace(options, ~c"unsupported AUTH type ~s~n", [type])
    do_auth_each(socket, username, password, tail, options)
  end

  defp is_auth_username_prompt("334 VXNlcm5hbWU6\r\n") do
    true
  end

  defp is_auth_username_prompt("334 dXNlcm5hbWU6\r\n") do
    true
  end

  defp is_auth_username_prompt(<<"334 VXNlcm5hbWU6 ", _::binary>>) do
    true
  end

  defp is_auth_username_prompt(<<"334 dXNlcm5hbWU6 ", _::binary>>) do
    true
  end

  defp is_auth_username_prompt(_) do
    false
  end

  defp is_auth_password_prompt("334 UGFzc3dvcmQ6\r\n") do
    true
  end

  defp is_auth_password_prompt("334 cGFzc3dvcmQ6\r\n") do
    true
  end

  defp is_auth_password_prompt(<<"334 UGFzc3dvcmQ6 ", _::binary>>) do
    true
  end

  defp is_auth_password_prompt(<<"334 cGFzc3dvcmQ6 ", _::binary>>) do
    true
  end

  defp is_auth_password_prompt(_) do
    false
  end

  @spec try_ehlo(Postbeam.SMTP.Socket.socket(), options()) :: {:ok, extensions()}
  defp try_ehlo(socket, options) do
    hallo =
      case :proplists.get_value(:protocol, options, :smtp) do
        :lmtp -> ~c"LHLO "
        _ -> ~c"EHLO "
      end

    :ok =
      Postbeam.SMTP.Socket.send(socket, [
        hallo,
        Keyword.fetch!(options, :hostname),
        ~c"\r\n"
      ])

    case read_possible_multiline_reply(socket) do
      {:ok, <<"500", _rest::binary>>} ->
        try_helo(socket, options)

      {:ok, <<"4", _rest::binary>> = msg} ->
        quit(socket)
        throw({:temporary_failure, msg})

      {:ok, reply} ->
        {:ok, parse_extensions(reply, options)}
    end
  end

  @spec try_helo(Postbeam.SMTP.Socket.socket(), options()) :: {:ok, list()}
  defp try_helo(socket, options) do
    :ok =
      Postbeam.SMTP.Socket.send(socket, [
        ~c"HELO ",
        Keyword.fetch!(options, :hostname),
        ~c"\r\n"
      ])

    case read_possible_multiline_reply(socket) do
      {:ok, <<"250", _rest::binary>>} ->
        {:ok, []}

      {:ok, <<"4", _rest::binary>> = msg} ->
        quit(socket)
        throw({:temporary_failure, msg})

      {:ok, msg} ->
        quit(socket)
        throw({:permanent_failure, msg})
    end
  end

  @spec try_starttls(Postbeam.SMTP.Socket.socket(), options(), extensions()) ::
          {Postbeam.SMTP.Socket.socket(), extensions()}
  defp try_starttls(socket, options, extensions) do
    case {:proplists.get_value(:tls, options), :proplists.get_value("STARTTLS", extensions)} do
      {atom, true} when atom === :always or atom === :if_available ->
        trace(options, ~c"Starting TLS~n", [])

        case {do_starttls(socket, options), atom} do
          {false, :always} ->
            trace(options, ~c"TLS failed~n", [])
            quit(socket)
            throw({:temporary_failure, :tls_failed})

          {false, :if_available} ->
            trace(options, ~c"TLS failed~n", [])
            {socket, extensions}

          {{s, e}, _} ->
            trace(options, ~c"TLS started~n", [])
            {s, e}
        end

      {:always, _} ->
        quit(socket)
        throw({:missing_requirement, :tls})

      _ ->
        trace(options, ~c"TLS not requested~n", [])
        {socket, extensions}
    end
  end

  @spec do_starttls(Postbeam.SMTP.Socket.socket(), options()) ::
          {Postbeam.SMTP.Socket.socket(), extensions()} | false
  defp do_starttls(socket, options) do
    Postbeam.SMTP.Socket.send(socket, ~c"STARTTLS\r\n")

    case read_possible_multiline_reply(socket) do
      {:ok, <<"220", _rest::binary>>} ->
        case (try do
                Postbeam.SMTP.Socket.to_ssl_client(
                  socket,
                  [:binary | :proplists.get_value(:tls_options, options, [])],
                  5000
                )
              catch
                :throw, term -> term
                :exit, reason -> {:EXIT, reason}
                :error, reason -> {:EXIT, {reason, __STACKTRACE__}}
              end) do
          {:ok, new_socket} ->
            {:ok, extensions} = try_ehlo(new_socket, options)
            {new_socket, extensions}

          {:EXIT, reason} ->
            quit(socket)
            :error_logger.error_msg(~c"Error in ssl upgrade: ~p.~n", [reason])
            throw({:temporary_failure, :tls_failed})

          {:error, :closed} ->
            quit(socket)
            :error_logger.error_msg(~c"Error in ssl upgrade: socket closed.~n")
            throw({:temporary_failure, :tls_failed})

          {:error, :ssl_not_started} ->
            quit(socket)
            :error_logger.error_msg(~c"SSL not started.~n")
            throw({:permanent_failure, :ssl_not_started})

          {:error, reason} ->
            quit(socket)
            trace(options, ~c"TLS negotiation failed: ~p~n", [reason])
            throw({:temporary_failure, :tls_failed})

          var_else ->
            trace(options, ~c"~p~n", [var_else])
            false
        end

      {:ok, <<"4", _rest::binary>> = msg} ->
        quit(socket)
        throw({:temporary_failure, msg})

      {:ok, msg} ->
        quit(socket)
        throw({:permanent_failure, msg})
    end
  end

  defp connect(host, options) when is_binary(host) do
    connect(:erlang.binary_to_list(host), options)
  end

  defp connect(host, options) do
    proto = if Keyword.get(options, :ssl, false), do: :ssl, else: :tcp
    port = Keyword.get(options, :port, if(proto == :ssl, do: 465, else: 25))
    timeout = Keyword.get(options, :timeout, 5000)
    extra_options = Keyword.get(options, :sockopts, [])

    extra_options =
      if proto == :ssl do
        Keyword.get(options, :tls_options, []) ++ extra_options
      else
        extra_options
      end

    sock_opts = [:binary, {:packet, :line}, {:keepalive, true}, {:active, false} | extra_options]

    case Postbeam.SMTP.Socket.connect(proto, host, port, sock_opts, timeout) do
      {:ok, socket} ->
        case read_possible_multiline_reply(socket) do
          {:ok, <<"220", banner::binary>>} ->
            {:ok, socket, host, banner}

          {:ok, <<"4", _rest::binary>> = msg} ->
            quit(socket)
            throw({:temporary_failure, msg})

          {:ok, msg} ->
            quit(socket)
            throw({:permanent_failure, msg})
        end

      {:error, reason} ->
        throw({:network_failure, {:error, reason}})
    end
  end

  @spec read_possible_multiline_reply(Postbeam.SMTP.Socket.socket()) :: {:ok, binary()}
  defp read_possible_multiline_reply(socket) do
    case Postbeam.SMTP.Socket.recv(socket, 0, 1_200_000) do
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

  @spec read_multiline_reply(Postbeam.SMTP.Socket.socket(), binary(), list(binary())) ::
          {:ok, binary()}
  defp read_multiline_reply(socket, code, acc) do
    case Postbeam.SMTP.Socket.recv(socket, 0, 1_200_000) do
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

  defp rset_or_quit(socket) do
    :ok = Postbeam.SMTP.Socket.send(socket, ~c"RSET\r\n")

    case read_possible_multiline_reply(socket) do
      {:ok, <<"250", _rest::binary>>} -> :ok
      {:ok, _msg} -> quit(socket)
    end
  end

  defp quit(socket) do
    Postbeam.SMTP.Socket.send(socket, ~c"QUIT\r\n")
    Postbeam.SMTP.Socket.close(socket)
    :ok
  end

  defp check_options(options) do
    checked_options = [:relay, :port, :auth]

    :lists.foldl(
      fn option, state ->
        case state do
          :ok ->
            value = :proplists.get_value(option, options)
            check_option({option, value}, options)

          other ->
            other
        end
      end,
      :ok,
      checked_options
    )
  end

  defp check_option({:relay, :undefined}, _options) do
    {:error, :no_relay}
  end

  defp check_option({:relay, _}, _options) do
    :ok
  end

  defp check_option({:port, :undefined}, _options) do
    :ok
  end

  defp check_option({:port, port}, _options) when is_integer(port) and port in 1..65_535 do
    :ok
  end

  defp check_option({:port, _}, _options) do
    {:error, :invalid_port}
  end

  defp check_option({:auth, :always}, options) do
    case :erlang.and(
           :proplists.is_defined(:username, options),
           :proplists.is_defined(:password, options)
         ) do
      false -> {:error, :no_credentials}
      true -> :ok
    end
  end

  defp check_option({:auth, _}, _options) do
    :ok
  end

  @spec parse_extensions(binary(), options()) :: extensions()
  defp parse_extensions(reply, options) do
    [_ | reply2] = :re.split(reply, ~c"\r\n", [{:return, :binary}, :trim])

    for entry <- reply2,
        into: [],
        do:
          (
            body = Postbeam.SMTP.Binary.substr(entry, 5)

            case :re.split(body, ~c" ", [{:return, :binary}, :trim, parts: 2]) do
              [verb, parameters] ->
                {Postbeam.SMTP.Binary.to_upper(verb), parameters}

              [^body] ->
                case Postbeam.SMTP.Binary.strchr(body, 61) do
                  0 ->
                    {Postbeam.SMTP.Binary.to_upper(body), true}

                  _ ->
                    trace(options, ~c"discarding option ~p~n", [body])
                    []
                end
            end
          )
  end

  defp trace(options, format, args) do
    case :proplists.get_value(:trace_fun, options) do
      :undefined -> :ok
      f -> f.(format, args)
    end
  end
end
