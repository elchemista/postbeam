# Native SMTP engine

Postbeam includes the Elixir implementation from `gen_smtp` directly in its
source tree. The engine is built and started as part of the `:postbeam`
application; no `:gen_smtp` dependency or application is required.

The regular APIs remain `Postbeam.deliver/2`, `Postbeam.Swoosh.Adapter` and
`Postbeam.Inbound`. They use the modules below internally.

| Module | Responsibility |
| --- | --- |
| `Postbeam.SMTP` | Direct-to-MX transport contract, deadlines and failure classification |
| `Postbeam.SMTP.Client` | SMTP/LMTP connections, AUTH, STARTTLS and delivery |
| `Postbeam.SMTP.Server` | Supervised Ranch listeners |
| `Postbeam.SMTP.Handler` | Callbacks for custom SMTP/LMTP handlers |
| `Postbeam.SMTP.Session` | Per-connection protocol process |
| `Postbeam.SMTP.MIME` | MIME encoding/decoding, multipart bodies and attachments |
| `Postbeam.SMTP.DKIM` | RSA/Ed25519 signing and canonicalization |
| `Postbeam.SMTP.Socket` | TCP/TLS socket operations |
| `Postbeam.SMTP.Util` | Address parsing, dates, MX lookup and protocol helpers |
| `Postbeam.SMTP.Binary` | Byte-oriented string utilities |

`Postbeam.DKIM` continues to manage signing keys and DNS record generation.

## Low-level client

Use the client directly when your application owns the SMTP envelope and
already has the complete MIME bytes:

```elixir
Postbeam.SMTP.Client.send_blocking(
  {"sender@example.com", ["recipient@example.net"], mime_bytes},
  relay: "smtp.example.com",
  hostname: "mail.example.com",
  port: 587,
  tls: :always,
  auth: :always,
  username: "sender@example.com",
  password: password
)
```

`send_blocking/2` returns a receipt binary or an error tuple. `open/1`,
`deliver/2` and `close/1` support reusable connections. `send_async/2,3` starts
an unlinked supervised delivery; `send/2,3` links the delivery to its caller.
`send_many/3` returns a stream and accepts `:max_concurrency` and `:timeout`.
These low-level operations have their own options and return contracts; the
deadlines and retry classification documented for `Postbeam.deliver/2` apply
to the high-level API.

## MIME decoding

```elixir
{type, subtype, headers, parameters, body} =
  Postbeam.SMTP.MIME.decode(raw_message, encoding: :raw)
```

The tuple format is also accepted by `Postbeam.SMTP.MIME.encode/1,2`.
`:raw` decodes transfer encodings while retaining charset bytes. The legacy
`:none` mode strips non-ASCII bytes before decoding transfer encodings.
Charset conversion to a requested encoding uses the optional `:eiconv`
dependency. Without it, default decoding uses `:raw`.

## Supervision and configuration

Starting `:postbeam` starts `Postbeam.SMTP.ClientSupervisor` for asynchronous
client deliveries and `Postbeam.SMTP.DataSupervisor` for incoming DATA readers.
Listeners start only when explicitly added to a supervision tree.

Configure the asynchronous client task limit before application startup:

```elixir
config :postbeam, :max_outbound_connections, 1024
```

For custom protocol handlers, implement `Postbeam.SMTP.Handler` and supervise
`{Postbeam.SMTP.Server, {MyHandler, options}}`. `Postbeam.SMTP.Example`
demonstrates the callback contract; use `Postbeam.Inbound` for the supported
application-owned recipient and message handling interface.

## Build and provenance

Ranch remains the listener dependency. OTP provides TCP, TLS and cryptography;
the optional `eiconv` package provides charset conversion. Three included
RFC parser/scanner grammars are compiled by Mix's standard Yecc/Leex compilers
into private `:postbeam_smtp_*` modules. Protocol and MIME logic lives in Elixir.

Upstream compatibility wrappers are replaced by direct native module calls.
The imported ExUnit, EUnit and PropEr regression suites and fixtures live in
`test/smtp` and run with `mix test`. PropEr and EUnit are only used for tests.
See `NOTICE` and `licenses/` for the retained upstream attribution and licenses.
