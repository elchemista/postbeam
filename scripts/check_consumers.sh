#!/usr/bin/env bash
# Compile and boot the packaged library in isolated consumers, with and without Swoosh.
set -euo pipefail

repository_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/postbeam-consumers.XXXXXX")
trap 'rm -rf "$smoke_dir"' EXIT

cd "$repository_dir"
mix hex.build --output "$smoke_dir/postbeam.tar"
mkdir -p "$smoke_dir/package" "$smoke_dir/envelope"
tar -xf "$smoke_dir/postbeam.tar" -C "$smoke_dir/envelope"
tar -xzf "$smoke_dir/envelope/contents.tar.gz" -C "$smoke_dir/package"

for with_swoosh in false true; do
  consumer_dir="$smoke_dir/consumer-$with_swoosh"
  mkdir -p "$consumer_dir/lib" "$consumer_dir/config"
  cat > "$consumer_dir/mix.exs" <<'MIX'
defmodule Consumer.MixProject do
  use Mix.Project

  def project do
    deps = [{:postbeam, path: "../package"}]
    deps = if System.fetch_env!("WITH_SWOOSH") == "true", do: [{:swoosh, "~> 1.28"} | deps], else: deps
    [app: :consumer, version: "0.1.0", deps: deps]
  end

  def application, do: [extra_applications: [:logger]]
end
MIX
  cat > "$consumer_dir/config/config.exs" <<'CONFIG'
import Config
config :logger, level: :warning
if System.fetch_env!("WITH_SWOOSH") == "true", do: config(:swoosh, :api_client, false)
CONFIG
  cat > "$consumer_dir/lib/consumer.ex" <<'ELIXIR'
defmodule Consumer do
  def check do
    expected = System.fetch_env!("WITH_SWOOSH") == "true"
    ^expected = Code.ensure_loaded?(Swoosh.Email)
    ^expected = Code.ensure_loaded?(Postbeam.Swoosh.Adapter)
    {:error, {:invalid, :from}} = Postbeam.deliver(from: "bad", to: "x@example.net", subject: "", text: "")

    {:ok, %{receipt: "accepted"}} = Postbeam.deliver(
      [from: "a@example.com", to: "x@example.net", subject: "", text: "Hello"],
      resolver: Consumer.DNS, transport: Consumer.Transport
    )

    if expected do
      email = apply(Swoosh.Email, :new, [[from: "a@example.com", to: "x@example.net", text_body: ""]])
      config = [postbeam: [resolver: Consumer.DNS, transport: Consumer.Transport]]
      {:ok, %{deliveries: [%{receipt: "accepted"}]}} = apply(Consumer.Mailer, :deliver, [email, config])
    end

    IO.puts("Consumer and OTP release verified; Swoosh=#{expected}")
  end
end
ELIXIR
  cat > "$consumer_dir/lib/mailer.ex" <<'ELIXIR'
if Code.ensure_loaded?(Swoosh.Email) do
  defmodule Consumer.Mailer do
    use Swoosh.Mailer, otp_app: :consumer, adapter: Postbeam.Swoosh.Adapter
  end
end
ELIXIR
  cat > "$consumer_dir/lib/dns.ex" <<'ELIXIR'
defmodule Consumer.DNS do
  @behaviour Postbeam.MX
  def lookup(_, _, _), do: {:ok, []}
end
ELIXIR
  cat > "$consumer_dir/lib/transport.ex" <<'ELIXIR'
defmodule Consumer.Transport do
  @behaviour Postbeam.SMTP
  def deliver(_, %{data: data}, _) when is_binary(data), do: {:ok, "accepted"}
end
ELIXIR
  (
    cd "$consumer_dir"
    export WITH_SWOOSH="$with_swoosh" MIX_ENV=prod
    mix deps.get
    mix compile --warnings-as-errors
    mix run -e 'Consumer.check()'
    mix release --overwrite
    _build/prod/rel/consumer/bin/consumer eval 'Consumer.check()'
  )
done
