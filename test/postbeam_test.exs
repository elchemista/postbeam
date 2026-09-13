defmodule PostbeamTest do
  use ExUnit.Case, async: true
  alias Postbeam.{TestDNS, TestTransport}

  @message [from: "sender@example.com", to: "user@example.net", subject: "Caffè ☕", text: "Ciao!"]
  @options [hostname: "mta.example.com", resolver: TestDNS, transport: TestTransport]

  test "orders MX servers, preserves MIME and Message-ID on temporary failover" do
    TestDNS.put("example.net", :mx, {:ok, [{20, ~c"second.test."}, {10, ~c"first.test."}]})
    Process.put({TestTransport, "first.test"}, {:error, {:retry, "451 later"}})
    assert {:ok, %{mx: "second.test", message_id: id}} = Postbeam.deliver(@message, @options)
    assert_receive {:attempt, "first.test", first, _}
    assert_receive {:attempt, "second.test", second, _}
    assert first.data == second.data
    assert first.message_id == id
    assert second.message_id == id
    assert first.data =~ "Message-ID: #{id}"
  end

  test "permanent and uncertain results stop without attempting the next MX" do
    TestDNS.put("example.net", :mx, {:ok, [{1, "first.test"}, {2, "second.test"}]})

    for kind <- [:permanent, :uncertain] do
      Process.put({TestTransport, "first.test"}, {:error, {kind, :detail}})

      assert {:error, {^kind, %{mx: "first.test", reason: :detail, message_id: id}}} =
               Postbeam.deliver(@message, @options)

      assert is_binary(id)
      assert_receive {:attempt, "first.test", _, _}
      refute_receive {:attempt, "second.test", _, _}
    end
  end

  test "exhausted results preserve the ordered host errors" do
    TestDNS.put("example.net", :mx, {:ok, [{1, "first.test"}, {2, "second.test"}]})

    for host <- ["first.test", "second.test"],
        do: Process.put({TestTransport, host}, {:error, {:retry, :econnrefused}})

    assert {:error,
            {:exhausted,
             %{
               attempts: [
                 %{mx: "first.test", reason: :econnrefused},
                 %{mx: "second.test", reason: :econnrefused}
               ]
             }}} = Postbeam.deliver(@message, @options)
  end

  test "no MX uses implicit MX; DNS failures and Null MX never deliver" do
    assert {:ok, %{mx: "example.net"}} = Postbeam.deliver(@message, @options)
    assert_receive {:attempt, "example.net", _, _}

    for reason <- [:nxdomain, :servfail, :timeout] do
      TestDNS.put("example.net", :mx, {:error, reason})
      assert {:error, {:dns, "example.net", :mx, ^reason}} = Postbeam.deliver(@message, @options)
    end

    for root <- [~c".", ~c"", ".", ""] do
      TestDNS.put("example.net", :mx, {:ok, [{0, root}]})
      assert {:error, {:null_mx, "example.net"}} = Postbeam.deliver(@message, @options)
    end

    TestDNS.put("example.net", :mx, {:ok, [{0, "."}, {10, "mx.test"}]})
    assert {:error, {:invalid_mx, _, _}} = Postbeam.deliver(@message, @options)
    refute_receive {:attempt, _, _, _}
  end

  test "equal priorities shuffle, lower priority remains last, and duplicate hosts are removed" do
    TestDNS.put(
      "example.net",
      :mx,
      {:ok, [{10, "a.test"}, {10, "b.test"}, {20, "c.test"}, {30, "a.test"}]}
    )

    orders =
      for _ <- 1..30 do
        {:ok, hosts} = Postbeam.MX.resolve("example.net", @options)
        assert List.last(hosts) == "c.test"
        assert Enum.sort(hosts) == ["a.test", "b.test", "c.test"]
        hosts
      end

    assert Enum.uniq(orders) |> length() == 2
  end

  test "invalid messages and header injection fail before DNS or SMTP" do
    for {field, value} <- [
          from: "x@example.com\r\nBcc: y@example.com",
          to: "a\nb@example.net",
          to: "a..b@example.net",
          to: "a@-example.net",
          to: ["a@example.net"],
          subject: "Hello\nBcc: a@example.net",
          subject: <<0>>,
          subject: nil,
          text: <<255>>,
          html: 123
        ] do
      assert {:error, {:invalid, ^field}} =
               Postbeam.deliver(Keyword.put(@message, field, value), @options)
    end

    assert {:error, {:invalid, :body}} =
             Postbeam.deliver(Keyword.delete(@message, :text), @options)

    assert {:error, {:unknown_field, :cc}} =
             Postbeam.deliver(@message ++ [cc: "x@example.net"], @options)

    assert {:error, {:unknown_field, nil}} =
             Postbeam.deliver(Map.put(Map.new(@message), nil, "x"), @options)

    refute_receive {:dns, _, _}
    refute_receive {:attempt, _, _, _}
  end

  test "invalid configuration is rejected without network access" do
    for {key, value} <- [
          hostname: "host\r\nMAIL FROM:x",
          tls: :sometimes,
          smtp_timeout: :infinity,
          dns_timeout: 0,
          port: 0,
          transport: MissingModule,
          resolver: String,
          dkim: [d: "example.com", s: "x\r\nInjected: y", private_key: {:pem_plain, "x"}],
          unknown: true
        ] do
      assert {:error, {:invalid_config, ^key}} =
               Postbeam.deliver(@message, Keyword.put(@options, key, value))
    end

    assert {:error, {:invalid, :config}} = Postbeam.deliver(@message, %{})
    refute_receive {:dns, _, _}
  end

  test "bad DKIM keys yield sanitized composition errors and no SMTP connection" do
    assert {:error, {:composition, _}} =
             Postbeam.deliver(
               @message,
               @options ++
                 [dkim: [d: "example.com", s: "test", private_key: {:pem_plain, "SECRET"}]]
             )

    refute_receive {:attempt, _, _, _}
  end

  test "MIME round trips UTF-8 text, HTML and multipart bodies" do
    for bodies <- [
          %{text: "Caffè ☕\n.Seconda riga"},
          %{html: "<p>Caffè ☕</p>"},
          %{text: "Caffè ☕", html: "<p>Caffè ☕</p>"}
        ] do
      fields = @message |> Map.new() |> Map.delete(:text) |> Map.merge(bodies)
      assert {:ok, _} = Postbeam.deliver(fields, @options)
      assert_receive {:attempt, _, message, _}
      {type, subtype, headers, _, body} = :mimemail.decode(message.data, encoding: :none)
      assert {"Subject", "=?UTF-8?Q?Caff=C3=A8_=E2=98=95?="} in headers
      assert {"Message-ID", message.message_id} in headers

      case bodies do
        %{text: text, html: html} ->
          assert {type, subtype} == {"multipart", "alternative"}
          assert [{"text", "plain", _, _, ^text}, {"text", "html", _, _, ^html}] = body

        %{text: text} ->
          assert {type, subtype, body} == {"text", "plain", text}

        %{html: html} ->
          assert {type, subtype, body} == {"text", "html", html}
      end
    end
  end
end
