defmodule Postbeam.SMTP.SessionResponseTest do
  use ExUnit.Case, async: true

  alias Postbeam.SMTP.Session
  alias Postbeam.SMTP.Session.Envelope
  alias Postbeam.SMTP.Session.Response
  alias Postbeam.SMTP.Session.State
  alias Postbeam.SMTP.Session.Transaction

  @doc false
  @spec send(:ok | {:error, atom()}, iodata()) :: :ok | {:error, atom()}
  def send(result, data) do
    Kernel.send(self(), {:wire_reply, IO.iodata_to_binary(data)})
    result
  end

  @doc false
  @spec setopts(:ok | {:error, atom()}, list()) :: :ok | {:error, atom()}
  def setopts(result, _options), do: result

  @doc false
  @spec handle_error(atom(), term(), atom()) :: {:ok, atom()} | {:stop, atom(), atom()}
  def handle_error(kind, reason, state) do
    Kernel.send(self(), {:callback_error, kind, reason, state})
    if state == :stop, do: {:stop, :callback_stop, :stopped}, else: {:ok, :error_handled}
  end

  # Handler callbacks are named after SMTP commands.
  @doc false
  @spec handle_MAIL(binary(), atom()) :: {:ok, atom()}
  # credo:disable-for-next-line Credo.Check.Readability.FunctionNames
  def handle_MAIL(_sender, _state), do: {:ok, :sender_accepted}

  @spec state(:ok | {:error, atom()}, atom()) :: State.t()
  defp state(result, callback_state \\ :initial) do
    %State{
      transport: __MODULE__,
      socket: result,
      module: __MODULE__,
      callbackstate: callback_state,
      envelope: %Envelope{}
    }
  end

  test "a successful reply commits the callback state and envelope" do
    assert {:ok, updated} = Transaction.mail("FROM:<sender@example.com>", state(:ok))
    assert updated.envelope.from == "sender@example.com"
    assert updated.callbackstate == :sender_accepted
    assert_received {:wire_reply, "250 sender Ok\r\n"}
  end

  test "a failed reply reports the previous callback state before committing MAIL" do
    assert {:stop, {:send_error, :closed}, updated} =
             catch_throw(Transaction.mail("FROM:<sender@example.com>", state({:error, :closed})))

    assert_received {:callback_error, :send_error, :closed, :initial}
    assert updated.callbackstate == :error_handled
    assert updated.envelope.from == :undefined
  end

  test "socket option errors preserve the callback error result" do
    assert {:stop, {:setopts_error, :einval}, updated} =
             catch_throw(Response.setopts(state({:error, :einval}), active: :once))

    assert_received {:callback_error, :setopts_error, :einval, :initial}
    assert updated.callbackstate == :error_handled
  end

  test "a callback can replace the stop reason after a transport error" do
    assert {:stop, :callback_stop, updated} =
             catch_throw(Response.send_reply(state({:error, :closed}, :stop), "250 OK\r\n"))

    assert updated.callbackstate == :stopped
  end

  test "an inconsistent SASL state returns 501 and clears the pending exchange" do
    initial = %{
      state(:ok)
      | waitingauth: :plain,
        authdata: "previous challenge",
        envelope: %Envelope{auth: {"previous user", "previous credential"}}
    }

    packet = Base.encode64(<<0, "user", 0, "pass">>) <> "\r\n"
    assert {:noreply, updated, _timeout} = Session.handle_info({:tcp, :ok, packet}, initial)
    assert_received {:wire_reply, "501 Invalid AUTH response\r\n"}
    assert updated.waitingauth == false
    assert updated.authdata == :undefined
    assert updated.envelope.auth == {"", ""}
  end
end
