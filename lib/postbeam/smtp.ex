defmodule Postbeam.SMTP do
  @moduledoc """
  SMTP transport and adapter contract.

  `deliver/3` attempts one MX, returning a receipt or a classified error:
  `:retry` allows another MX, `:permanent` stops delivery, `:uncertain` stops
  delivery because the server may already have accepted the message.

  The default adapter tries every A/AAAA address using `Postbeam.SMTP.Client`. Each address attempt owns its sockets in a short-lived
  monitored process with a hard `smtp_timeout` (including connection and TLS).
  `connect_timeout` additionally bounds each TCP connection.
  """

  alias Postbeam.SMTP.Client
  alias Postbeam.SMTP.Delivery
  alias Postbeam.SMTP.TLS

  alias Postbeam.Config
  alias Postbeam.Message
  alias Postbeam.MX

  @typedoc "Only `:retry` authorizes the orchestrator to attempt another MX."
  @type failure :: {:retry | :permanent | :uncertain, term()}
  @type result :: {:ok, binary()} | {:error, failure()}
  @typep phase :: :connect | :envelope | :data

  @doc """
  Attempts one MX and returns an acceptance receipt or a classified failure.

  Implementations receive immutable MIME bytes and a Message-ID in `message`.
  They own address resolution, deadlines and cleanup. Return `:uncertain` after
  a disconnect if acceptance cannot be ruled out, even when retrying would be
  convenient. Adapter-specific diagnostics are preserved as the failure reason.
  """
  @callback deliver(String.t(), Message.encoded(), Config.t()) :: result()

  @doc """
  Default SMTP adapter: resolves A/AAAA and attempts each address sequentially.

  Session failures try another address; permanent envelope/message errors and
  uncertain results stop. SMTP AUTH, implicit TLS and dependency-managed retries
  are disabled. STARTTLS verifies the MX certificate against system CAs unless
  explicitly overridden in `:tls_options`.

  The DATA marker is emitted just before the DATA command. Network failures from that point are conservatively
  uncertain. Each worker exits after its attempt, releasing owned TCP/TLS sockets.
  """
  @spec deliver(String.t(), Message.encoded(), Config.t()) :: result()
  def deliver(host, message, config) do
    case MX.addresses(host, config) do
      {:ok, addresses} -> attempt_addresses(addresses, host, message, config, [])
      {:error, reason} -> {:error, {:retry, reason}}
    end
  end

  @spec attempt_addresses([:inet.ip_address()], String.t(), Message.encoded(), Config.t(), [
          {:inet.ip_address(), term()}
        ]) :: result()
  defp attempt_addresses([], host, _, _, errors),
    do: {:error, {:retry, {:addresses_exhausted, host, Enum.reverse(errors)}}}

  defp attempt_addresses([address | rest], host, message, config, errors) do
    case attempt(address, host, message, config) do
      {:error, {:retry, reason}} ->
        attempt_addresses(rest, host, message, config, [{address, reason} | errors])

      result ->
        result
    end
  end

  @spec attempt(:inet.ip_address(), String.t(), Message.encoded(), Config.t()) :: result()
  defp attempt(address, host, message, config) do
    parent = self()
    token = make_ref()

    case Delivery.start_monitor(fn ->
           run_session(parent, token, address, host, message, config)
         end) do
      {:ok, pid, monitor} -> await(pid, monitor, token, :connect)
      {:error, reason} -> {:error, {:retry, reason}}
    end
  end

  @doc false
  @spec run_session(
          pid(),
          reference(),
          :inet.ip_address(),
          String.t(),
          Message.encoded(),
          Config.t()
        ) :: :ok
  def run_session(parent, token, address, host, message, config) do
    # Also bounds socket lifetime if the caller exits unexpectedly.
    {:ok, timer} = :timer.kill_after(Keyword.fetch!(config, :smtp_timeout))
    result = transact(parent, token, address, host, message, config)
    {:ok, :cancel} = :timer.cancel(timer)
    # Worker exit releases every socket, including failed opens. QUIT errors
    # must never replace an already received acceptance or rejection.
    send(parent, {token, :result, result})
    :ok
  end

  @spec transact(
          pid(),
          reference(),
          :inet.ip_address(),
          String.t(),
          Message.encoded(),
          Config.t()
        ) :: term()
  defp transact(parent, token, address, host, message, config) do
    case Client.open(options(address, host, config)) do
      {:ok, socket} ->
        send(parent, {token, :envelope})

        body = fn ->
          # The client evaluates the body before issuing DATA, not after 354.
          send(parent, {token, :data})
          message.data
        end

        Client.deliver(socket, {message.from, [message.to], body})

      error ->
        error
    end
  catch
    kind, reason -> {:crash, kind, reason}
  end

  @spec await(pid(), reference(), reference(), phase()) :: result()
  defp await(pid, monitor, token, phase) do
    receive do
      {^token, next_phase} ->
        await(pid, monitor, token, next_phase)

      {^token, :result, result} ->
        # Wait for termination so the transport has released all owned sockets.
        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> classify(result, phase)
        end

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        classify({:error, :timeout}, phase)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        classify({:error, {:exit, reason}}, phase)
    end
  end

  @spec classify(term(), phase()) :: result()
  defp classify({:ok, receipt}, _), do: {:ok, receipt}

  defp classify({:error, _, {kind, _host, reason}}, phase),
    do: classify({:error, {kind, reason}}, phase)

  defp classify({:error, {:permanent_failure, reason}}, phase) when phase != :connect,
    do: {:error, {:permanent, reason}}

  defp classify({:error, {:temporary_failure, reason}}, _),
    do: {:error, {:retry, reason}}

  defp classify(reason, :data), do: {:error, {:uncertain, reason}}
  defp classify(reason, _), do: {:error, {:retry, reason}}

  @spec options(:inet.ip_address(), String.t(), Config.t()) :: keyword()
  defp options(address, host, config) do
    [
      relay: address,
      port: config[:port],
      hostname: String.to_charlist(config[:hostname]),
      timeout: config[:connect_timeout],
      tls_timeout: Keyword.get(config, :tls_timeout, config[:connect_timeout]),
      tls: config[:tls],
      tls_options: tls_options(host, config),
      sockopts: [
        if(tuple_size(address) == 8, do: :inet6, else: :inet),
        {:ip, if(tuple_size(address) == 8, do: {0, 0, 0, 0, 0, 0, 0, 0}, else: {0, 0, 0, 0})},
        {:send_timeout, config[:connect_timeout]},
        {:send_timeout_close, true}
      ],
      auth: :never,
      ssl: false,
      no_mx_lookups: true,
      retries: 0
    ]
  end

  @spec tls_options(String.t(), Config.t()) :: keyword()
  defp tls_options(host, config) do
    Keyword.merge(
      [
        versions: [:"tlsv1.2", :"tlsv1.3"],
        depth: 10,
        active: false,
        verify: :verify_peer,
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      Keyword.fetch!(config, :tls_options)
    )
    |> TLS.client_options()
  end
end
