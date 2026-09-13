defmodule Postbeam.Attachment do
  @moduledoc false

  alias Postbeam.Config
  alias Postbeam.Headers

  @enforce_keys [:filename, :content_type, :type]
  defstruct [:filename, :content_type, :type, :cid, :path, :data, headers: []]

  @type t :: %__MODULE__{
          filename: String.t(),
          content_type: String.t(),
          type: :attachment | :inline,
          cid: String.t() | nil,
          path: String.t() | nil,
          data: binary() | nil,
          headers: Headers.t()
        }
  @type error :: {:attachment, non_neg_integer(), atom()}

  @doc false
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid, :attachments}}
  def new(fields) do
    filename = fields[:filename] || filename(fields[:path])
    type = fields[:type]
    cid = if type == :inline, do: fields[:cid] || filename, else: fields[:cid]
    content_type = fields[:content_type] || "application/octet-stream"

    with :ok <- validate(nonempty_header?(filename)),
         :ok <- validate(content_type?(content_type)),
         :ok <- validate(type in [:attachment, :inline]),
         :ok <- validate(cid?(cid, type)),
         :ok <- validate(source?(fields[:data], fields[:path])),
         {:ok, headers} <- Headers.new(fields[:headers], :attachments) do
      {:ok,
       %__MODULE__{
         filename: filename,
         content_type: content_type,
         type: type,
         cid: cid,
         path: fields[:path],
         data: fields[:data],
         headers: headers
       }}
    end
  end

  @doc false
  @spec load([t()]) :: {:ok, [t()]} | {:error, error()}
  def load(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, loaded} ->
      case read(attachment) do
        {:ok, data} ->
          {:cont, {:ok, [%{attachment | data: data, path: nil} | loaded]}}

        {:error, reason} ->
          {:halt, {:error, {:attachment, index, reason}}}
      end
    end)
    |> reverse_loaded()
  end

  @spec reverse_loaded({:ok, [t()]} | {:error, error()}) :: {:ok, [t()]} | {:error, error()}
  defp reverse_loaded({:ok, loaded}), do: {:ok, Enum.reverse(loaded)}
  defp reverse_loaded({:error, _} = error), do: error

  @spec read(t()) :: {:ok, binary()} | {:error, atom()}
  defp read(%__MODULE__{data: data}) when is_binary(data), do: {:ok, data}
  defp read(%__MODULE__{path: path}), do: File.read(path)

  @spec filename(term()) :: String.t() | nil
  defp filename(path) when is_binary(path), do: Path.basename(path)
  defp filename(_), do: nil

  @spec nonempty_header?(term()) :: boolean()
  defp nonempty_header?(value), do: Config.header?(value) and value != ""

  @spec content_type?(term()) :: boolean()
  defp content_type?(value) when is_binary(value) do
    # Composite MIME entities cannot be base64 encoded as opaque attachments.
    not String.starts_with?(String.downcase(value), ["message/", "multipart/"]) and
      Regex.match?(~r/\A[a-zA-Z0-9!#$&^_.+-]+\/[a-zA-Z0-9!#$&^_.+-]+\z/, value)
  end

  defp content_type?(_), do: false

  @spec cid?(term(), :attachment | :inline) :: boolean()
  defp cid?(nil, :attachment), do: true

  defp cid?(cid, _) when is_binary(cid),
    do: Regex.match?(~r/\A[a-zA-Z0-9.!#$%&'*+\-\/=?^_`{|}~@]+\z/, cid)

  defp cid?(_, _), do: false

  @spec source?(term(), term()) :: boolean()
  defp source?(data, _) when is_binary(data), do: true
  defp source?(nil, path), do: nonempty_header?(path)
  defp source?(_, _), do: false

  @spec validate(boolean()) :: :ok | {:error, {:invalid, :attachments}}
  defp validate(true), do: :ok
  defp validate(false), do: {:error, {:invalid, :attachments}}
end
