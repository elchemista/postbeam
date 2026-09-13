defmodule Postbeam.StorageTest do
  use ExUnit.Case, async: true

  alias Postbeam.{Config, DKIM, KeyStore, SentStore}
  alias Postbeam.KeyStore.File, as: KeyFile
  alias Postbeam.SentStore.ETS

  defmodule Store do
    @behaviour KeyStore
    @behaviour SentStore

    @impl KeyStore
    def fetch(id, options), do: Agent.get(options[:agent], &Map.get(&1, id, :not_found))

    @impl KeyStore
    def put_new(id, pem, options) do
      Agent.get_and_update(options[:agent], fn keys ->
        if Map.has_key?(keys, id),
          do: {{:error, :already_exists}, keys},
          else: {:ok, Map.put(keys, id, {:ok, pem})}
      end)
    end

    @impl SentStore
    def put(entry, options) do
      send(options[:owner], {:stored, entry})

      case options[:result] do
        :raise -> raise ArgumentError, "secret"
        :exit -> exit(:secret)
        :throw -> throw(:secret)
        result -> result
      end
    end
  end

  defmodule FailingKeyStore do
    @behaviour KeyStore
    @impl true
    def fetch(_id, options) do
      case options[:fetch] do
        :raise -> raise ArgumentError, "secret"
        :throw -> throw(:secret)
        :exit -> exit(:secret)
        result -> result
      end
    end

    @impl true
    def put_new(_id, _pem, options), do: options[:put]
  end

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

  test "key failure prevents SMTP and archiving", %{options: options, directory: directory} do
    assert :ok = KeyFile.put_new({"example.com", "postbeam"}, "bad key", directory: directory)

    assert {:error, {:dkim, :invalid_private_key}} =
             deliver(options ++ [sent_store: {Store, owner: self(), result: :ok}])

    refute_receive {:attempt, _, _, _}
    refute_receive {:stored, _}
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
          sent_store: KeyFile,
          key_store: {Store, [:bad]},
          sent_store: {Store, x: 1, x: 2}
        ] do
      assert {:error, {:invalid_config, ^option}} = Config.new([{option, invalid}])
    end
  end

  test "managed delivery signs and archives exact wire data without configuration", %{
    options: options
  } do
    assert {:ok, record} = DKIM.setup(options)
    assert {:ok, receipt} = deliver(options ++ [sent_store: {Store, owner: self(), result: :ok}])
    assert receipt.storage == :ok
    assert_receive {:stored, entry}
    assert entry.message.message_id == receipt.message_id
    assert entry.message.data =~ "DKIM-Signature:"
    assert entry.receipt == Map.delete(receipt, :storage)
    assert %DateTime{} = entry.accepted_at
    assert Enum.sort(Map.keys(entry)) == [:accepted_at, :message, :receipt]
    assert {:ok, ^record} = DKIM.setup(options)
  end

  test "archive errors and exceptions preserve SMTP success without fallback" do
    for result <- [{:error, :offline}, :raise, :exit, :throw, :invalid] do
      assert {:ok, %{storage: {:error, reason}}} =
               deliver(sent_store: {Store, owner: self(), result: result})

      refute inspect(reason) =~ "secret"
      assert_receive {:attempt, _, _, _}
      assert_receive {:stored, _}
      refute_receive {:attempt, _, _, _}
    end
  end

  test "archives only accepted email and supports disabling storage" do
    assert {:ok, receipt} = deliver(sent_store: nil)
    refute Map.has_key?(receipt, :storage)
    refute_receive {:stored, _}
    Process.put({Postbeam.TestTransport, "example.net"}, {:error, {:permanent, :rejected}})
    assert {:error, {:permanent, _}} = deliver(sent_store: {Store, owner: self(), result: :ok})
    refute_receive {:stored, _}
  end

  test "ETS retains the newest ten records and protects writes" do
    start_supervised!({ETS, name: __MODULE__})
    options = [name: __MODULE__]
    for id <- 1..15, do: assert(:ok = ETS.put(entry(id), options))
    assert {:ok, entries} = ETS.list(options)
    assert Enum.map(entries, & &1.receipt.message_id) == Enum.map(15..6//-1, &Integer.to_string/1)
    assert_raise ArgumentError, fn -> :ets.insert(__MODULE__, {99, entry(99)}) end
  end

  test "ETS bounds concurrent writes and starts empty after supervised restart" do
    owner = start_supervised!({ETS, name: __MODULE__, limit: 3})
    results = 1..30 |> Task.async_stream(&ETS.put(entry(&1), name: __MODULE__)) |> Enum.to_list()
    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, entries} = ETS.list(name: __MODULE__)
    assert length(entries) == 3
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    assert await_restart(supervisor, owner)
    assert {:ok, []} = ETS.list(name: __MODULE__)
  end

  test "default ETS owner is supervised and invalid or unavailable instances are explicit" do
    assert is_pid(Process.whereis(ETS))

    assert Process.whereis(ETS) in elem(
             Process.info(Process.whereis(Postbeam.Supervisor), :links),
             1
           )

    assert {:error, :unavailable} = ETS.list(name: Postbeam.MissingArchive)
    assert {:error, :unavailable} = ETS.put(entry(1), name: Postbeam.MissingArchive)
    assert {:error, :invalid_options} = ETS.list(limit: 2)
    assert {:error, :invalid_options} = ETS.put(entry(1), name: nil)

    for limit <- [0, -1, :infinity],
        do: assert({:error, :invalid_options} = ETS.start_link(limit: limit))

    assert {:error, _} = ETS.start_link([:invalid])
  end

  defp await_restart(supervisor, previous, attempts \\ 50)
  defp await_restart(_, _, 0), do: false

  defp await_restart(supervisor, previous, attempts) do
    case Supervisor.which_children(supervisor) do
      [{__MODULE__, pid, _, _}] when is_pid(pid) and pid != previous ->
        true

      _ ->
        Process.sleep(10)
        await_restart(supervisor, previous, attempts - 1)
    end
  end

  defp deliver(options) do
    Postbeam.deliver(
      [from: "a@example.com", to: "b@example.net", subject: "Stored", text: "Hello"],
      Keyword.merge([resolver: Postbeam.TestDNS, transport: Postbeam.TestTransport], options)
    )
  end

  defp entry(id) do
    id = Integer.to_string(id)

    %{
      message: %Postbeam.Message{
        from: "a@example.com",
        to: "b@example.net",
        subject: "",
        domain: "example.net",
        data: "email",
        message_id: id
      },
      receipt: %{to: "b@example.net", mx: "example.net", receipt: "queued", message_id: id},
      accepted_at: DateTime.utc_now()
    }
  end
end
