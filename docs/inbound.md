# Receive email

Postbeam can listen for incoming SMTP messages and hand them to your application.
It does not store messages, create mailboxes or choose an API/database for you.
The listener uses the built-in `Postbeam.SMTP.Server` and starts only when you
add it to your supervision tree.

## Implement an adapter

Both callbacks are required. This example injects an application function so
the handling policy can be configured independently of the listener:

```elixir
defmodule MyApp.IncomingMail do
  @behaviour Postbeam.Inbound

  @impl true
  def accept_recipient(address, options) do
    domain = address |> String.split("@") |> List.last() |> String.downcase()

    if domain in Keyword.fetch!(options, :domains) do
      :ok
    else
      {:error, {:permanent, "Unknown recipient"}}
    end
  end

  @impl true
  def handle_message(message, options) do
    handler = Keyword.fetch!(options, :handler)
    handler.(message)
  end
end
```

`accept_recipient/2` runs for each SMTP `RCPT TO` command before Postbeam reads
the message. Replace the domain check with your own recipient or tenant lookup
if needed. It may also return a temporary error if that lookup is unavailable.

`handle_message/2` runs once after the entire message has arrived. Your handler
can call an API, write to your repository, enqueue work, or invoke another
application service. It must return the callback results described below.
Both callbacks receive the keyword list in `{MyApp.IncomingMail, options}`.
Using `adapter: MyApp.IncomingMail` passes `[]` instead.

## Add the listener

In your application's `start/2`, after any services used by the adapter:

```elixir
children = [
  {Postbeam.Inbound,
   name: MyApp.IncomingSMTP,
   hostname: "mx.example.com",
   address: {0, 0, 0, 0},
   port: 25,
   adapter: {MyApp.IncomingMail,
     domains: ["example.com"],
     handler: &MyApp.MailPipeline.handle/1}}
]

Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

Implement `MyApp.MailPipeline.handle/1` in your application to perform the API,
database or other handoff. Return `:ok` only after that operation succeeds.
There is no automatic forwarding, persistence or deferred retry inside Postbeam.
Multiple listeners can use different adapters/options with distinct `:name`
values and listening ports/addresses.

Receiving options are explicit listener options; they do not use or change the
outgoing `config :postbeam` settings.

| Option | Default | Meaning |
| --- | --- | --- |
| `:adapter` | Required | Module or `{module, keyword_options}` implementing both callbacks |
| `:name` | `Postbeam.Inbound` | Unique listener and supervision identity |
| `:hostname` | `"localhost"` | Hostname in the SMTP greeting |
| `:address` | `{127, 0, 0, 1}` | Local IPv4 or IPv6 bind address |
| `:port` | `2525` | SMTP port; `0` selects an ephemeral port |
| `:max_size` | `10_485_760` | Maximum incoming message size in bytes, for both HELO and EHLO |
| `:tls_options` | `[]` | TLS server options; nonempty options enable STARTTLS advertisement |

Unknown options, duplicate keys, invalid values and missing callbacks are
rejected before opening a socket. No listener is started by simply adding the
library dependency. `Postbeam.Inbound.start_link/1` is also available for a
manually managed linked listener.

## Message fields

The handler receives a `%Postbeam.Inbound.Message{}`:

| Field | Content |
| --- | --- |
| `:from` | SMTP envelope sender; `""` for a bounce/null reverse path |
| `:to` | All accepted envelope recipients, in SMTP order |
| `:data` | Complete raw MIME binary after SMTP dot unescaping |
| `:peer` | Connecting client's IP address |
| `:helo` | Client's HELO/EHLO name |
| `:tls` | Whether this connection successfully upgraded using STARTTLS |

Use the envelope recipients to route messages, including blind recipients.
Visible From/To/Cc headers can differ from the envelope and are not used to
select destinations. Postbeam preserves the MIME bytes, including headers,
bodies and attachments; it does not decode or rewrite them. If your application
needs parsed parts, use the built-in MIME codec:

```elixir
{type, subtype, headers, parameters, body} =
  Postbeam.SMTP.MIME.decode(message.data, encoding: :none)
```

Handle parsing failures in your adapter. SMTPUTF8 is not advertised; envelope
addresses use ASCII, while MIME headers and bodies can contain Unicode.
Postbeam does not authenticate inbound sender identities or verify SPF/DKIM/DMARC;
any such policy belongs to your receiving infrastructure or adapter.

## Acceptance and failure

| Callback result | SMTP response | Sender behavior |
| --- | --- | --- |
| `:ok` | `250` | Recipient/message accepted |
| `{:error, {:temporary, "Service unavailable"}}` | `451` | Sender can retry later |
| `{:error, {:permanent, "Unknown recipient"}}` | `550` | Recipient/message rejected |

Error text is sent to the SMTP peer. Use a nonempty single line of at most 400
bytes without control characters. Invalid returns, invalid error text, raised
exceptions, throws and exits become a generic `451`; private exception details
are not included in the response.

Callbacks run synchronously in the connection process, with separate processes
for concurrent connections. Bound the time spent calling external services in
your adapter. A `250` after DATA is sent only after `handle_message/2` returns
`:ok`: your application has then taken responsibility for the email. A handler
that only starts untracked asynchronous work can lose the message after acceptance.

SMTP gives one final response for the entire recipient list. If your handler
performs work for some recipients and then returns a temporary failure, a retry
may repeat that work. A disconnect after a successful handoff can also cause a
retry. Design your handler's side effects to tolerate duplicates; Postbeam does
not add storage or deduplication. Interrupted/incomplete DATA is never handed
to `handle_message/2`.

## Network and STARTTLS

For local development, the loopback/2525 defaults need no DNS changes. To
receive public internet mail, configure your receiving domain's MX to the
listener hostname, give that hostname the appropriate A/AAAA records, and route
inbound TCP port 25 to the listener. Account for your host's port binding and
network restrictions. Receiving DNS is independent of outbound DKIM setup.

Supply a server certificate and its key to offer STARTTLS:

```elixir
tls_options: [
  certfile: ~c"/etc/mail/fullchain.pem",
  keyfile: ~c"/etc/mail/privkey.pem",
  versions: [:"tlsv1.2", :"tlsv1.3"]
]
```

STARTTLS is optional for the SMTP peer. The listener does not advertise SMTP
AUTH or provide an IMAP/POP3 mailbox service. The adapter chooses accepted
recipients and all subsequent handling.
