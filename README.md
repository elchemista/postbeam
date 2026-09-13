# Postbeam

An Elixir library prototype for delivering email directly to the recipient's
MX servers, using Erlang/OTP DNS and `gen_smtp`.

```text
recipient → domain → MX lookup → try servers by priority → SMTP
```

Synchronous delivery to one recipient is implemented: text/HTML MIME, optional
DKIM, MX priority and failover, IPv4/IPv6, STARTTLS and bounded SMTP attempts.
Success is acceptance by the recipient's server; inbox placement is separate.

## Quick start

Requires Elixir 1.15+ and Erlang/OTP 26+. From this checkout:

```bash
mix deps.get
iex -S mix
```

```elixir
Postbeam.deliver(
  [from: "hello@example.com", to: "recipient@example.net",
   subject: "Hello", text: "Hello world!", html: "<p>Hello world!</p>"],
  hostname: "mta.example.com",
  tls: :always
)
# {:ok, %{to: "recipient@example.net", mx: "mx.example.net",
#         receipt: "queued ...\r\n", message_id: "<...@mta.example.com>"}}
```

Both keyword lists and maps with atom keys are accepted. `from`, `to`, `subject`
and at least one of `text` or `html` are required. Empty bodies and subjects are
valid. Addresses must be bare ASCII dot-atom mailboxes; display names, quoted
local parts, domain literals and SMTPUTF8 are outside this version. International
domain names must be supplied as punycode. Subjects and bodies support UTF-8.
Unknown fields/options, duplicate keyword keys and control characters in headers are rejected.

## Configuration

Pass options to `Postbeam.deliver/2` or configure application defaults:

```elixir
# config/config.exs in your application
import Config
config :postbeam,
  hostname: "mta.example.com",
  tls: :always,
  smtp_timeout: 60_000
```

| Option | Default | Meaning |
| --- | --- | --- |
| `hostname` | `"localhost"` | EHLO and Message-ID hostname; set your public FQDN in production |
| `tls` | `:if_available` | STARTTLS policy: `:always`, `:if_available`, `:never` |
| `tls_options` | `[]` | Overrides to OTP SSL options |
| `port` | `25` | SMTP destination port; override for local receivers |
| `connect_timeout` | `5_000` | TCP connection/send timeout in milliseconds |
| `smtp_timeout` | `60_000` | Hard total timeout per IP attempt, including greeting, TLS and DATA |
| `dns_timeout` | `5_000` | Timeout per DNS query in milliseconds |
| `dns_options` | `[]` | Options for `:inet_res.resolve/5`, e.g. private nameservers |
| `dkim` | `nil` | `:mimemail` signing options, shown below |
| `resolver` | `Postbeam.MX` | DNS adapter implementing `lookup/3` |
| `transport` | `Postbeam.SMTP` | Transport adapter implementing `deliver/3` |

Overrides merge at the top level; a supplied `dkim` or `tls_options` replaces
the corresponding application value. No authentication or submission relay is
used. TLS uses TLS 1.2/1.3, system CA roots and certificate hostname verification
against the MX hostname. `:if_available` permits plaintext if STARTTLS is absent;
`gen_smtp` can also fall back to plaintext after failed opportunistic negotiation.
Use `:always` to require encryption. CA/verification settings can be overridden
through `tls_options` for private SMTP servers.

Timeouts are finite per operation, not a single end-to-end delivery deadline:
multiple MX hosts, addresses and DNS queries can increase total elapsed time.
The application creates no persistent processes, queue or database.

## Results and retry policy

- `{:ok, %{to: ..., mx: ..., receipt: ..., message_id: ...}}`: server accepted DATA.
- `{:error, {:invalid, field}}` / `{:error, {:unknown_field, field}}`: invalid message.
- `{:error, {:invalid_config, key}}`: invalid or unknown option.
- `{:error, {:dns, domain, record_type, reason}}`: DNS failure, preserving OTP details.
- `{:error, {:null_mx, domain}}`: domain explicitly rejects email.
- `{:error, {:invalid_mx, domain, records}}`: malformed MX set, including mixed Null MX.
- `{:error, {:composition, kind}}`: MIME/signing failure; key material is never returned.
- `{:error, {:exhausted, %{to: ..., message_id: ..., attempts: [...]}}}`: all MX attempts failed.
- `{:error, {:permanent, details}}`: recipient, sender or message rejected; stop.
- `{:error, {:uncertain, details}}`: acceptance may have happened; stop without retry.

Terminal SMTP details contain `to`, `mx`, `message_id`, `reason` and prior
`attempts`. Exhausted attempts include host/address-level connection and DNS
errors. Connection/session failures and explicit temporary SMTP rejections try
the next address or MX; permanent envelope/message rejections stop immediately.
A `gen_smtp` body callback marks the start of DATA: network failures from that
point are conservatively uncertain, including failures before the body actually
leaves the socket. **Do not automatically retry uncertain results.** A fresh
`deliver` call is a new delivery with a new Message-ID, not an idempotent retry.

MX priorities are ascending and equal-priority hosts are shuffled. Only a
successful empty MX response activates implicit MX (the recipient domain's
A/AAAA records). NXDOMAIN, SERVFAIL and other DNS failures never activate this
fallback. Each MX tries IPv4 addresses followed by IPv6 addresses. The MIME
bytes and Message-ID stay identical for all attempts within one call.
See [SMTP routing](https://www.rfc-editor.org/rfc/rfc5321.html#section-5),
[Null MX](https://www.rfc-editor.org/rfc/rfc7505.html) and
[OTP DNS](https://www.erlang.org/doc/apps/kernel/inet_res.html).

## Extending the library

Keep callers on `Postbeam.deliver/1,2`. The default modules also declare the two
adapter behaviours, so caching resolvers or alternate transports can implement
them without changing delivery orchestration:

```elixir
defmodule MyDNS do
  @behaviour Postbeam.MX
  @impl true
  def lookup(domain, type, options), do: Postbeam.MX.lookup(domain, type, options)
end

defmodule MyTransport do
  @behaviour Postbeam.SMTP
  @impl true
  def deliver(mx, %Postbeam.Message{} = message, options),
    do: Postbeam.SMTP.deliver(mx, message, options)
end
```

DNS returns `{:ok, records}` or `{:error, reason}`; an empty successful list must
mean NODATA. MX records are `{priority, hostname}` tuples; A/AAAA records are IP
tuples. Honour `dns_timeout` in custom resolvers. Transports receive the MX
hostname, validated message with encoded `data` and `message_id`, and merged
options. Return `{:ok, receipt}` or `{:error, {classification, reason}}`, where
classification is `:retry`, `:permanent` or `:uncertain`. Custom transports own
their timeouts and must never classify ambiguous acceptance as retryable.
Adapter programming errors propagate so they can be fixed at their source.

Persistent queues, deferred retries/backoff, rate limiting, pooling, bounce
processing, attachments, multiple recipients, SMTPUTF8 and MTA-STS/DANE remain
future work outside this MVP.

## Manual sending example

Configure your own sender and test mailbox, then run:

```bash
export POSTBEAM_FROM='hello@example.com'
export POSTBEAM_TO='recipient@example.net'
export POSTBEAM_HOSTNAME='mta.example.com'
# Optional signing (all three settings required together):
export POSTBEAM_DKIM_DOMAIN='example.com'
export POSTBEAM_DKIM_SELECTOR='postbeam'
export POSTBEAM_DKIM_KEY='priv/keys/postbeam.pem'
mix run examples/send.exs
```

Optional variables: `POSTBEAM_SUBJECT`, `POSTBEAM_TEXT`, `POSTBEAM_HTML`,
`POSTBEAM_TLS` (defaults to `always` in the script), `POSTBEAM_CONNECT_TIMEOUT`,
`POSTBEAM_SMTP_TIMEOUT`, `POSTBEAM_DNS_TIMEOUT`. The script prints the result and
exits with status 1 on failure. It sends real mail; use a controlled sender.
The existing domain/server preparation guide follows.

## Local verification

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --cover --warnings-as-errors
mix dialyzer
mix docs --warnings-as-errors
```

The suite uses only local TCP/TLS/UDP receivers and in-process adapters: it
checks real DNS → SMTP delivery, IPv4/IPv6, certificate hostname verification,
MX failover, temporary/permanent/uncertain outcomes, deadlines, UTF-8 MIME and
cryptographic DKIM verification. It sends no external mail. Credo and Dialyxir
are development/test-only dependencies; ExDoc generates HTML/EPUB API reference.
Production retains `gen_smtp` as its only direct runtime dependency.

See the [adapter and architecture guide](guides/adapters.md) for callback contracts,
message lifecycle and extension points, and the [quality guide](guides/quality.md)
for tooling, coverage and test boundaries. Public types distinguish validated and
encoded messages and describe receipts, DNS errors and terminal SMTP outcomes.

External mailbox delivery has not been verified: sender domain, server hostname,
source IP/DNS and outbound port 25 still need to be configured.

## Namecheap DNS setup

Replace these example values with your own throughout this guide:

| Setting | Example value |
| --- | --- |
| Domain you control | `example.com` |
| Server's public outbound IPv4 address | `203.0.113.10` |
| SMTP / EHLO hostname | `mta.example.com` |
| Sender address | `hello@example.com` |
| DKIM selector | `postbeam` |
| First test recipient | `elchemista@gmail.com` |

`example.com` and `203.0.113.10` are placeholders. Use your domain and the actual
public IP used for outbound SMTP connections, including when the server is
behind NAT. Send from an address on your domain; use the Gmail address to receive
the test message.

### 1. Open the right DNS panel

In Namecheap, go to **Domain List → Manage** for your domain. Check **Nameservers**:

- For **Namecheap BasicDNS, PremiumDNS or FreeDNS**, use **Advanced DNS →
  Host Records → Add New Record**.
- For **Namecheap Web Hosting DNS**, use **cPanel → Zone Editor → Manage**.
- For another provider's nameservers, add the records at that provider.

The table below uses the **Advanced DNS** fields. Enter only the prefix in
**Host**: `mta`, `postbeam._domainkey`, `_dmarc`; `@` means the root domain.
Namecheap automatically appends `.example.com`. In cPanel, the Name field may
instead require the full name. The active nameservers determine where you manage
DNS, even if you registered the domain with Namecheap.
[Official Namecheap guide](https://www.namecheap.com/support/knowledgebase/article.aspx/317/2237/how-do-i-add-txtspfdkimdmarc-records-for-my-domain/).

### 2. Add the records

This is the initial setup for a domain that only sends through Postbeam.
If you already use email on this domain, also follow the notes below the table.

| Type | Host | Value | TTL |
| --- | --- | --- | --- |
| A Record | `mta` | `203.0.113.10` | Automatic |
| TXT Record — SPF | `@` | `v=spf1 ip4:203.0.113.10 -all` | Automatic |
| TXT Record — DKIM | `postbeam._domainkey` | `v=DKIM1; k=rsa; p=BASE64_PUBLIC_KEY` | Automatic |
| TXT Record — DMARC | `_dmarc` | `v=DMARC1; p=none` | Automatic |

Select **TXT Record** in the menu for all three SPF/DKIM/DMARC entries. Paste
the values without surrounding quotes and save your changes. Generate the full
DKIM value in step 3.

The A record maps `mta.example.com` to your server. You can keep the website's
records at `@` and `www`. If `mta` is already in use, choose an unused hostname
and use it consistently in the PTR and EHLO settings too.
[Namecheap A record setup](https://www.namecheap.com/support/knowledgebase/article.aspx/319/2237/how-can-i-set-up-an-a-address-record-for-my-domain/).

**Existing SPF:** each DNS name must have only one record starting with `v=spf1`.
Add `ip4:203.0.113.10` to your existing record, before its final `~all` or `-all`
mechanism, preserving the other authorized senders. For example, if you also send
through **Namecheap Private Email**:

```text
v=spf1 ip4:203.0.113.10 include:spf.privateemail.com ~all
```

The `include` is only needed if you use that service to send. With **Mail Settings →
Private Email**, Namecheap may manage an automatic SPF record that is not visible
in Host Records. Follow its consolidation procedure and check the result with
`dig`. [Consolidating SPF records on Namecheap](https://www.namecheap.com/support/knowledgebase/article.aspx/9736/2237/consolidating-several-spf-records-into-one/).

You can also add a TXT record at Host `mta` containing
`v=spf1 ip4:203.0.113.10 -all` for SPF checks on the EHLO identity. These are two
separate DNS names: `example.com` and `mta.example.com`.
[SPF and HELO/MAIL FROM identities](https://www.rfc-editor.org/rfc/rfc7208.html#section-2).

**DMARC:** `p=none` is an initial policy for observing authentication without
requesting quarantine or rejection through DMARC. To receive reports, add
`rua=mailto:dmarc@example.com` after creating that mailbox. If you already have
a DMARC policy, keep it and align the new sender with your existing configuration.
[DMARC setup](https://knowledge.workspace.google.com/admin/security/set-up-dmarc?hl=en).

### 3. Generate the DKIM key on the server

From the project directory, generate a 2048-bit RSA key once. The file check
prevents replacing a key that is already in use:

```bash
(
  umask 077
  mkdir -p priv/keys
  if [ ! -e priv/keys/postbeam.pem ]; then
    openssl genrsa -out priv/keys/postbeam.pem 2048
  fi
)
```

To get the complete value to paste into the DKIM TXT record:

```bash
openssl pkey -in priv/keys/postbeam.pem -pubout -outform DER |
  openssl base64 -A |
  awk '{ print "v=DKIM1; k=rsa; p=" $0 }'
```

Publish the entire output line under **Host `postbeam._domainkey`**.
The private key at `priv/keys/postbeam.pem` stays on the server and is excluded
from Git. Keep using the same key to sign messages; replacing it requires
updating DNS. [RSA key generation](https://docs.openssl.org/3.6/man1/openssl-genrsa/)
and [public key export](https://docs.openssl.org/3.6/man1/openssl-pkey/).

Namecheap's TXT field supports values long enough for this key.
[Namecheap TXT limits](https://www.namecheap.com/support/knowledgebase/article.aspx/10058/10/namecheap-dns-limits/).
If `dig` shows multiple quoted strings on one line, they are parts of the same
TXT record. Do not create separate DKIM records to split the key.
[DKIM TXT record format](https://www.rfc-editor.org/rfc/rfc6376.html#section-3.6.2.2).

DNS publishes the public key. Postbeam must also sign each message using the
private key with **`d=example.com`** and **`s=postbeam`**.
[DKIM in gen_smtp](https://github.com/gen-smtp/gen_smtp#dkim-signing-of-outgoing-emails).

### 4. Set up reverse DNS / PTR

The expected configuration is:

```text
mta.example.com  → A   → 203.0.113.10
203.0.113.10     → PTR → mta.example.com
Postbeam EHLO          → mta.example.com
```

Set the PTR through the provider that assigns your IP, using its server panel
or support team. Adding a PTR to your domain's ordinary DNS zone does not configure
reverse DNS for that IP.
[How PTR records work at Namecheap](https://www.namecheap.com/support/knowledgebase/article.aspx/10057/10/what-is-ptr-record/).

If your server is a **Namecheap VPS with SolusVM**:

1. Open SolusVM and select your VPS.
2. Go to **Network** and find the public IP.
3. Under **Reverse DNS**, click **Edit**.
4. Enter `mta.example.com` and click **Update**.

Namecheap estimates about 30–60 minutes for the update. If you have a dedicated
server or a different panel, ask support to set the PTR for your IP.
[Official SolusVM instructions, section 8](https://www.namecheap.com/support/knowledgebase/article.aspx/9974/48/how-to-manage-your-vps-with-solusvm-for-kvm/).

### 5. Keep your incoming mail MX records

The **recipient's** MX records tell Postbeam where to deliver. **Your domain's**
MX records determine where replies and delivery failure notifications are received.

You can send through Postbeam while keeping the MX records of your existing
mailbox provider. Use an existing mailbox or alias as the sender, such as
`hello@example.com`, so you can receive replies and bounces.

Do not point your MX records to `mta.example.com` just to enable sending: this
MVP does not provide an SMTP server that listens for incoming mail. If the domain
does not have incoming email yet, set up a mailbox and MX records according to
your chosen provider's instructions.
[The role of MX records](https://www.rfc-editor.org/rfc/rfc5321.html#section-5).

### 6. Check DNS and port 25

Run these checks after replacing the domain and IP. On Debian/Ubuntu, the tools
are available in the `dnsutils` and `netcat-openbsd` packages.

```bash
dig +short NS example.com
dig +short A mta.example.com
dig +short -x 203.0.113.10
dig +short TXT example.com
dig +short TXT postbeam._domainkey.example.com
dig +short TXT _dmarc.example.com
dig +short MX example.com
```

Check that A and PTR match, the domain has a single SPF record, DKIM contains
the public key you generated, and MX points to your incoming mail provider.
DNS caches may delay updates.

Then, **from the server that will run Postbeam**, look up the MX records and
test a connection to the first Gmail MX returned by DNS:

```bash
dig +short MX gmail.com
dig +short MX outlook.com

postbeam_mx=$(dig +short MX gmail.com | sort -n | awk 'NR == 1 { sub(/\.$/, "", $2); print $2 }')
if [ -n "$postbeam_mx" ]; then
  nc -4 -vz -w 5 "$postbeam_mx" 25
fi
```

This only checks whether a TCP connection can be opened. If it fails, check the
firewall, routing, and your provider's **outbound TCP port 25** access. Direct
delivery to MX servers uses port 25; port 587 is for submission to a sending
service. This MVP needs outbound access: opening an inbound port does not enable
an outbound connection.
[SMTP](https://www.rfc-editor.org/rfc/rfc5321.html#section-4.5.4.2) and
[the submission port](https://www.rfc-editor.org/rfc/rfc6409.html#section-3.1).

Use IPv4 for the first test. If you also send over IPv6, configure matching AAAA,
PTR, and SPF `ip6:` authorization for that address. Authentication requirements
apply to the actual source IP of the connection.
[Sender DNS and authentication requirements](https://support.google.com/mail/answer/81126?hl=en).

## DKIM delivery configuration

This example uses `deliver/2`. The values must match the DNS records above.

```elixir
Postbeam.deliver(
  [
    from: "hello@example.com",
    to: "elchemista@gmail.com",
    subject: "Postbeam test",
    text: "First direct delivery through MX."
  ],
  hostname: "mta.example.com",
  tls: :always,
  dkim: [
    d: "example.com",
    s: "postbeam",
    private_key: {:pem_plain, File.read!("priv/keys/postbeam.pem")}
  ]
)
```

For the Gmail test, require STARTTLS with `tls: :always`. The From address,
envelope sender, and DKIM signing domain will all use `example.com`, keeping
authentication aligned. Gmail requires TLS and valid forward/reverse DNS;
we prepare both SPF and DKIM for the test.
[Gmail sender guidelines](https://support.google.com/mail/answer/81126?hl=en).

When the message arrives, open **Show original** in Gmail and check
`SPF: PASS`, `DKIM: PASS`, and `DMARC: PASS`. Also check the spam folder:
SMTP acceptance and successful authentication do not guarantee inbox placement.
[Checking authentication in Gmail](https://support.google.com/mail/answer/180707?hl=en&co=GENIE.Platform%3DDesktop).
