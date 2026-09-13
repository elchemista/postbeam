# Configuration

Pass options to `Postbeam.deliver/2`, under `postbeam: [...]` in a Swoosh mailer,
or as application defaults:

```elixir
config :postbeam,
  hostname: "mta.example.com",
  tls: :always,
  dkim: [d: "example.com", s: "mail"]
```

Call options override application defaults. Nested keyword lists such as `dkim`
and `tls_options` are replaced as a whole. Unknown and duplicate options fail
validation. `dkim: nil` disables signing for a call.

| Option | Default | Purpose |
| --- | --- | --- |
| `hostname` | `"localhost"` | Public EHLO and Message-ID hostname |
| `tls` | `:if_available` | `:always`, `:if_available` or `:never` |
| `tls_options` | `[]` | OTP SSL overrides, such as a private CA |
| `port` | `25` | Destination SMTP port |
| `connect_timeout` | `5_000` | TCP connection/send timeout, ms |
| `smtp_timeout` | `60_000` | Hard deadline for each IP attempt, ms |
| `dns_timeout` | `5_000` | Deadline for each DNS query, ms |
| `dns_options` | `[]` | OTP resolver options, such as private nameservers |
| `dkim` | `nil` | Signing domain, selector and optional explicit PEM |
| `key_store` | `Postbeam.KeyStore.File` | DKIM key persistence |
| `resolver` | `Postbeam.MX` | DNS adapter implementing `lookup/3` |
| `transport` | `Postbeam.SMTP` | SMTP adapter implementing `deliver/3` |

TLS uses TLS 1.2/1.3, system CAs and MX hostname verification. Use `tls: :always`
to require encryption. `:if_available` permits plaintext, including when the
underlying SMTP client cannot establish optional STARTTLS.

There is no SMTP authentication or submission relay: delivery goes directly to
the recipient's MX. Multiple recipients, MX hosts and IPs increase total elapsed
time; timeouts apply per operation. DNS caching and background scheduling belong
to your application.
