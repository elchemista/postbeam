# Postbeam

Send email directly to recipient MX servers from Elixir, with optional Swoosh
support. Includes TLS, DKIM, text/HTML bodies and Swoosh attachments.

## Install

Requires Elixir 1.19+ and Erlang/OTP 26+. For a local checkout:

```elixir
  defp deps do
    [
      {:postbeam, github: "elchemista/postbeam"}
    ]
  end
```

## Send

```elixir
Postbeam.deliver(
  [from: "hello@example.com", to: "person@example.net",
   subject: "Welcome", text: "Hello!"],
  hostname: "mta.example.com",
  tls: :always,
  dkim: [d: "example.com", s: "mail"]
)
```

Returns `{:ok, receipt}` after SMTP acceptance or `{:error, reason}`.
[Set up your sending domain](docs/domain-setup.md) before sending real email.

## Swoosh / Phoenix

Add `{:swoosh, "~> 1.28"}` and configure your mailer:

```elixir
config :my_app, MyApp.Mailer,
  adapter: Postbeam.Swoosh.Adapter,
  postbeam: [hostname: "mta.example.com", tls: :always]
```

Compose with `Swoosh.Email`, then call `MyApp.Mailer.deliver(email)`.
To, Cc, Bcc, Reply-To, HTML, attachments and inline images are supported.
[Complete setup](docs/swoosh.md).

## Usage guides

- [Configuration and TLS](docs/configuration.md)
- [Delivery results and retry decisions](docs/delivery.md)
- [DKIM keys](docs/dkim.md)
- [Custom DNS and transport adapters](docs/adapters.md)

Delivery is synchronous. Background jobs, retries over time and storage belong
to your application. Mailboxes must be ASCII; use punycode for international
domains. Display names, subjects and bodies support Unicode.
