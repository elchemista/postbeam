# DKIM keys

Configure a signing domain and selector:

```elixir
config :postbeam,
  dkim: [d: "example.com", s: "mail"],
  key_store: {Postbeam.KeyStore.File, directory: "/var/lib/my_app/mail-keys"}
```

Generate or load the key and obtain its DNS record:

```elixir
{:ok, record} = Postbeam.DKIM.setup()
# Publish record.value as a TXT record at record.name.
```

`setup/1` accepts the same options as delivery. It does not send email or change
DNS. Managed RSA keys are 2048 bits and generated on setup or first delivery,
then reused. Publish the record before sending mail.

The file store writes `<directory>/<domain>/<selector>.pem` with mode `0600` and
atomically creates keys without overwriting an existing one. Use a writable,
persistent directory and back it up. The default is the library's `priv/keys`
directory, which may be unsuitable in deployed releases.

Unreadable or corrupt keys fail delivery rather than silently rotating. To
rotate, create a new selector, publish its DNS record, then switch signing
configuration. Keep the old public record available while old messages may
still be in transit.

## Explicit keys

```elixir
dkim: [
  d: "example.com",
  s: "mail",
  private_key: {:pem_plain, pem}
]
```

Encrypted PEM uses `{:pem_encrypted, pem, ~c"password"}`. RSA-SHA256 is the default;
explicit Ed25519 keys support `a: :"ed25519-sha256"`. MIME and DKIM signing are
handled by `Postbeam.SMTP.MIME` and `Postbeam.SMTP.DKIM`. Signature bytes remain unchanged across MX attempts and
Swoosh recipients.

## Canonicalization and signed headers

`c: {:relaxed, :simple}` is the default. Set `c: {:relaxed, :relaxed}` to
normalize spaces and tabs within body lines, remove trailing whitespace, and
ignore trailing empty lines according to
[RFC 6376 section 3.4.4](https://www.rfc-editor.org/rfc/rfc6376.html#section-3.4.4).
This tolerates those whitespace changes, but does not permit arbitrary line
rewrapping or changes to the message content. Both header and body modes accept
`:simple` or `:relaxed`.

The default `h` list covers From, To, Cc, Reply-To, Subject, Date, Message-ID,
MIME-Version, Content-Type and Content-Transfer-Encoding. Override it with
`h: ["from", ...]` when needed. Missing fields contribute no bytes to the hash,
but remain in `h` so adding them invalidates the signature. Repeated names
select successive occurrences from the bottom of the header block.

## Custom persistence

Set `key_store: {MyApp.Keys, options}` and implement `Postbeam.KeyStore`:

- `fetch({domain, selector}, options)` returns `{:ok, pem}`, `:not_found` or
  `{:error, reason}`.
- `put_new({domain, selector}, pem, options)` atomically creates a missing key.
  Return `{:error, :already_exists}` when another writer won; Postbeam reads it.

Only `:not_found` permits generation. Never overwrite a published key or include
key material in returned errors.
