defmodule Postbeam.Store do
  @moduledoc false

  alias Postbeam.Config

  @type adapter :: module() | {module(), keyword()}

  @spec valid?(term(), [{atom(), non_neg_integer()}]) :: boolean()
  @doc false
  def valid?({module, options}, callbacks) do
    match?({:ok, _}, Config.keyword(options, :store)) and
      is_atom(module) and Code.ensure_loaded?(module) and
      Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  def valid?(module, callbacks) when is_atom(module), do: valid?({module, []}, callbacks)
  def valid?(_, _), do: false

  # Exceptions/exits must not leak keys or turn SMTP acceptance into a retry.
  @spec call(adapter(), atom(), [term()]) :: term()
  @doc false
  def call({module, options}, function, arguments) do
    apply(module, function, arguments ++ [options])
  rescue
    error -> {:error, {:adapter_exception, error.__struct__}}
  catch
    kind, _ -> {:error, {:adapter_failure, kind}}
  end

  def call(module, function, arguments), do: call({module, []}, function, arguments)
end
