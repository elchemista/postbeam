defmodule Postbeam.ApplicationTest do
  use ExUnit.Case, async: false

  test "startup prepares configured keys, reuses them on restart and fails on corruption" do
    previous = Application.get_all_env(:postbeam)

    directory =
      Path.join(System.tmp_dir!(), "postbeam-boot-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      _ = Application.stop(:postbeam)

      for {key, _} <- Application.get_all_env(:postbeam),
          do: Application.delete_env(:postbeam, key)

      for {key, value} <- previous, do: Application.put_env(:postbeam, key, value)
      {:ok, _} = Application.ensure_all_started(:postbeam)
      File.rm_rf!(directory)
    end)

    :ok = Application.stop(:postbeam)
    Application.put_env(:postbeam, :dkim, d: "example.com", s: "boot")
    Application.put_env(:postbeam, :key_store, {Postbeam.KeyStore.File, directory: directory})
    assert {:ok, _} = Application.ensure_all_started(:postbeam)
    path = Path.join(directory, "example.com/boot.pem")
    assert File.exists?(path)
    assert {:ok, record} = Postbeam.DKIM.setup()
    assert :ok = Application.stop(:postbeam)
    assert {:ok, _} = Application.ensure_all_started(:postbeam)
    assert {:ok, ^record} = Postbeam.DKIM.setup()

    assert :ok = Application.stop(:postbeam)
    File.write!(path, "corrupt")

    assert {:error, {:postbeam, {{:dkim, :invalid_private_key}, _}}} =
             Application.ensure_all_started(:postbeam)

    assert File.read!(path) == "corrupt"
  end
end
