defmodule Postbeam.Headers do
  @moduledoc false

  alias Postbeam.Config

  @type t :: [{String.t(), String.t()}]
  @type mailbox :: {String.t(), String.t()}
  @reserved ~w(from to cc bcc reply-to subject sender return-path message-id date mime-version dkim-signature)

  @doc false
  @spec new(term(), atom()) :: {:ok, t()} | {:error, {:invalid, atom()}}
  def new(headers, field) when is_map(headers) and not is_struct(headers),
    do: new(Map.to_list(headers), field)

  def new(headers, field) when is_list(headers) do
    if Enum.all?(headers, &valid?/1) and unique?(headers),
      do: {:ok, headers},
      else: {:error, {:invalid, field}}
  end

  def new(_, field), do: {:error, {:invalid, field}}

  @doc false
  @spec render([mailbox()]) :: String.t()
  def render(mailboxes), do: Enum.map_join(mailboxes, ", ", &render_mailbox/1)

  @spec render_mailbox(mailbox()) :: String.t()
  defp render_mailbox({"", address}), do: address

  defp render_mailbox({name, address}) do
    escaped = String.replace(name, ["\\", "\""], &("\\" <> &1))
    "\"" <> escaped <> "\" <" <> address <> ">"
  end

  @spec valid?(term()) :: boolean()
  defp valid?({name, value}) when is_binary(name) do
    normalized = String.downcase(name)

    Regex.match?(~r/\A[a-zA-Z0-9-]+\z/, name) and
      normalized not in @reserved and
      not String.starts_with?(normalized, ["content-", "resent-"]) and
      Config.header?(value)
  end

  defp valid?(_), do: false

  @spec unique?(t()) :: boolean()
  defp unique?(headers) do
    names = Enum.map(headers, fn {name, _} -> String.downcase(name) end)
    length(names) == MapSet.size(MapSet.new(names))
  end
end
