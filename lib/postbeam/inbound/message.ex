defmodule Postbeam.Inbound.Message do
  @moduledoc """
  An incoming SMTP envelope, raw message bytes, optional decoded MIME and connection metadata.

  `from` and `to` come from SMTP MAIL FROM / RCPT TO, independently of the
  visible From/To/Cc headers. The null reverse path used for bounces is `""`.
  `to` contains only recipients accepted by the adapter, in SMTP order.

  `data` is the complete MIME binary after SMTP dot unescaping and the configured
  newline policy. It remains available when decoding is enabled.

  `decoded` is `nil` by default. With the listener option `decode: true`, it is
  the `{type, subtype, headers, parameters, body}` tuple returned by
  `Postbeam.SMTP.MIME.decode/1`. Multipart bodies contain a list of child tuples;
  attached RFC822 messages contain a nested tuple. Nothing is persisted.

  If automatic decoding fails, `decoded` remains `nil` and `decode_error` is
  `:invalid_mime`. The adapter still receives `data` and decides whether to
  accept or reject it. `decode_error` is `nil` when decoding is disabled or
  succeeds.

  `peer` is the remote IP address, `helo` is the client-supplied HELO/EHLO name,
  and `tls` indicates a successful STARTTLS upgrade. Sender addresses and
  HELO names are claims by the peer, not verified identities.
  """

  alias Postbeam.SMTP.MIME

  @enforce_keys [:from, :to, :data, :peer, :helo, :tls]
  defstruct [:from, :to, :data, :peer, :helo, :tls, :decoded, :decode_error]

  @type t :: %__MODULE__{
          from: String.t(),
          to: [String.t(), ...],
          data: binary(),
          decoded: MIME.mimetuple() | nil,
          decode_error: :invalid_mime | nil,
          peer: :inet.ip_address(),
          helo: String.t(),
          tls: boolean()
        }

  @doc """
  Decodes the MIME bytes and returns a message with `decoded` populated.

  Preserves `data` and the SMTP envelope. Returns `{:error, :invalid_mime}` if
  parsing fails, without exposing message content or parser exception details.
  Uses the default decoding behavior of `Postbeam.SMTP.MIME.decode/1`.
  """
  @spec decode(t()) :: {:ok, t()} | {:error, :invalid_mime}
  def decode(%__MODULE__{} = message) do
    {:ok, %{message | decoded: MIME.decode(message.data), decode_error: nil}}
  rescue
    _ -> {:error, :invalid_mime}
  catch
    _, _ -> {:error, :invalid_mime}
  end
end
