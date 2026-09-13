defmodule Postbeam.StorageTest do
  use ExUnit.Case, async: true

  alias Postbeam.Config
  alias Postbeam.DKIM
  alias Postbeam.KeyStore.File, as: KeyFile
  alias Postbeam.StorageTest.FailingKeyStore
  alias Postbeam.StorageTest.Store

  setup context do
    directory =
      Path.join(
        System.tmp_dir!(),
        "postbeam-keys-#{context.test}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok,
     options: [
       dkim: [d: "Example.COM", s: "Postbeam"],
       key_store: {KeyFile, directory: directory}
     ],
     directory: directory}
  end

  test "generates a reusable 2048-bit key and a public SPKI DNS record", %{
    options: options,
    directory: directory
  } do
    assert {:ok, record} = DKIM.setup(options)
    assert record.type == :txt
    assert record.host == "postbeam._domainkey"
    assert record.name == "postbeam._domainkey.example.com"
    assert "v=DKIM1; k=rsa; p=" <> public = record.value

    assert {:RSAPublicKey, modulus, 65_537} =
             :public_key.pem_entry_decode(
               {:SubjectPublicKeyInfo, Base.decode64!(public), :not_encrypted}
             )

    assert bit_size(:binary.encode_unsigned(modulus)) == 2048
    path = Path.join(directory, "example.com/postbeam.pem")
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    original = File.read!(path)
    assert {:ok, ^record} = DKIM.setup(options)
    assert File.read!(path) == original
    assert File.ls!(Path.dirname(path)) == ["postbeam.pem"]
  end

  test "concurrent first use publishes exactly one complete key", %{options: options} do
    records =
      1..8
      |> Task.async_stream(fn _ -> DKIM.setup(options) end, timeout: 30_000)
      |> Enum.map(fn {:ok, {:ok, record}} -> record end)

    assert length(Enum.uniq(records)) == 1
  end

  test "custom atomic key store works with concurrent setup" do
    agent = start_supervised!({Agent, fn -> %{} end})
    options = [dkim: [d: "example.com", s: "postbeam"], key_store: {Store, agent: agent}]

    records =
      1..4
      |> Task.async_stream(fn _ -> DKIM.setup(options) end, timeout: 30_000)
      |> Enum.map(fn {:ok, {:ok, record}} -> record end)

    assert length(Enum.uniq(records)) == 1
    assert map_size(Agent.get(agent, & &1)) == 1
  end

  test "stored errors and corrupt keys never trigger rotation", %{
    options: options,
    directory: directory
  } do
    assert :ok = KeyFile.put_new({"example.com", "postbeam"}, "corrupt", directory: directory)
    assert {:error, {:dkim, :invalid_private_key}} = DKIM.setup(options)
    assert {:ok, "corrupt"} = KeyFile.fetch({"example.com", "postbeam"}, directory: directory)

    assert {:error, :already_exists} =
             KeyFile.put_new({"example.com", "postbeam"}, "replacement", directory: directory)

    # Force an OS error rather than a missing key.
    File.write!(Path.join(directory, "file"), "not a directory")

    options =
      Keyword.put(options, :key_store, {KeyFile, directory: Path.join(directory, "file/nope")})

    assert {:error, {:dkim, {:store, :enotdir}}} = DKIM.setup(options)
  end

  test "key store failures are sanitized and writes cannot silently fail" do
    for result <- [:raise, :throw, :exit, :invalid, {:ok, 42}, {:error, :offline}] do
      assert {:error, {:dkim, reason}} =
               DKIM.setup(
                 dkim: [d: "a.test", s: "s"],
                 key_store: {FailingKeyStore, fetch: result}
               )

      refute inspect(reason) =~ "secret"
    end

    for result <- [{:error, :readonly}, :unexpected, {:error, :already_exists}] do
      assert {:error, {:dkim, _}} =
               DKIM.setup(
                 dkim: [d: "a.test", s: "s"],
                 key_store: {FailingKeyStore, fetch: :not_found, put: result}
               )
    end
  end

  test "key failure prevents SMTP", %{options: options, directory: directory} do
    assert :ok = KeyFile.put_new({"example.com", "postbeam"}, "bad key", directory: directory)

    assert {:error, {:dkim, :invalid_private_key}} =
             deliver(options)

    refute_receive {:attempt, _, _, _}
  end

  test "store identities reject traversal and setup requires managed RSA" do
    assert {:error, :invalid_key_path} = KeyFile.fetch({"../escape", "postbeam"}, [])

    assert {:error, :invalid_key_path} =
             KeyFile.put_new({"example.com", "../../escape"}, "pem", [])

    assert {:error, {:dkim, :not_configured}} = DKIM.setup(dkim: nil)

    assert {:error, {:dkim, :explicit_private_key}} =
             DKIM.setup(dkim: [d: "a.test", s: "s", private_key: {:pem_plain, "pem"}])

    assert {:error, {:invalid_config, :dkim}} =
             Config.new(dkim: [d: "a.test", s: "s", a: :"ed25519-sha256"])

    for {option, invalid} <- [
          key_store: nil,
          key_store: {Store, [:bad]},
          key_store: {Store, x: 1, x: 2}
        ] do
      assert {:error, {:invalid_config, ^option}} = Config.new([{option, invalid}])
    end
  end

  defp deliver(options) do
    Postbeam.deliver(
      [from: "a@example.com", to: "b@example.net", subject: "Stored", text: "Hello"],
      Keyword.merge([resolver: Postbeam.TestDNS, transport: Postbeam.TestTransport], options)
    )
  end
end
