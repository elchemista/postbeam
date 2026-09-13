# Set up a sending domain

Postbeam sends directly to the recipient's MX, using your server's public IP.
The same setup serves Gmail, Outlook, Yahoo, iCloud and company domains.

## Server and DNS

Choose an SMTP hostname such as `mta.example.com` and a From address in a domain
you control. Configure:

| Record / setting | Purpose |
| --- | --- |
| `mta.example.com A` (and AAAA if used) | Resolves your SMTP hostname to the sending IP |
| PTR for each sending IP | Reverse DNS points back to the SMTP hostname; configure through your server provider |
| SPF TXT at `example.com` | Authorizes your sending IP, e.g. `v=spf1 ip4:YOUR_IP -all` |
| DKIM TXT at `mail._domainkey.example.com` | Publishes the key used by Postbeam |
| DMARC TXT at `_dmarc.example.com` | Publishes your authentication policy; begin with `v=DMARC1; p=none` while verifying alignment |

Merge the IP authorization into an existing SPF record instead of publishing
multiple SPF records. The visible From domain should align with your SPF or DKIM
domain. Configure outbound TCP port **25** with your hosting provider and firewall.
Opening inbound SMTP does not enable outbound access. Port 587 is for submission
to a relay; Postbeam's direct MX transport uses port 25.

## DKIM

Generate or load a key and obtain its public DNS record:

```elixir
{:ok, record} = Postbeam.DKIM.setup(
  dkim: [d: "example.com", s: "mail"],
  key_store: {Postbeam.KeyStore.File, directory: "/var/lib/my_app/mail-keys"}
)
# Publish record.value as TXT at record.name.
```

Use those same `dkim` and `key_store` settings in `Postbeam.deliver/2`, the mailer
or the Swoosh mailer's `postbeam` options. Keep the key directory on persistent storage.
Use `hostname: "mta.example.com"` and `tls: :always` for encrypted delivery.

## Verify reception

Send to mailboxes you control at several providers. Check the message's original
headers for SPF, DKIM and DMARC results, and check spam as well as the inbox.
An SMTP acceptance does not guarantee inbox placement. Sending-IP and domain
reputation also influence filtering.

Provider requirements: [Google](https://support.google.com/mail/answer/81126),
[Yahoo](https://senders.yahooinc.com/best-practices/),
[Microsoft](https://support.microsoft.com/en-us/outlook/sender-support-in-outlook-com).
