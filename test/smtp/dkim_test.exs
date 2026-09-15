defmodule Postbeam.SMTP.DKIMTest do
  use ExUnit.Case, async: true

  alias Postbeam.SMTP.DKIM

  test "relaxed body canonicalization follows RFC 6376 section 3.4.4 and its example" do
    for {body, expected} <- [
          {" C \r\nD \t E\r\n\r\n\r\n", " C\r\nD E\r\n"},
          {"", ""},
          {"\r\n\r\n", ""},
          {" \t\r\n\t \r\n \t", ""},
          {" \tA\t  B \t", " A B\r\n"},
          {"\r\nA\r\n \t\r\nB\r\n", "\r\nA\r\n\r\nB\r\n"},
          {<<255, 32, 9, 254, 32, 13, 10>>, <<255, 32, 254, 13, 10>>},
          {"a\v\fb\r\n", "a\v\fb\r\n"}
        ] do
      assert DKIM.canonicalize_body(body, :relaxed) == expected
    end

    assert Base.encode64(:crypto.hash(:sha256, DKIM.canonicalize_body("", :relaxed))) ==
             "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
  end

  test "relaxed signing hashes the canonical body and tolerates only the allowed whitespace changes" do
    headers = ["From: sender@example.com", "Subject: Signed"]
    [signature | _] = sign(headers, " A \t B\t\r\n\t\r\n", c: {:relaxed, :relaxed})
    assert tag(signature, "c") == "relaxed/relaxed"
    assert tag(signature, "bh") == Base.encode64(:crypto.hash(:sha256, " A B\r\n"))
    assert verify(signature, ["from:sender@example.com", "subject:Signed"])

    [equivalent | _] = sign(headers, " A B\r\n", c: {:relaxed, :relaxed})
    assert signature == equivalent
    [changed | _] = sign(headers, " A\r\nB\r\n", c: {:relaxed, :relaxed})
    refute signature == changed
  end

  test "repeated signed names consume headers from the bottom and permit oversigning" do
    headers = [
      "From: sender@example.com",
      "X-Trace: first",
      "x-trace: second",
      "X-TRACE: third"
    ]

    for {names, selected} <- [
          {["from", "x-trace"], ["from:sender@example.com", "x-trace:third"]},
          {["from", "x-trace", "X-Trace"],
           ["from:sender@example.com", "x-trace:third", "x-trace:second"]},
          {["from", "x-trace", "x-trace", "x-trace", "x-trace"],
           ["from:sender@example.com", "x-trace:third", "x-trace:second", "x-trace:first"]}
        ] do
      [signature | _] = sign(headers, "body", h: names)
      assert verify(signature, selected)
      refute verify(signature, selected ++ ["x-trace:injected"])
    end
  end

  test "default signatures protect message identity, MIME metadata and visible recipients" do
    fields = [
      {"From", "sender@example.com"},
      {"To", "recipient@example.net"},
      {"Cc", "copy@example.org"},
      {"Reply-To", "replies@example.com"},
      {"Subject", "Signed"},
      {"Date", "Tue, 15 Sep 2026 12:00:00 +0200"},
      {"Message-ID", "<id@example.com>"},
      {"MIME-Version", "1.0"},
      {"Content-Type", "text/plain"},
      {"Content-Transfer-Encoding", "7bit"}
    ]

    headers = Enum.map(fields, fn {name, value} -> name <> ": " <> value end)
    canonical = Enum.map(fields, fn {name, value} -> String.downcase(name) <> ":" <> value end)
    [signature | _] = sign(headers, "body")
    assert verify(signature, canonical)

    for index <- 0..(length(canonical) - 1) do
      refute verify(signature, List.update_at(canonical, index, &(&1 <> "changed")))
    end
  end

  defp sign(headers, body, options \\ []) do
    DKIM.sign(
      headers,
      body,
      Keyword.merge(
        [
          d: "example.com",
          s: "test",
          private_key: {:pem_plain, File.read!("test/smtp/fixtures/dkim-rsa-private.pem")}
        ],
        options
      )
    )
  end

  defp tag(signature, name) do
    signature
    |> String.replace(~r/[\r\n\t ]/, "")
    |> String.split(":", parts: 2)
    |> List.last()
    |> String.split(";")
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Map.new(fn [key, value] -> {key, value} end)
    |> Map.fetch!(name)
  end

  defp verify(signature, canonical_headers) do
    [entry] =
      "test/smtp/fixtures/dkim-rsa-public.pem"
      |> File.read!()
      |> :public_key.pem_decode()

    public_key = :public_key.pem_entry_decode(entry)
    unsigned = Regex.replace(~r/\bb=[^;]*/, signature, "b=")
    [name, value] = String.split(unsigned, ":", parts: 2)

    canonical_signature =
      String.downcase(name) <>
        ":" <>
        (value
         |> String.replace(~r/\r\n/, "")
         |> String.replace(~r/[\t ]+/, " ")
         |> String.trim())

    signed = Enum.join(canonical_headers, "\r\n") <> "\r\n" <> canonical_signature
    :public_key.verify(signed, :sha256, Base.decode64!(tag(signature, "b")), public_key)
  end
end
