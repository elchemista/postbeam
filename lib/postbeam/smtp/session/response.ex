defmodule Postbeam.SMTP.Session.Response do
  @moduledoc false

  alias Postbeam.SMTP.Session.State

  @doc false
  @spec reply(State.t(), iodata()) :: {:ok, State.t()}
  def reply(state, data), do: reply(state, data, state)

  @doc false
  @spec reply(State.t(), iodata(), State.t()) :: {:ok, State.t()}
  def reply(state, data, next_state) do
    send_reply(state, data)
    {:ok, next_state}
  end

  @doc false
  @spec send_reply(State.t(), iodata()) :: :ok
  def send_reply(state, data) do
    check_result(state.transport.send(state.socket, data), :send_error, state)
  end

  @doc false
  @spec setopts(State.t(), list()) :: :ok
  def setopts(state, options) do
    check_result(state.transport.setopts(state.socket, options), :setopts_error, state)
  end

  @spec check_result(:ok | {:error, term()}, :send_error | :setopts_error, State.t()) :: :ok
  defp check_result(:ok, _kind, _state), do: :ok

  defp check_result({:error, reason}, kind, state) do
    state = handle_error(kind, reason, state)
    throw({:stop, {kind, reason}, state})
  end

  @doc false
  @spec handle_error(
          Postbeam.SMTP.Session.error_class(),
          any(),
          State.t()
        ) :: State.t()
  def handle_error(
        kind,
        details,
        %State{module: module, callbackstate: old_callback_state} = state
      ) do
    case :erlang.function_exported(module, :handle_error, 3) do
      true ->
        case module.handle_error(kind, details, old_callback_state) do
          {:ok, callback_state} ->
            %{state | callbackstate: callback_state}

          {:stop, reason, callback_state} ->
            throw({:stop, reason, %{state | callbackstate: callback_state}})
        end

      false ->
        state
    end
  end
end
