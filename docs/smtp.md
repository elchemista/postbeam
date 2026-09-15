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

## Internal responsibilities

The public entry points delegate to smaller modules with explicit contracts:

- `Client.Authentication`, `Client.Reply` and `Client.Transaction` handle AUTH,
  response framing and envelope/DATA delivery.
- `Session.Address`, `Session.Transaction`, `Session.Response` and
  `Session.DataReader` handle address syntax, MAIL/RCPT, transport failures and
  streaming DATA respectively.
- `MIME.EncodedWord`, `MIME.Parameters` and `MIME.TransferEncoding` own header
  encoding, parameter continuations and base64/quoted-printable bodies.
- Postbeam.Validation shares validation and fail-fast list conversion between
  message construction, Swoosh conversion and attachment loading.

These helper modules are internal. Applications should use the public APIs
listed above. The source follows `SKILL.md` and `GUIDELINE.md`; production
functions have specs and public functions have documentation attributes.

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
See the README for the engine's origin and `LICENSE` for Postbeam's license.

## Run the complete SMTP tests

From the Postbeam checkout:

```sh
mix deps.get
mix test.smtp --trace
```

This runs every imported test in `test/smtp`, plus Postbeam's outbound transport
and inbound adapter integration tests. It starts local TCP/TLS listeners and
uses the bundled certificates and MIME fixtures; `../gen_smtp` is not needed.
The SMTP aliases select `MIX_ENV=test` automatically.

The import includes all seven original ExUnit suites, eight Erlang test/property
modules, 44 unchanged fixtures, the test handler and the certificate generation
script. The original test helper is merged into `test/test_helper.exs` so the
Erlang suites are compiled and loaded before ExUnit runs.

| Tests | Coverage |
| --- | --- |
| `legacy_test.exs` | All six original EUnit suites: client, server, sessions, TCP/TLS sockets, MIME/DKIM and address utilities |
| `otp_test.exs` | Concurrent deliveries, supervision, cleanup, STARTTLS, certificate verification and malformed replies |
| `session_response_test.exs` | Callback state and failure handling when sending responses or changing socket options |
| `data_reader_test.exs` | DATA framing across packet boundaries, empty messages, newline policies and size limits |
| `mime_test.exs`, `binary_test.exs`, `util_test.exs` | Charset handling, byte operations and RFC parsing |
| `properties_test.exs` | All 11 PropEr properties for generated MIME messages and RFC address lists |
| `integration_test.exs` | Native application ownership and independence from `gen_smtp` |

ExUnit counts each EUnit suite as one test; the individual EUnit results appear
in the verbose output. The final ExUnit count therefore does not include all
individual assertions and generated cases.

For a longer property run, increase the number of generated cases per property
(the default is 200):

```sh
SMTP_PROPERTY_CASES=2000 mix test.smtp.properties --trace
```

Run all Postbeam tests and measure coverage with:

```sh
mix test --cover
```

The existing CI runs this complete suite on both supported Elixir/OTP matrix
entries. Avoid simultaneous suite runs in the same environment because some
of the original EUnit tests bind fixed local ports.
