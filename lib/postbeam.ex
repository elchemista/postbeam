defmodule Postbeam do
  @moduledoc """
  Synchronous email delivery directly to a recipient's MX servers.

      Postbeam.deliver(
        from: "hello@example.com",
        to: "recipient@example.net",
        subject: "Hello",
        text: "Sent directly through SMTP."
      )

  Accepts a keyword list or map with `:from`, `:to`, `:subject`, and at least one
  of `:text` / `:html`. Each call sends to one recipient. Options override the
  `:postbeam` application environment; see `Postbeam.Config` for defaults.

  Success means SMTP acceptance, not inbox placement. Never blindly retry
  `{:error, {:uncertain, details}}`: the server may already have the message.
  Both terminal SMTP errors and exhausted attempts include the Message-ID.

  Implement `Postbeam.MX` or `Postbeam.SMTP` to replace DNS or transport without
  changing callers, message encoding, or the MX fallback policy.
  """

  alias Postbeam.Config
  alias Postbeam.Delivery
  alias Postbeam.DKIM
  alias Postbeam.Message
  alias Postbeam.MX

  @typedoc "Receipt returned only after the recipient server accepts DATA."
  @type receipt :: %{
          required(:to) => String.t(),
          required(:mx) => String.t(),
          required(:receipt) => binary(),
          required(:message_id) => String.t()
        }

  @type attempt :: %{mx: String.t(), reason: term()}
  @type exhausted :: %{to: String.t(), message_id: String.t(), attempts: [attempt()]}
  @type failure_details :: %{
          to: String.t(),
          mx: String.t(),
          message_id: String.t(),
          reason: term(),
          attempts: [attempt()]
        }
  @typedoc "DNS details and adapter-specific reasons are retained inside structured errors."
  @type error ::
          Config.error()
          | Message.validation_error()
          | Message.composition_error()
          | DKIM.error()
          | MX.routing_error()
          | {:exhausted, exhausted()}
          | {:permanent | :uncertain, failure_details()}
  @type result :: {:ok, receipt()} | {:error, error()}

  @typedoc "Accepted receipts for an email delivered to multiple recipients."
  @type delivery_summary :: %{message_id: String.t(), deliveries: [receipt()]}
  @type delivery_failure :: %{to: String.t(), reason: error()}
  @typedoc "Per-recipient outcomes, including any accepted deliveries before failures."
  @type delivery_failed :: %{
          message_id: String.t(),
          deliveries: [receipt()],
          failures: [delivery_failure()]
        }
  @type delivery_result ::
          {:ok, delivery_summary()}
          | {:error, Message.composition_error() | {:delivery_failed, delivery_failed()}}

  @doc """
  Validates, routes, composes and synchronously sends one email.

  Options are documented in `Postbeam.Config` and `docs/configuration.md`. No external action
  happens for invalid input. MIME is composed once after resolving MX records,
  then reused for every address/host attempt. SMTP errors include the Message-ID
  for diagnostics. An explicit temporary rejection permits fallback; permanent
  envelope/message rejections and uncertain acceptance stop immediately.

  Each call sends a new message, even with identical input. Background jobs,
  persistence and delayed retries belong to the consuming application. Each DNS query/IP attempt has
  its own timeout, so total elapsed time depends on the number of destinations.
  DNS/transport adapter exceptions propagate. Key store exceptions are sanitized.
  Managed DKIM keys use the configured `:key_store`.

      iex> Postbeam.deliver(from: "invalid", to: "a@example.net", subject: "", text: "")
      {:error, {:invalid, :from}}
  """
  @spec deliver(Message.input(), Config.t()) :: result()
  def deliver(input, options \\ []) do
    with {:ok, config} <- Config.new(options),
         {:ok, message} <- Message.new(input),
         {:ok, hosts} <- MX.resolve(message.domain, config),
         {:ok, message} <- Message.encode(message, config) do
      Delivery.attempt(hosts, message, config, [])
    end
  end
end
