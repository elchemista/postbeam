defmodule Postbeam.SwooshTest do
  use ExUnit.Case, async: true

  import Swoosh.Email

  alias Postbeam.TestDNS
  alias Postbeam.TestMailer
  alias Postbeam.TestTransport
  alias Swoosh.Attachment

  @options [hostname: "mta.example.com", resolver: TestDNS, transport: TestTransport]

  test "mailer composes display names, Reply-To, Unicode bodies and custom headers" do
    email =
      email()
      |> from({~s(Caffè "team" \\ support), "Sender@EXAMPLE.COM"})
      |> reply_to([{"Support", "support@example.com"}, "other@example.org"])
      |> html_body("<p>Caffè ☕</p>")
      |> header("X-Trace", "test-123")
      |> assign(:secret, "not in MIME")
      |> put_private(:template, :welcome)

    assert {:ok, %{message_id: id, deliveries: [receipt]}} = deliver(email)
    assert receipt.message_id == id
    assert_receive {:attempt, "example.net", message, _}
    assert message.from == "Sender@example.com"
    assert message.to == "user@example.net"
    assert {"multipart", "alternative", headers, _, parts} = decode(message)
    assert {"X-Trace", "test-123"} in headers
    assert {"Message-ID", id} in headers
    assert header_value(headers, "Reply-To") =~ "support@example.com"
    assert header_value(headers, "Reply-To") =~ "other@example.org"
    assert header_value(headers, "From") =~ "=?UTF-8?"
    assert [{"text", "plain", _, _, "Caffè ☕"}, {"text", "html", _, _, "<p>Caffè ☕</p>"}] = parts
    refute message.data =~ "not in MIME"
    assert Enum.all?(:binary.bin_to_list(message.data), &(&1 < 128))
  end

  test "To, CC and BCC deliver once per normalized mailbox with identical bytes" do
    email =
      email()
      |> put_to(["user@example.net", {"Duplicate", "user@EXAMPLE.NET"}])
      |> cc(["copy@example.org", "User@example.net"])
      |> bcc(["hidden@example.edu", "copy@example.org"])

    assert {:ok, %{deliveries: receipts}} = deliver(email)

    assert Enum.map(receipts, & &1.to) == [
             "user@example.net",
             "copy@example.org",
             "User@example.net",
             "hidden@example.edu"
           ]

    messages =
      for _ <- receipts do
        assert_receive {:attempt, _, message, _}
        message
      end

    assert messages |> Enum.map(& &1.data) |> Enum.uniq() |> length() == 1
    assert messages |> Enum.map(& &1.message_id) |> Enum.uniq() |> length() == 1

    for message <- messages do
      refute message.data =~ "hidden@example.edu"
      {_, _, headers, _, _} = decode(message)
      refute Enum.any?(headers, fn {name, _} -> String.downcase(name) == "bcc" end)
      assert header_value(headers, "To") =~ "user@example.net"
      assert header_value(headers, "Cc") =~ "copy@example.org"
    end

    refute_receive {:attempt, _, _, _}
  end

  test "CC-only and BCC-only emails are valid while empty recipients fail" do
    for field <- [:cc, :bcc] do
      email = %{email() | field => [{"", "only@example.org"}], to: []}
      assert {:ok, %{deliveries: [%{to: "only@example.org"}]}} = deliver(email)
      assert_receive {:attempt, _, message, _}
      if field == :bcc, do: refute(message.data =~ "only@example.org")
    end

    assert {:error, {:invalid, :recipients}} = deliver(%{email() | to: []})
  end

  test "all recipients and content are validated before any DNS or SMTP" do
    invalid = [
      %{email() | bcc: [{"", "bad"}]},
      %{email() | cc: :bad},
      %{email() | to: [{"", "user@example.net"}, {"", "invalid"}]},
      %{email() | from: {"injected\r\nBcc: x", "a@example.com"}},
      %{email() | reply_to: {"", "invalid"}},
      %{email() | text_body: nil},
      %{email() | subject: "Injected\nHeader"},
      %{email() | attachments: [:invalid]},
      %{email() | attachments: :invalid}
    ]

    for email <- invalid, do: assert({:error, {:invalid, _}} = deliver(email))
    refute_receive {:dns, _, _}
    refute_receive {:attempt, _, _, _}
  end

  test "reserved headers and case-insensitive duplicates cannot bypass validation" do
    for name <- [
          "Bcc",
          "bCC",
          "Content-Type",
          "DKIM-Signature",
          "Sender",
          "Return-Path",
          "Message-ID",
          "Date",
          "From",
          "Subject",
          "Reply-To",
          "Resent-Bcc"
        ] do
      assert {:error, {:invalid, :headers}} = deliver(header(email(), name, "x"))
    end

    for headers <- [
          %{"X-Test" => "a", "x-test" => "b"},
          %{"X-Test" => "a\r\nBcc: x"},
          %{"X Bad" => "a"},
          %{"X-Test" => nil},
          ["invalid"],
          nil
        ] do
      assert {:error, {:invalid, :headers}} = deliver(%{email() | headers: headers})
    end

    assert {:error, {:unsupported, :provider_options}} =
             deliver(put_provider_option(email(), :async, true))

    refute_receive {:dns, _, _}
  end

  test "partial and uncertain failures preserve successful receipts and continue other recipients" do
    TestDNS.put("example.org", :mx, {:ok, [{1, "first.test"}, {2, "backup.test"}]})
    Process.put({TestTransport, "first.test"}, {:error, {:uncertain, :disconnected}})
    email = email() |> put_to(["user@example.net", "copy@example.org", "last@example.edu"])
    assert {:error, {:delivery_failed, summary}} = deliver(email)
    assert Enum.map(summary.deliveries, & &1.to) == ["user@example.net", "last@example.edu"]
    assert [%{to: "copy@example.org", reason: {:uncertain, details}}] = summary.failures
    assert details.message_id == summary.message_id
    refute_receive {:attempt, "backup.test", _, _}
  end

  test "DNS errors and permanent/exhausted SMTP failures are retained per recipient" do
    TestDNS.put("example.net", :mx, {:error, :nxdomain})
    Process.put({TestTransport, "example.org"}, {:error, {:permanent, :rejected}})
    Process.put({TestTransport, "example.edu"}, {:error, {:retry, :econnrefused}})
    email = email() |> put_to(["user@example.net", "copy@example.org", "last@example.edu"])
    assert {:error, {:delivery_failed, %{deliveries: [], failures: failures}}} = deliver(email)

    assert [
             %{reason: {:dns, "example.net", :mx, :nxdomain}},
             %{reason: {:permanent, _}},
             %{reason: {:exhausted, _}}
           ] = failures
  end

  test "temporary MX fallback and recipients reuse the same MIME and Message-ID" do
    TestDNS.put("example.net", :mx, {:ok, [{1, "first.test"}, {2, "backup.test"}]})
    Process.put({TestTransport, "first.test"}, {:error, {:retry, :temporary}})
    assert {:ok, %{deliveries: [receipt]}} = deliver(email())
    assert receipt.mx == "backup.test"
    assert_receive {:attempt, "first.test", first, _}
    assert_receive {:attempt, "backup.test", second, _}
    assert first.data == second.data
    assert first.message_id == second.message_id
  end

  test "binary, file and inline attachments preserve content and MIME topology" do
    path =
      Path.join(System.tmp_dir!(), "postbeam-attachment-#{System.unique_integer([:positive])}")

    File.write!(path, <<0, 255, 1, 2>>)
    on_exit(fn -> File.rm(path) end)

    email =
      email()
      |> html_body(~s(<img src="cid:logo">))
      |> attachment(
        Attachment.new(path, filename: "dati ☕.bin", content_type: "application/octet-stream")
      )
      |> attachment(
        Attachment.new({:data, <<137, 80, 78, 71>>},
          filename: "logo.png",
          content_type: "image/png",
          type: :inline,
          cid: "logo"
        )
      )

    assert {:ok, _} = deliver(email)
    assert_receive {:attempt, _, message, _}
    assert {"multipart", "mixed", _, _, [alternative, ordinary]} = decode(message)
    assert {"multipart", "alternative", _, _, [text, related]} = alternative
    assert {"text", "plain", _, _, "Caffè ☕"} = text
    assert {"multipart", "related", _, _, [html, inline]} = related
    assert {"text", "html", _, _, ~s(<img src="cid:logo">)} = html
    assert {"image", "png", inline_headers, _, <<137, 80, 78, 71>>} = inline
    assert header_value(inline_headers, "Content-ID") == "<logo>"
    assert {"application", "octet-stream", _, params, <<0, 255, 1, 2>>} = ordinary

    assert {"filename*", encoded_filename} =
             List.keyfind(params.disposition_params, "filename*", 0)

    assert "UTF-8''" <> filename = encoded_filename
    assert URI.decode(filename) == "dati ☕.bin"
    assert Enum.all?(message.attachments, &(is_binary(&1.data) and is_nil(&1.path)))
  end

  test "attachment data wins over path and inline CID defaults to filename" do
    attachment = %Attachment{data: "", path: "/missing", filename: "logo.png", type: :inline}

    assert {:ok, _} =
             deliver(email() |> html_body("<img src='cid:logo.png'>") |> attachment(attachment))

    assert_receive {:attempt, _, message, _}
    assert message.data =~ "Content-ID: <logo.png>"
  end

  test "attachment validation and missing files fail before DNS" do
    valid = Attachment.new({:data, "hello"}, filename: "file.txt", content_type: "text/plain")

    invalid = [
      %{valid | filename: "bad\nname"},
      %{valid | content_type: "text/plain\r\nInjected: true"},
      %{valid | content_type: "message/rfc822"},
      %{valid | content_type: "multipart/mixed"},
      %{valid | type: :other},
      %{valid | data: nil},
      %{valid | type: :inline, cid: "bad>\r\nHeader: x"},
      %{valid | headers: [{"Content-ID", "<override>"}]},
      %{valid | headers: [{"X-Part", "bad\nvalue"}]}
    ]

    for attachment <- invalid do
      assert {:error, {:invalid, :attachments}} = deliver(attachment(email(), attachment))
    end

    inline = %{valid | type: :inline, cid: "duplicate"}
    assert {:error, {:invalid, :attachments}} = deliver(attachment(email(), inline))

    assert {:error, {:invalid, :attachments}} =
             deliver(%{email() | html_body: "html", attachments: [inline, inline]})

    missing = Attachment.new("/missing/postbeam-attachment.txt")
    assert {:error, {:attachment, 0, :enoent}} = deliver(attachment(email(), missing))
    refute_receive {:dns, _, _}
    refute_receive {:attempt, _, _, _}
  end

  test "mailer configuration rejects unknown options without revealing values" do
    for config <- [
          [postbeam: [tls: :bad]],
          [postbeam: [password: "secret-value"]],
          [relay: "secret-value"],
          [postbeam: %{}]
        ] do
      error = assert_raise ArgumentError, fn -> TestMailer.deliver(email(), config) end
      refute Exception.message(error) =~ "secret-value"
    end

    refute_receive {:dns, _, _}
  end

  test "deliver! returns receipts on success and raises on delivery error" do
    assert %{deliveries: [_]} = TestMailer.deliver!(email(), postbeam: @options)
    TestDNS.put("example.net", :mx, {:error, :nxdomain})
    assert_raise Swoosh.DeliveryError, fn -> TestMailer.deliver!(email(), postbeam: @options) end
  end

  test "real SMTP receives the envelope and MIME composed through the mailer" do
    TestDNS.put("example.net", :a, {:ok, [{127, 0, 0, 1}]})

    {port, token} =
      Postbeam.TestReceiver.start(fn socket, parent, token ->
        Postbeam.TestReceiver.greet(socket)
        {from, to} = Postbeam.TestReceiver.envelope(socket)
        data = Postbeam.TestReceiver.data(socket)
        :gen_tcp.send(socket, "250 swoosh-accepted\r\n")
        send(parent, {token, from, to, data})
      end)

    options = [hostname: "mta.example.com", resolver: TestDNS, tls: :never, port: port]

    assert {:ok, %{message_id: id, deliveries: [%{receipt: "swoosh-accepted\r\n"}]}} =
             TestMailer.deliver(email(), postbeam: options)

    assert_receive {^token, "MAIL FROM:<sender@example.com>\r\n",
                    "RCPT TO:<user@example.net>\r\n", data}

    assert data =~ "Message-ID: #{id}"
    assert {"text", "plain", _, _, "Caffè ☕"} = Postbeam.SMTP.MIME.decode(data, encoding: :none)
    Postbeam.TestReceiver.done(token)
  end

  test "text-only, HTML-only and empty body with empty subject are supported" do
    for {text, html} <- [{"plain", nil}, {nil, "<b>html</b>"}, {"", nil}, {nil, ""}] do
      assert {:ok, _} = deliver(%{email() | text_body: text, html_body: html, subject: ""})
      assert_receive {:attempt, _, message, _}
      assert {"text", subtype, _, _, body} = decode(message)
      assert subtype == if(is_nil(text), do: "html", else: "plain")
      assert body == (text || html)
    end
  end

  @spec email() :: Swoosh.Email.t()
  defp email do
    new()
    |> from("sender@example.com")
    |> to("user@example.net")
    |> subject("Caffè ☕")
    |> text_body("Caffè ☕")
  end

  @spec deliver(Swoosh.Email.t()) :: Postbeam.Delivery.result() | {:error, term()}
  defp deliver(email), do: TestMailer.deliver(email, postbeam: @options)

  @spec decode(Postbeam.Message.encoded()) :: tuple()
  defp decode(message), do: Postbeam.SMTP.MIME.decode(message.data, encoding: :none)

  @spec header_value(Postbeam.Headers.t(), String.t()) :: String.t() | nil
  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == String.downcase(name), do: value
    end)
  end
end
