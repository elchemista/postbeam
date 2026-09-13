defmodule Postbeam.Address do
  @moduledoc false
  alias Postbeam.Config

  @doc false
  @spec new(term(), atom()) :: {:ok, String.t(), String.t()} | {:error, {:invalid, atom()}}
  def new(value, field) when is_binary(value) and byte_size(value) <= 254 do
    case String.split(value, "@") do
      [local, domain] ->
        valid =
          byte_size(local) in 1..64 and Config.domain?(domain) and
            Regex.match?(
              ~r/\A[a-zA-Z0-9!#$%&'*+\-\/=?^_`{|}~]+(?:\.[a-zA-Z0-9!#$%&'*+\-\/=?^_`{|}~]+)*\z/,
              local
            )

        if valid,
          do: {:ok, local <> "@" <> String.downcase(domain), String.downcase(domain)},
          else: {:error, {:invalid, field}}

      _ ->
        {:error, {:invalid, field}}
    end
  end

  def new(_, field), do: {:error, {:invalid, field}}
end
