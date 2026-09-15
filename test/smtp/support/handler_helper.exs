# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Readability.FunctionNames
defmodule Postbeam.SMTP.TestHandler do
  @behaviour Postbeam.SMTP.Handler
  def init(host, _sessions, _peer, opts), do: {:ok, [host, " test"], Map.new(opts)}
  def handle_HELO(_host, state), do: {:ok, state}

  def handle_EHLO(_host, extensions, state) do
    extensions =
      if Map.get(state, :tls), do: extensions ++ [{~c"STARTTLS", true}], else: extensions

    {:ok, extensions, state}
  end

  def handle_MAIL(_from, state), do: {:ok, state}
  def handle_RCPT(_to, state), do: {:ok, state}

  def handle_DATA(from, to, data, state) do
    send(state.owner, {:delivery_started, self(), from, to, data})

    if Map.get(state, :hold),
      do:
        (receive do
           :release -> :ok
         end)

    {:ok, "queued", state}
  end

  def handle_MAIL_extension(_, _), do: :error
  def handle_RCPT_extension(_, _), do: :error
  def handle_RSET(state), do: state
  def handle_VRFY(_, state), do: {:error, ~c"252 Cannot verify", state}
  def handle_STARTTLS(state), do: state
  def handle_other(_, _, state), do: {~c"500 Unknown command", state}
  def code_change(_, state, _), do: {:ok, Map.put(state, :upgraded, true)}
  def terminate(_, _), do: :ok
end
