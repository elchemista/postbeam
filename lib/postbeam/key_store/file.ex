defmodule Postbeam.KeyStore.File do
  @moduledoc """
  Default DKIM store under the Postbeam application's `priv/keys` directory.

  Override with `{Postbeam.KeyStore.File, directory: "/persistent/keys"}`.
  Files are `<directory>/<domain>/<selector>.pem`, written with mode `0600`.
  A synced temporary file is published using an atomic hard link, so concurrent
  writers cannot overwrite an existing key or expose a partial PEM.

  The directory must be writable, trusted, and persistent across deployments.
  This adapter does not back up keys, follow deployment migrations or rotate
  them. Use a shared persistent store for multiple nodes using the same selector.
  """
  @behaviour Postbeam.KeyStore

  @impl true
  def fetch(id, options) do
    with {:ok, path} <- path(id, options) do
      case File.read(path) do
        {:error, :enoent} -> :not_found
        result -> result
      end
    end
  end

  @impl true
  def put_new(id, pem, options) do
    with {:ok, path} <- path(id, options),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      publish(path, pem)
    end
  end

  defp path({domain, selector}, options) do
    directory =
      Keyword.get_lazy(options, :directory, fn -> Application.app_dir(:postbeam, "priv/keys") end)

    if Postbeam.Config.domain?(domain) and Postbeam.Config.domain?(selector) and
         is_binary(directory) and Keyword.keys(options) -- [:directory] == [] do
      {:ok, Path.join([directory, domain, selector <> ".pem"])}
    else
      {:error, :invalid_key_path}
    end
  end

  defp publish(path, pem) do
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(file, pem),
             :ok <- :file.sync(file) do
          case File.ln(temporary, path) do
            {:error, :eexist} -> {:error, :already_exists}
            result -> result
          end
        end
      after
        _ = File.close(file)
        _ = File.rm(temporary)
      end
    end
  end
end
