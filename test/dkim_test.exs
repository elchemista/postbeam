defmodule Postbeam.DKIMTest do
  use ExUnit.Case, async: true

  for mode <- [:explicit, :managed] do
    test "#{mode} RSA DKIM signature and body hash verify against the public key" do
      {public_key, signing_options} = signing_options(unquote(mode))

      assert {:ok, _} =
               Postbeam.deliver(
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
      {headers, body} = :mimemail.parse_headers(message.data)
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
      assert tags["a"] == "rsa-sha256"
      assert tags["c"] == "relaxed/simple"
      body_hash = :crypto.hash(:sha256, String.trim_trailing(body, "\r\n") <> "\r\n")
      assert Base.decode64!(tags["bh"]) == body_hash

      signed_headers =
        for name <- String.split(tags["h"], ":") do
          {key, value} =
            Enum.find(Enum.reverse(headers), fn {key, _} -> String.downcase(key) == name end)

          canonical(key, value) <> "\r\n"
        end

      unsigned = Regex.replace(~r/\bb=[^;]*/, signature_header, "b=")
      signed = IO.iodata_to_binary(signed_headers) <> canonical("DKIM-Signature", unsigned)
      signature = Base.decode64!(String.replace(tags["b"], ~r/\s/, ""))
      assert :public_key.verify(signed, :sha256, signature, public_key)
      refute :public_key.verify(signed <> "tampered", :sha256, signature, public_key)
    end
  end

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

  defp canonical(name, value),
    do: String.downcase(name) <> ":" <> (value |> String.replace(~r/[\s]+/, " ") |> String.trim())
end
