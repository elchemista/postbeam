defmodule Postbeam.ConfigTest do
  use ExUnit.Case, async: false

  test "per-call options override application defaults, including disabling DKIM" do
    previous = Application.get_all_env(:postbeam)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:postbeam),
          do: Application.delete_env(:postbeam, key)

      for {key, value} <- previous, do: Application.put_env(:postbeam, key, value)
    end)

    Application.put_env(:postbeam, :hostname, "global.example.com")
    Application.put_env(:postbeam, :tls, :always)
    Application.put_env(:postbeam, :max_outbound_connections, 32)

    Application.put_env(:postbeam, :dkim,
      d: "example.com",
      s: "test",
      private_key: {:pem_plain, "bad"}
    )

    options = [resolver: Postbeam.TestDNS, transport: Postbeam.TestTransport, dkim: nil]
    message = [from: "a@example.com", to: "b@example.net", subject: "", text: ""]
    assert {:ok, %{message_id: id}} = Postbeam.deliver(message, options)
    assert id =~ "@global.example.com>"
    assert_receive {:attempt, _, _, config}
    assert config[:tls] == :always
    refute Keyword.has_key?(config, :max_outbound_connections)

    assert {:error, {:invalid_config, :max_outbound_connections}} =
             Postbeam.Config.new(max_outbound_connections: 10)

    assert {:ok, %{message_id: id}} =
             Postbeam.deliver(message, options ++ [hostname: "call.example.com"])

    assert id =~ "@call.example.com>"
  end
end

defmodule Postbeam.ConfigValidationTest do
  use ExUnit.Case, async: true
  alias Postbeam.Config

  for {key, value} <- [
        hostname: "",
        hostname: "a..test",
        port: 65_536,
        connect_timeout: -1,
        dns_timeout: 4_294_967_296,
        tls_options: %{},
        dns_options: [:bad],
        resolver: nil,
        transport: Postbeam.Config
      ] do
    test "rejects #{key}=#{inspect(value)}" do
      assert {:error, {:invalid_config, unquote(key)}} =
               Config.new([{unquote(key), unquote(Macro.escape(value))}])
    end
  end

  test "rejects ambiguous duplicate options and malformed containers" do
    for options <- [[port: 25, port: 2525], nil, 42, ["tls"], [{"tls", :always}]] do
      assert {:error, {:invalid, :config}} = Config.new(options)
    end

    for key <- [:tls_options, :dns_options, :dkim] do
      assert {:error, {:invalid_config, ^key}} = Config.new([{key, [x: 1, x: 2]}])
    end
  end

  test "validates DKIM algorithms, canonicalization, signed headers and timestamps" do
    dkim = [d: "example.com", s: "selector", private_key: {:pem_plain, "placeholder"}]

    for option <- [
          a: :md5,
          c: {:relaxed, :relaxed},
          h: [],
          h: ["subject"],
          h: ["from", "X-Bad\r\nInjected"],
          t: {{2026, 2, 30}, {0, 0, 0}},
          t: {{2026, 1, 1}, {24, 0, 0}},
          x: {{2026, 1, 1}, {0, 60, 0}},
          x: {{2026, 1, 1}, {0, 0, 60}},
          x: {{2026, 1, 1}, {0, 0, :bad}},
          t: {{:bad, 1, 1}, {0, 0, 0}},
          t: :tomorrow,
          unknown: true,
          private_key: {:pem_encrypted, "pem", [:bad]}
        ] do
      assert {:error, {:invalid_config, :dkim}} = Config.new(dkim: Keyword.merge(dkim, [option]))
    end

    for option <- [
          a: :"rsa-sha256",
          a: :"ed25519-sha256",
          c: {:simple, :simple},
          c: {:relaxed, :simple},
          h: ["from", "message-id"],
          t: :now,
          x: {{2028, 2, 29}, {23, 59, 59}},
          private_key: {:pem_encrypted, "pem", ~c"password"}
        ] do
      assert {:ok, _} = Config.new(dkim: Keyword.merge(dkim, [option]))
    end
  end

  test "DNS and TLS sub-options are replaced rather than partially inherited" do
    assert {:ok, config} =
             Config.new(tls_options: [verify: :verify_none], dns_options: [retry: 1])

    assert config[:tls_options] == [verify: :verify_none]
    assert config[:dns_options] == [retry: 1]
  end
end
