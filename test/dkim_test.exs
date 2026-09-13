defmodule Postbeam.DKIMTest do
  use ExUnit.Case, async: true

  for mode <- [:explicit, :managed, :ed25519],
      interface <- [:native, :swoosh],
      c14n <- [:relaxed, :simple] do
    test "#{interface} #{mode} #{c14n} DKIM signature and body hash verify against the public key" do
      {public_key, signing_options} = signing_options(unquote(mode))

      signing_options =
        Keyword.update!(signing_options, :dkim, &Keyword.put(&1, :c, {unquote(c14n), :simple}))

      assert {:ok, _} =
               deliver(
                 unquote(interface),
                 [
                   from: "sender@example.com",
                   to: "user@example.net",
                   subject: "Caffè ☕",
                   text: "Caffè ☕",
                   html: "<p>Caffè ☕</p>"
                 ],
                 Keyword.merge(
                   [
                     hostname: "mta.example.com",
                     resolver: Postbeam.TestDNS,
                     transport: Postbeam.TestTransport
                   ],
                   signing_options
                 )
               )

      assert_receive {:attempt, _, message, _}

      if unquote(interface) == :swoosh do
        assert_receive {:attempt, _, copy, _}
        assert copy.to == "copy@example.org"
        assert copy.data == message.data
        assert copy.message_id == message.message_id
      end

      [header_block, body] = :binary.split(message.data, "\r\n\r\n")

      headers =
        ~r/\r\n(?![ \t])/
        |> Regex.split(header_block)
        |> Enum.map(fn header ->
          [name, value] = String.split(header, ":", parts: 2)
          {name, String.trim_leading(value, " ")}
        end)

      {_, signature_header} = List.keyfind(headers, "DKIM-Signature", 0)

      tags =
        signature_header
        |> String.split(";")
        |> Map.new(fn pair ->
          [key, value] = pair |> String.trim() |> String.split("=", parts: 2)
          {key, value}
        end)

      assert tags["d"] == "example.com"
      assert tags["s"] == "test"
      assert tags["a"] == if(unquote(mode) == :ed25519, do: "ed25519-sha256", else: "rsa-sha256")
      assert tags["c"] == "#{unquote(c14n)}/simple"
      body_hash = :crypto.hash(:sha256, String.trim_trailing(body, "\r\n") <> "\r\n")
      assert Base.decode64!(tags["bh"]) == body_hash

      signed_headers =
        for name <- String.split(tags["h"], ":") do
          {key, value} =
            Enum.find(Enum.reverse(headers), fn {key, _} -> String.downcase(key) == name end)

          canonical(key, value, unquote(c14n)) <> "\r\n"
        end

      unsigned = Regex.replace(~r/\bb=[^;]*/, signature_header, "b=")

      signed =
        IO.iodata_to_binary(signed_headers) <>
          canonical("DKIM-Signature", unsigned, unquote(c14n))

      signature = Base.decode64!(String.replace(tags["b"], ~r/\s/, ""))

      {signed, digest} =
        if unquote(mode) == :ed25519,
          do: {:crypto.hash(:sha256, signed), :none},
          else: {signed, :sha256}

      assert :public_key.verify(signed, digest, signature, public_key)
      refute :public_key.verify(signed <> "tampered", digest, signature, public_key)
    end
  end

  @spec deliver(:native | :swoosh, keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp deliver(:native, fields, options), do: Postbeam.deliver(fields, options)

  defp deliver(:swoosh, fields, options) do
    email =
      Swoosh.Email.new(
        from: {"Caffè team", fields[:from]},
        to: fields[:to],
        subject: fields[:subject],
        text_body: fields[:text],
        html_body: fields[:html]
      )
      |> Swoosh.Email.cc("copy@example.org")
      |> Swoosh.Email.attachment(
        Swoosh.Attachment.new({:data, <<0, 255, 42>>},
          filename: "dati.bin",
          content_type: "application/octet-stream"
        )
      )

    Postbeam.TestMailer.deliver(email, postbeam: options)
  end

  @spec signing_options(:explicit | :managed | :ed25519) :: {tuple(), keyword()}
  defp signing_options(:explicit) do
    key = :public_key.generate_key({:rsa, 1024, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    {{:RSAPublicKey, elem(key, 2), elem(key, 3)},
     [dkim: [d: "example.com", s: "test", private_key: {:pem_plain, pem}]]}
  end

  defp signing_options(:managed) do
    directory =
      Path.join(System.tmp_dir!(), "postbeam-sign-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    options = [
      dkim: [d: "example.com", s: "test"],
      key_store: {Postbeam.KeyStore.File, directory: directory}
    ]

    assert {:ok, record} = Postbeam.DKIM.setup(options)
    "v=DKIM1; k=rsa; p=" <> public = record.value

    key =
      :public_key.pem_entry_decode(
        {:SubjectPublicKeyInfo, Base.decode64!(public), :not_encrypted}
      )

    {key, options}
  end

  defp signing_options(:ed25519) do
    key = :public_key.generate_key({:namedCurve, :ed25519})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
    public = {{:ECPoint, elem(key, 4)}, elem(key, 3)}

    {public,
     [dkim: [a: :"ed25519-sha256", d: "example.com", s: "test", private_key: {:pem_plain, pem}]]}
  end

  @spec canonical(String.t(), String.t(), :simple | :relaxed) :: String.t()
  defp canonical(name, value, :simple), do: name <> ": " <> value

  defp canonical(name, value, :relaxed),
    do: String.downcase(name) <> ":" <> (value |> String.replace(~r/[\s]+/, " ") |> String.trim())
end
