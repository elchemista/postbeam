defmodule Postbeam.SentStore do
  @moduledoc """
  Optional archive of SMTP-accepted emails.

  Enable with `sent_store: Postbeam.SentStore.ETS` or `{MyStore, options}`.
  Implement `put/2` to persist an entry; database adapters may use Message-ID as
  an idempotent archive key. Query APIs belong to each adapter.

  Entries contain the encoded email, acceptance receipt and UTC timestamp, never
  delivery configuration, adapter credentials or private keys. Only SMTP success
  is archived. The delivery receipt gains `storage: :ok | {:error, reason}`;
  storage failure NEVER changes SMTP success into a delivery error. Exceptions
  and exits are sanitized. Return safe error reasons yourself.

  Archiving is synchronous and best effort, not a transactional outbox. A process
  crash between SMTP acceptance and `put/2` can leave no archive entry. An archive
  timeout can still complete later. Do not resend an email to retry archiving.
  """
  alias Postbeam.{Message, Store}

  @type adapter :: module() | {module(), keyword()}
  @type entry :: %{
          message: Message.encoded(),
          receipt: Postbeam.receipt(),
          accepted_at: DateTime.t()
        }
  @doc "Archives one accepted message. Return safe errors without raising or leaking secrets."
  @callback put(entry(), keyword()) :: :ok | {:error, term()}

  @doc false
  @spec record(adapter() | nil, Message.encoded(), Postbeam.receipt()) :: Postbeam.receipt()
  def record(nil, _message, receipt), do: receipt

  def record(store, message, receipt) do
    entry = %{message: message, receipt: receipt, accepted_at: DateTime.utc_now()}

    status =
      case Store.call(store, :put, [entry]) do
        :ok -> :ok
        {:error, _} = error -> error
        _ -> {:error, :invalid_store_response}
      end

    Map.put(receipt, :storage, status)
  end
end
