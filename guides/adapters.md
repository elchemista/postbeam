# Architecture and adapter contracts

Postbeam keeps delivery policy in `Postbeam`, composition in `Postbeam.Message`,
and external I/O in `Postbeam.MX` and `Postbeam.SMTP`. `Postbeam.Config` validates
and merges options. The default I/O modules also declare their own behaviours,
so a replacement can delegate to them without introducing another wrapper layer.

## Message lifecycle

1. `Postbeam.Config.new/1` merges library, application and call options in that order.
2. `Postbeam.Message.new/1` validates fields and normalizes mailbox domains without I/O.
3. `Postbeam.MX.resolve/2` selects recipient MX hostnames in priority order.
4. `Postbeam.Message.encode/2` produces MIME bytes, a random Message-ID and optional DKIM.
5. The orchestrator calls `transport.deliver/3` for each candidate until accepted
   or a terminal result occurs.

`t:Postbeam.Message.t/0` describes validated messages; `t:Postbeam.Message.encoded/0` guarantees binary
`data` and `message_id` fields. Transports receive the encoded type. They must
send the supplied bytes without rewriting headers or bodies, especially after
DKIM signing. Encoding again creates a new Message-ID. An independent `deliver`
call also creates a new message, even if every caller-provided field is identical.

A successful receipt reports SMTP acceptance. Postbeam does not infer inbox
placement, later bounces or spam classification from that receipt.

## DNS adapters

Implement `Postbeam.MX.lookup/3`:

```elixir
defmodule MyApp.DNS do
  @behaviour Postbeam.MX

  @impl true
  @spec lookup(String.t(), Postbeam.MX.record_type(), Postbeam.Config.t()) ::
          Postbeam.MX.lookup_result()
  def lookup(domain, type, options) do
    Postbeam.MX.lookup(domain, type, options)
  end
end
```

Use `resolver: MyApp.DNS`. The callback receives a hostname, `:mx`, `:a` or
`:aaaa`, and merged options. It returns:

| Query | Successful records |
| --- | --- |
| MX | `[{10, "mx.example.net"}, {20, ~c"backup.example.net"}]` |
| A | `[{192, 0, 2, 1}]` |
| AAAA | `[{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}]` |

Wrap records in `{:ok, records}`; return `{:error, reason}` for DNS failures.
An empty successful list **must mean NODATA**. It must never hide NXDOMAIN,
SERVFAIL or timeout: doing so would incorrectly enable implicit MX delivery.
A sole `{0, "."}` (or the empty-root representation returned by OTP) means Null
MX. Mixed Null MX and regular records are rejected as an invalid MX set.

Custom resolvers own their deadlines and any caching lifecycle. Honor
`dns_timeout`. A cache should respect DNS TTLs and distinguish positive records,
negative answers and transient lookup failures. The default adapter exposes
`dns_options` for OTP resolver options such as private nameservers.

A/AAAA resolution is deferred until a host is attempted. Both families are
queried; working addresses from either family are usable. Each query has a
separate timeout. With no usable addresses, both results are kept for debugging.

## Transport adapters

Implement `Postbeam.SMTP.deliver/3`:

```elixir
defmodule MyApp.Transport do
  @behaviour Postbeam.SMTP

  @impl true
  @spec deliver(String.t(), Postbeam.Message.encoded(), Postbeam.Config.t()) ::
          Postbeam.SMTP.result()
  def deliver(mx, message, options) do
    Postbeam.SMTP.deliver(mx, message, options)
  end
end
```

Use `transport: MyApp.Transport`. Return `{:ok, receipt}` or
`{:error, {classification, reason}}`. Classification determines orchestration:

| Classification | Meaning | Next MX? |
| --- | --- | --- |
| `:retry` | Connection/session failure or explicit temporary rejection | Yes |
| `:permanent` | Definitive sender, recipient or message rejection | No |
| `:uncertain` | The message may have been accepted | No |

A custom transport owns address selection, network deadlines, socket cleanup,
and its acceptance boundary. Never turn an ambiguous disconnect into `:retry`.
Adapter exceptions propagate; programming errors should not masquerade as
recipient rejection. Only the default SMTP adapter catches dependency crashes
at its isolated protocol boundary, where it retains the failure and phase.

## Default SMTP lifecycle

Each IP attempt runs in a monitored process. It owns the socket and a kill timer;
exiting releases TCP/TLS resources, including failures during connection setup.
The timer also limits socket lifetime if the caller dies. No supervisor, pool
or persistent worker is required by the library.

The worker reports envelope and DATA phases in order. `gen_smtp` evaluates the
body callback just before sending DATA, so this is the earliest conservative
acceptance-uncertainty boundary. A disconnect before 354 can therefore also
produce `:uncertain`. Explicit 4xx/5xx responses still determine retryability.
A received acceptance is not replaced by a subsequent QUIT/cleanup failure.

`connect_timeout` bounds TCP connect/send; `smtp_timeout` bounds the complete
IP attempt, including greeting, TLS and SMTP replies. `dns_timeout` is separate.
Several MX hosts, addresses and DNS queries can extend total call duration.

## Configuration and future extensions

Unknown top-level options, duplicate keyword keys and header injection are
validation errors. Nested `dkim`, `tls_options` and `dns_options` are replaced
as whole values when overridden. Error values avoid including configuration or
private-key contents. SMTP errors carry a Message-ID for correlation.

TLS defaults to opportunistic STARTTLS with certificate/hostname verification;
use `tls: :always` to require encryption. Optional TLS can fall back to plaintext.
Direct MX delivery always disables SMTP authentication and implicit TLS.

Future queues can persist job state and recorded delivery results around the
public API. Pooling can live in a transport implementation. Caching can live in
a resolver. These additions still need explicit lifecycle and duplicate-delivery
policies: the current API is synchronous and does not promise durable or
exactly-once delivery. Attachments, multiple recipients and SMTPUTF8 require
further message/envelope API design and are outside this MVP.
