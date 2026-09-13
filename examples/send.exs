# Run with: mix run examples/send.exs
required = fn name -> System.fetch_env!("POSTBEAM_" <> name) end

integer = fn name, default ->
  System.get_env("POSTBEAM_" <> name, Integer.to_string(default)) |> String.to_integer()
end

tls =
  case System.get_env("POSTBEAM_TLS", "always") do
    "always" -> :always
    "if_available" -> :if_available
    "never" -> :never
    value -> raise ArgumentError, "Invalid POSTBEAM_TLS: #{inspect(value)}"
  end

dkim =
  case System.get_env("POSTBEAM_DKIM_KEY") do
    nil ->
      nil

    path ->
      [
        d: required.("DKIM_DOMAIN"),
        s: required.("DKIM_SELECTOR"),
        private_key: {:pem_plain, File.read!(path)}
      ]
  end

result =
  Postbeam.deliver(
    [
      from: required.("FROM"),
      to: required.("TO"),
      subject: System.get_env("POSTBEAM_SUBJECT", "Postbeam delivery test"),
      text: System.get_env("POSTBEAM_TEXT", "Hello from Postbeam."),
      html: System.get_env("POSTBEAM_HTML")
    ],
    hostname: required.("HOSTNAME"),
    tls: tls,
    dkim: dkim,
    connect_timeout: integer.("CONNECT_TIMEOUT", 5_000),
    smtp_timeout: integer.("SMTP_TIMEOUT", 60_000),
    dns_timeout: integer.("DNS_TIMEOUT", 5_000)
  )

IO.puts("SMTP delivery: #{inspect(result, pretty: true)}")
if match?({:error, _}, result), do: System.halt(1)
