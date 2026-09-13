# Key and sent-email stores

Postbeam separates the persistent signing identity from the optional archive of
accepted emails. Each adapter is a module or `{module, keyword_options}`. The
library adds no database or secret-manager dependency.

## Managed DKIM

```elixir
config :postbeam,
  dkim: [d: "example.com", s: "postbeam"],
  key_store: Postbeam.KeyStore.File

# Application code; safe to call repeatedly or expose in an authenticated admin UI.
{:ok, record} = Postbeam.DKIM.setup()
# Publish record.value at record.name; record.host omits the zone's domain.
```

At startup Postbeam loads or creates the globally configured managed key. For
per-call configuration, `Postbeam.DKIM.setup/1` prepares the record before sending,
and encoding also loads/creates the key. RSA generation runs in the calling
process only on first use; no permanent key-management process is required.
Delivery reads the stored key on each call so a store does not become a second,
inconsistent cache. If that read fails, signing and SMTP do not proceed.

Default files live under the library's application `priv/keys/<domain>/<selector>.pem`.
Configure another location entirely in code:

```elixir
config :postbeam,
  key_store: {Postbeam.KeyStore.File, directory: "/persistent/postbeam/keys"}
```

A release/container may have a read-only or ephemeral application directory.
Choose storage that survives deployment. Local files are not replicated to other
nodes. Generating a separate key on each node under the same selector will break
DKIM verification; share a persistent store or assign different selectors.
Only public DNS data is returned by `Postbeam.DKIM.setup/1`.

## Implementing a key store

Implement `Postbeam.KeyStore`:

```elixir
defmodule MyApp.DKIMKeys do
  @behaviour Postbeam.KeyStore

  @impl true
  def fetch({domain, selector}, options) do
    # Return {:ok, unencrypted_pem}, :not_found, or {:error, safe_reason}.
    MyApp.Secrets.fetch({domain, selector}, options)
  end

  @impl true
  def put_new({domain, selector}, pem, options) do
    # Atomically create only if absent; use a unique constraint / conditional put.
    # Return :ok, {:error, :already_exists}, or {:error, safe_reason}.
    MyApp.Secrets.create_if_absent({domain, selector}, pem, options)
  end
end
```

Configure `key_store: {MyApp.DKIMKeys, bucket: "mail-signing"}`. Both callbacks
receive the same options. Domains/selectors are lowercased before reaching the
adapter. The PEM is an unencrypted RSA private key; encrypt it at rest inside
your adapter as appropriate. Reads must observe a completed `put_new/3`.

The default file implementation writes and syncs a private temporary file, then
publishes it with an atomic hard link. Concurrent creators read the winning key;
no partial PEM or replacement of an existing key is allowed. A corrupt key or
store error stops preparation instead of generating a replacement. Adapter
exceptions/exits are sanitized; callback error reasons must themselves omit
secrets. Custom adapters own their timeouts and connection lifecycle.

A globally configured key store must be available when the Postbeam OTP
application starts. Put its service in an earlier application dependency if
needed. For a store owned by your application's supervision tree, leave global
`dkim` unset, start that store first, then call `Postbeam.DKIM.setup/1` from your
startup code and pass signing/store options to deliveries. Startup preparation
can fail and should not be silently ignored.

To rotate, use a new selector, call setup, publish the new TXT record and wait
for propagation before switching sending configuration. Preserve the old key
and DNS record long enough for already-sent emails to be verified. No automatic
rotation, deletion or DNS publication is performed.

Existing explicit keys remain supported:

```elixir
dkim: [d: "example.com", s: "legacy", private_key: {:pem_plain, pem}]
```

Explicit keys bypass the store; `setup/1` is for managed RSA keys only. Other
signing options (`:h`, `:c`, `:t`, `:x`) still pass through to `:mimemail`.

## Sent email archive

```elixir
config :postbeam, sent_store: Postbeam.SentStore.ETS

{:ok, entries} = Postbeam.SentStore.ETS.list()
```

The default owner is supervised by Postbeam and keeps the last 10 accepted
emails on this node. Each entry contains `:message` (including signed wire
`:data` and Message-ID), `:receipt` (SMTP acceptance) and `:accepted_at` (UTC).
Adapter options, TLS settings and DKIM private keys are never archived.

Reads access a protected ETS table directly. Writes and eviction are serialized,
and the count is bounded even during concurrent reads/writes. Ordering reflects
archive insertion, not necessarily SMTP completion order. A read during concurrent
writes is a best-effort view, not a transaction. Owner/node restart loses entries.
Large bodies can still consume significant memory: the limit counts emails.

To retain a different number, add a separately named instance to your children:

```elixir
{Postbeam.SentStore.ETS, name: MyApp.SentEmails, limit: 100}
```

Use `sent_store: {Postbeam.SentStore.ETS, name: MyApp.SentEmails}` and
`Postbeam.SentStore.ETS.list(name: MyApp.SentEmails)`. `limit` belongs to the owner's
startup options; callers cannot change a shared table's retention. The default
instance remains available for other callers.

For a custom archive implement one callback:

```elixir
defmodule MyApp.SentEmails do
  @behaviour Postbeam.SentStore

  @impl true
  def put(entry, options) do
    # Return :ok or {:error, safe_reason}; queries belong to your adapter.
    MyApp.Archive.insert(entry.message.message_id, entry, options)
  end
end
```

Enable with `sent_store: {MyApp.SentEmails, retention_days: 30}`. Pass
`sent_store: nil` to disable an application-level archive for one delivery.
The callback runs synchronously after acceptance, once per successful call, so
its latency adds to delivery duration. The ETS adapter bounds the owner call to
five seconds; custom adapters must provide their own finite deadlines.

An enabled archive adds `storage: :ok | {:error, reason}` to a **successful**
delivery receipt. Archive exceptions, exits and malformed responses become
storage errors. SMTP acceptance is preserved; never resend to retry storage.
Temporary rejections, permanent rejections, exhausted attempts and uncertain
acceptance are not archived. Use a separate queue/outbox for durable submission
or failed-attempt history.

SMTP acceptance and archiving are not atomic. A caller/node crash between them
can lose the archive entry, and a timed-out archive operation might complete
later. The archive is not a delivery queue or an exactly-once guarantee.
