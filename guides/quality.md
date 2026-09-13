# Development and quality checks

## Tooling

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --cover --warnings-as-errors
mix dialyzer
mix docs --warnings-as-errors
```

Credo and Dialyxir are development/test dependencies with `runtime: false`.
ExDoc is development-only. Production still needs only `gen_smtp` directly and
its transitive runtime dependencies. The lockfile pins tool versions as well.

Credo runs its standard strict checks over `lib/`, `test/`, `examples/` and
`mix.exs`, without project-specific suppressions.
Dialyzer analyzes all production modules, their specs and OTP/dependency types,
with additional `:error_handling` and `:unmatched_returns` warnings. The first
run builds a PLT under `_build`; subsequent runs reuse it. Rebuild it after
changing the Elixir/OTP version if Dialyxir requests that.

ExDoc produces HTML and EPUB documentation under `doc/`. Public API examples
that use `iex>` prompts are executable doctests and perform no external I/O.
Generated docs, coverage reports and PLTs are excluded from Git.

## What the tests exercise

- Real local DNS-to-SMTP delivery through the default adapters.
- MX ordering, deduplication, equal-priority selection, implicit/Null MX,
  malformed MX sets and detailed DNS failures.
- IPv4/IPv6 fallback, missing addresses and partial family failures.
- SMTP greeting/envelope/DATA rejection, lost receipts and malformed replies.
- Deadlines, socket cleanup and caller termination while an attempt is active.
- STARTTLS negotiation and certificate validation on IPv4 and IPv6, including
  incorrect hostnames and intermediate certificate chains.
- Mailbox syntax boundaries, unsupported address forms, control-character
  injection, malformed containers and duplicate keys.
- UTF-8 text/HTML MIME, long encoded content, Message-ID stability within an
  attempt sequence and fresh IDs across independent encodings.
- Cryptographic DKIM signature/body-hash verification and signed-byte stability
  across fallback, plus invalid key/options handling.
- Application option precedence and executable public documentation.

Tests use local UDP/TCP/TLS receivers on ephemeral ports and process-local
adapter state. They do not depend on public DNS or send real email. IPv6 tests
require an enabled loopback interface. Keys/certificates are generated in memory
for each test and are never production credentials.

## Coverage and failures

`mix test --cover` measures production modules, excluding only the test adapter
and receiver helpers. Open `cover/Elixir.Postbeam.SMTP.html`, for example, to
inspect uncovered branches. Coverage supports review; add tests for behavior
and failure modes, not just to execute more lines.

On failure, first run the affected test file or `mix test --failed`. Fix source
problems rather than disabling checks. Preserve phase-aware SMTP error
classification when refactoring: a mistaken retry after DATA can duplicate mail.

External acceptance, SPF/DKIM/DMARC results and inbox placement are a separate
manual verification. Use `examples/send.exs` with a controlled sender and test
recipient only after configuring the domain, host and outbound TCP port 25.
