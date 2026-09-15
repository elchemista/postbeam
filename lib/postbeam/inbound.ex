defmodule Postbeam.Inbound do
  @moduledoc """
  Opt-in SMTP reception with application-owned handling and no message storage.

  Implement both callbacks, then add a listener to your supervision tree:

      {Postbeam.Inbound,
       adapter: {MyApp.IncomingMail, api_url: "https://api.example.com/mail"},
       hostname: "mx.example.com",
       address: {0, 0, 0, 0},
       port: 25}

  `accept_recipient/2` decides which envelope recipients to accept.
  `handle_message/2` receives the complete raw MIME message once per SMTP
  transaction, with all accepted recipients. It can call an API, store data,
  enqueue work or apply any other application policy.

  Callbacks run synchronously in each SMTP session. Only `:ok` confirms
  acceptance. Return a temporary error to ask the sender to retry, or a
  permanent error to reject the recipient/message. Unexpected return values,
  exceptions, throws and exits produce a generic temporary failure; exception
  details are not sent to the peer. Adapters own their I/O deadlines and must
  account for retries, including a lost SMTP reply after a successful handoff.

  No listener starts automatically. Receiving options are passed directly to
  this module, independently of outbound `:postbeam` application settings.
  See `docs/inbound.md` for setup, callback examples and delivery guarantees.
  """

  alias Postbeam.SMTP.Server

  alias Postbeam.Config
  alias Postbeam.Inbound.Message
  alias Postbeam.Inbound.Session

  @type adapter :: module() | {module(), keyword()}
  @typedoc "Error text is public: it is sent to the SMTP peer without an SMTP code."
  @type result :: :ok | {:error, {:temporary | :permanent, String.t()}}
  @type option ::
          {:adapter, adapter()}
          | {:name, term()}
          | {:hostname, String.t()}
          | {:address, :inet.ip_address()}
          | {:port, 0..65_535}
          | {:max_size, pos_integer()}
          | {:tls_options, keyword()}

  @doc """
  Accepts or rejects one SMTP envelope recipient before its message is read.

  Accept only addresses your application handles. This callback is mandatory;
  there is no default catch-all or automatic forwarding. Options come from the
  configured `{Adapter, options}` tuple (or `[]` for a module alone).
  """
  @callback accept_recipient(String.t(), keyword()) :: result()

  @doc """
  Handles a complete message for every accepted recipient in `message.to`.

  Return `:ok` only when your application has taken responsibility for it.
  SMTP has one final response for all recipients: partial side effects followed
  by a temporary error can be repeated when the sender retries.
  """
  @callback handle_message(Message.t(), keyword()) :: result()

  @defaults [
    name: __MODULE__,
    hostname: "localhost",
    address: {127, 0, 0, 1},
    port: 2525,
    max_size: 10_485_760,
    tls_options: []
  ]

  @doc """
  Builds a supervised listener. Invalid options raise before opening a socket.

  `:adapter` is required. Defaults: loopback address, port 2525, hostname
  `localhost`, 10 MiB maximum message size, and no STARTTLS. Supply server
  certificate/key options in `:tls_options` to advertise STARTTLS. Give each
  listener a distinct `:name`; use port `0` to allocate an ephemeral port.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(options) do
    config = validate!(options)

    server_options = [
      domain: String.to_charlist(config[:hostname]),
      address: config[:address],
      family: if(tuple_size(config[:address]) == 8, do: :inet6, else: :inet),
      port: config[:port],
      sessionoptions: [callbackoptions: config, tls_options: config[:tls_options]]
    ]

    config[:name]
    |> Server.child_spec(Session, server_options)
    |> Supervisor.child_spec(id: {__MODULE__, config[:name]})
  end

  @doc "Starts a linked listener. Prefer adding `{Postbeam.Inbound, options}` to a supervisor."
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(options) do
    %{start: {module, function, arguments}} = child_spec(options)
    apply(module, function, arguments)
  end

  @spec validate!(term()) :: keyword()
  defp validate!(options) do
    case Config.keyword(options, :inbound) do
      {:ok, options} ->
        config = Keyword.merge(@defaults, options)

        if not Keyword.has_key?(config, :adapter), do: invalid!(:adapter)

        Enum.each(config, &validate_option!/1)

        config

      {:error, _} ->
        raise ArgumentError, "inbound options must be a keyword list without duplicate keys"
    end
  end

  @spec validate_option!({atom(), term()}) :: :ok
  defp validate_option!({key, value}) do
    if not valid?(key, value), do: invalid!(key)
    :ok
  end

  @spec valid?(atom(), term()) :: boolean()
  defp valid?(:adapter, {module, options}) when is_atom(module) do
    match?({:ok, _}, Config.keyword(options, :adapter)) and valid?(:adapter, module)
  end

  defp valid?(:adapter, module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :accept_recipient, 2) and
      function_exported?(module, :handle_message, 2)
  end

  defp valid?(:name, _), do: true
  defp valid?(:hostname, value), do: Config.domain?(value)
  defp valid?(:address, value), do: :inet.is_ip_address(value)
  defp valid?(:port, value), do: is_integer(value) and value in 0..65_535
  defp valid?(:max_size, value), do: is_integer(value) and value > 0
  defp valid?(:tls_options, value), do: match?({:ok, _}, Config.keyword(value, :tls_options))
  defp valid?(_, _), do: false

  @spec invalid!(atom()) :: no_return()
  defp invalid!(key), do: raise(ArgumentError, "invalid inbound option: #{key}")
end
