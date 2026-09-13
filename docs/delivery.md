# Delivery results

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
The transport marks the start of DATA: network failures from that
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

Delayed retries, persistence and scheduling belong to the consuming application.
