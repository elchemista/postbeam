defmodule Postbeam.Delivery do
  @moduledoc false

  alias Postbeam.Config
  alias Postbeam.Message
  alias Postbeam.MX

  @type summary :: Postbeam.delivery_summary()
  @type failure :: Postbeam.delivery_failure()
  @type failed :: Postbeam.delivery_failed()
  @type result :: Postbeam.delivery_result()

  @doc false
  @spec deliver_recipients([Message.t(), ...], Config.t()) :: result()
  def deliver_recipients([first | rest], config) do
    with {:ok, encoded} <- Message.encode(first, config) do
      {deliveries, failures} =
        Enum.reduce([first | rest], {[], []}, fn recipient, accumulated ->
          message = %{encoded | to: recipient.to, domain: recipient.domain}
          collect(deliver_encoded(message, config), message.to, accumulated)
        end)

      summarize(encoded.message_id, deliveries, failures)
    end
  end

  @doc false
  @spec deliver_encoded(Message.encoded(), Config.t()) :: Postbeam.result()
  def deliver_encoded(message, config) do
    with {:ok, hosts} <- MX.resolve(message.domain, config),
         do: attempt(hosts, message, config, [])
  end

  @spec collect(Postbeam.result(), String.t(), {[Postbeam.receipt()], [failure()]}) ::
          {[Postbeam.receipt()], [failure()]}
  defp collect({:ok, receipt}, _, {deliveries, failures}),
    do: {[receipt | deliveries], failures}

  defp collect({:error, reason}, to, {deliveries, failures}),
    do: {deliveries, [%{to: to, reason: reason} | failures]}

  @spec summarize(String.t(), [Postbeam.receipt()], [failure()]) ::
          {:ok, summary()} | {:error, {:delivery_failed, failed()}}
  defp summarize(id, deliveries, []),
    do: {:ok, %{message_id: id, deliveries: Enum.reverse(deliveries)}}

  defp summarize(id, deliveries, failures) do
    {:error,
     {:delivery_failed,
      %{
        message_id: id,
        deliveries: Enum.reverse(deliveries),
        failures: Enum.reverse(failures)
      }}}
  end

  @doc false
  @spec attempt([String.t()], Message.encoded(), Config.t(), [Postbeam.attempt()]) ::
          Postbeam.result()
  def attempt([], message, _, attempts) do
    {:error,
     {:exhausted,
      %{to: message.to, message_id: message.message_id, attempts: Enum.reverse(attempts)}}}
  end

  def attempt([host | rest], message, config, attempts) do
    transport = Keyword.fetch!(config, :transport)

    case transport.deliver(host, message, config) do
      {:ok, receipt} ->
        receipt = %{to: message.to, mx: host, receipt: receipt, message_id: message.message_id}
        {:ok, receipt}

      {:error, {:retry, reason}} ->
        attempt(rest, message, config, [%{mx: host, reason: reason} | attempts])

      {:error, {kind, reason}} when kind in [:permanent, :uncertain] ->
        {:error,
         {kind,
          %{
            to: message.to,
            mx: host,
            reason: reason,
            message_id: message.message_id,
            attempts: Enum.reverse(attempts)
          }}}
    end
  end
end
