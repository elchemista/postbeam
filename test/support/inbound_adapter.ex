defmodule Postbeam.TestInboundAdapter do
  @moduledoc false
  @behaviour Postbeam.Inbound

  @impl true
  def accept_recipient(to, options) do
    notify(options, {:recipient, to})

    if String.ends_with?(String.downcase(to), "@example.net"),
      do: outcome(Keyword.get(options, :recipient_result, :ok)),
      else: {:error, {:permanent, "Unknown recipient"}}
  end

  @impl true
  def handle_message(message, options) do
    notify(options, {:message, message})

    if options[:wait] do
      receive do
        :continue -> :ok
      after
        2_000 -> raise "adapter was not released"
      end
    end

    outcome(Keyword.get(options, :message_result, :ok))
  end

  defp notify(options, event) do
    if owner = options[:owner], do: send(owner, {:inbound, self(), event})
  end

  defp outcome(:raise), do: raise("PRIVATE adapter details")
  defp outcome(:throw), do: throw("PRIVATE adapter details")
  defp outcome(:exit), do: exit("PRIVATE adapter details")
  defp outcome(result), do: result
end
