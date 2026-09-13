# Swoosh / Phoenix

Add Postbeam and `{:swoosh, "~> 1.28"}` to your application. Swoosh is optional;
applications using only `Postbeam.deliver/2` do not need it.

```elixir
defmodule MyApp.Mailer do
  use Swoosh.Mailer, otp_app: :my_app
end
```

Configure your existing Phoenix mailer, or the module above:

```elixir
config :my_app, MyApp.Mailer,
  adapter: Postbeam.Swoosh.Adapter,
  postbeam: [
    hostname: "mta.example.com",
    tls: :always,
    dkim: [d: "example.com", s: "mail"]
  ]

# If all mailers use SMTP, no Swoosh HTTP client is needed.
config :swoosh, :api_client, false
```

Keep an HTTP client configured if another mailer requires one. Postbeam options
belong inside `postbeam: [...]`; see [configuration](configuration.md) and
[domain setup](domain-setup.md). If adding Swoosh to an existing build, run
`mix deps.compile postbeam --force` to compile the optional adapter.

## Compose and deliver

```elixir
import Swoosh.Email

email =
  new()
  |> from({"Example team", "hello@example.com"})
  |> to("person@example.net")
  |> cc("copy@example.org")
  |> bcc("private@example.edu")
  |> reply_to("support@example.com")
  |> subject("Welcome")
  |> text_body("Welcome!")
  |> html_body("<h1>Welcome!</h1>")
  |> attachment(Swoosh.Attachment.new({:data, "Your report"},
    filename: "report.txt", content_type: "text/plain"))

MyApp.Mailer.deliver(email)
```

To, Cc and Bcc may contain multiple recipients. One MIME message is signed once
and reused across separate SMTP transactions. Bcc is absent from wire headers;
duplicate envelope mailboxes are removed after domain normalization.

- Mailbox addresses must be ASCII dot-atom addresses. Use punycode for IDN
  domains. SMTPUTF8, quoted local parts and address literals are unsupported.
- Display names, subjects and bodies support Unicode. At least one body must
  be supplied; an empty body or subject is valid.
- Reply-To accepts one mailbox or a list. Custom headers are supported, except
  generated/routing headers such as From, Bcc, Message-ID, DKIM-Signature,
  Content-* and Resent-*. Invalid headers and provider options are rejected.
- File or in-memory attachments are read before delivery. Inline images require
  HTML and a unique ASCII `cid` without whitespace, referenced as `cid:logo`.
  Composite `message/*` and `multipart/*` attachments are unsupported.
- Attachment bytes are retained in memory across attempts. There is no streaming.
  Swoosh assigns/private metadata are not serialized.

## Results

```elixir
{:ok, %{message_id: id, deliveries: receipts}}

{:error, {:delivery_failed, %{
  message_id: id,
  deliveries: accepted_receipts,
  failures: [%{to: address, reason: postbeam_error}]
}}}
```

Validation/composition errors return before delivery. Each receipt contains
`to`, `mx`, `receipt` and `message_id`. Acceptance does not guarantee inbox placement.
Do not retry the entire email after partial success, or automatically retry an
uncertain result. See [delivery results](delivery.md).

`Mailer.deliver!/2` returns the success map or raises `Swoosh.DeliveryError`.
Batch `deliver_many/2` is not implemented. Background jobs and persistence belong
to your application.

Per-call `postbeam: [...]` replaces the mailer's whole Postbeam list. Omitted
values then come from Postbeam application defaults, not the previous mailer list.
