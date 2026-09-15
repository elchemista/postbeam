defmodule Postbeam.Inbound.Message do
  @moduledoc """
  An incoming SMTP envelope, raw message bytes and connection metadata.

  `from` and `to` come from SMTP MAIL FROM / RCPT TO, independently of the
  visible From/To/Cc headers. The null reverse path used for bounces is `""`.
  `to` contains only recipients accepted by the adapter, in SMTP order.

  `data` is the complete MIME binary after SMTP dot unescaping; it is not
  parsed, rewritten, signed or persisted. Headers, bodies and attachments are
  available to your own parser (for example `Postbeam.SMTP.MIME.decode/2`).

  `peer` is the remote IP address, `helo` is the client-supplied HELO/EHLO name,
  and `tls` indicates a successful STARTTLS upgrade. Sender addresses and
  HELO names are claims by the peer, not verified identities.
  """

  @enforce_keys [:from, :to, :data, :peer, :helo, :tls]
  defstruct [:from, :to, :data, :peer, :helo, :tls]

  @type t :: %__MODULE__{
          from: String.t(),
          to: [String.t(), ...],
          data: binary(),
          peer: :inet.ip_address(),
          helo: String.t(),
          tls: boolean()
        }
end
