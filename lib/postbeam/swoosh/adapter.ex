if Code.ensure_loaded?(Swoosh.Adapter) and Code.ensure_loaded?(Swoosh.Email) do
  defmodule Postbeam.Swoosh.Adapter do
    @moduledoc """
    Delivers Swoosh emails directly to recipient MX servers using Postbeam.

        config :my_app, MyApp.Mailer,
          adapter: Postbeam.Swoosh.Adapter,
          postbeam: [hostname: "mta.example.com", tls: :always]

    Requires the optional `:swoosh` dependency. Supports text/HTML, display names,
    To/Cc/Bcc, Reply-To, custom headers and ordinary/inline attachments. SMTP
    mailboxes must be ASCII; use punycode for internationalized domains. Reserved
    header overrides, provider options and composite message/multipart attachments are
    unsupported and rejected before delivery. At least one body is required.

    Delivers sequentially, with one SMTP transaction per unique recipient.
    MIME, DKIM and Message-ID are shared across all recipients and MX attempts.
    Bcc addresses are never included in the transmitted headers.

    Returns `{:ok, %{message_id: id, deliveries: receipts}}` when all recipients
    accept, otherwise `{:error, {:delivery_failed, summary}}`. The failed summary
    includes `:message_id`, accepted `:deliveries` and `:failures`, each with `:to`
    and the original Postbeam `:reason`. Never retry the whole email after a
    partial result, or blindly retry an `:uncertain` failure. Acceptance does not
    mean inbox placement.

    Exceptions from custom transports propagate, possibly after prior deliveries.
    Background delivery belongs to the consuming application. `deliver_many/2`
    for batches of distinct emails is not implemented. See the Swoosh guide for
    configuration, supported fields, attachment limits and application examples.
    """

    @behaviour Swoosh.Adapter

    alias Postbeam.Delivery
    alias Postbeam.Swoosh.Config
    alias Postbeam.Swoosh.Message
    alias Swoosh.Email

    @doc "Delivers a composed email and reports acceptance separately for each recipient."
    @impl Swoosh.Adapter
    @spec deliver(Email.t(), keyword()) ::
            Postbeam.delivery_result()
            | {:error,
               Postbeam.Config.error()
               | Postbeam.Message.validation_error()
               | {:unsupported, :provider_options}}
    def deliver(%Email{} = email, config) do
      with {:ok, options} <- Config.new(config),
           {:ok, messages} <- Message.new(email) do
        Delivery.deliver_recipients(messages, options)
      end
    end

    @doc "Validates mailer options without network, file access or exposing their values."
    @impl Swoosh.Adapter
    @spec validate_config(keyword()) :: :ok | no_return()
    def validate_config(config) do
      case Config.new(config) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          raise ArgumentError, "invalid Postbeam mailer configuration: #{inspect(reason)}"
      end
    end
  end
end
