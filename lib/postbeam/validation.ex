defmodule Postbeam.Validation do
  @moduledoc false

  @doc false
  @spec check(boolean(), atom()) :: :ok | {:error, {:invalid, atom()}}
  def check(true, _field), do: :ok
  def check(false, field), do: {:error, {:invalid, field}}

  @doc false
  @spec map([input], (input -> {:ok, output} | {:error, error})) ::
          {:ok, [output]} | {:error, error}
        when input: var, output: var, error: var
  def map(values, convert) do
    result =
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case convert.(value) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, reversed} <- result, do: {:ok, Enum.reverse(reversed)}
  end
end
