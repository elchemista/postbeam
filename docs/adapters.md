# Custom adapters

Postbeam handles validation, MIME, DKIM and MX fallback. Replace external I/O with
`resolver: MyApp.DNS` or `transport: MyApp.Transport` when needed.

## DNS

```elixir
defmodule MyApp.DNS do
  @behaviour Postbeam.MX

  @impl Postbeam.MX
  def lookup(domain, type, options) do
    Postbeam.MX.lookup(domain, type, options)
  end
end
```

`lookup/3` receives a hostname, `:mx`, `:a` or `:aaaa`, and merged delivery options.
Return `{:ok, records}` or `{:error, reason}`:

- MX records: `[{10, "mx.example.net"}, {20, "backup.example.net"}]`.
- A records: `[{192, 0, 2, 1}]`.
- AAAA records: `[{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}]`.

An empty successful result must mean NODATA. Never convert NXDOMAIN, SERVFAIL or
timeouts to `{:ok, []}`: this would incorrectly enable implicit MX fallback.
A sole `{0, "."}` means Null MX and rejects delivery. Honor `dns_timeout`.

## SMTP

```elixir
defmodule MyApp.Transport do
  @behaviour Postbeam.SMTP

  @impl Postbeam.SMTP
  def deliver(mx, message, options) do
    Postbeam.SMTP.deliver(mx, message, options)
  end
end
```

`deliver/3` receives an MX hostname, an encoded `Postbeam.Message` and merged
options. Send `message.data` unchanged: its MIME and DKIM are already complete.
The SMTP envelope uses `message.from` and `message.to`, which may differ from
visible To/Cc headers.

Return `{:ok, receipt}` or `{:error, {classification, reason}}`:

| Classification | Meaning | Try another MX? |
| --- | --- | --- |
| `:retry` | Temporary rejection or connection failure before uncertain acceptance | Yes |
| `:permanent` | Definitive sender, recipient or message rejection | No |
| `:uncertain` | The server may already have accepted the message | No |

Custom transports own address resolution, deadlines and socket cleanup.
Exceptions propagate. Never classify an ambiguous disconnect as safe to retry.
The default transport uses the built-in `Postbeam.SMTP.Client`, with a monitored
process and a hard deadline for each IP attempt.

## Incoming email

Implement `Postbeam.Inbound` to choose accepted recipients and handle complete
incoming messages. Its `accept_recipient/2` and `handle_message/2` callbacks
receive your adapter options. There is no default message store or forwarding
destination: the application owns every side effect and the acceptance decision.
See [receiving email](inbound.md) for a complete example and SMTP error semantics.
