defmodule Postbeam.Inbound.Session do
  # The callback names follow the SMTP commands in Postbeam.SMTP.Handler.
  # credo:disable-for-this-file Credo.Check.Readability.FunctionNames
  @moduledoc false
  @behaviour Postbeam.SMTP.Handler

  alias Postbeam.Config
  alias Postbeam.Inbound.Message

  @impl true
  def init(hostname, _session_count, peer, options) do
    state = %{config: options, peer: peer, helo: nil, tls: false}
    {:ok, [hostname, " ESMTP Postbeam"], state}
  end

  @impl true
  def handle_HELO(hostname, state) do
    {:ok, state.config[:max_size], %{state | helo: hostname}}
  end

  @impl true
  def handle_EHLO(hostname, extensions, state) do
    extensions =
      extensions
      |> List.keydelete(~c"SIZE", 0)
      |> List.keydelete(~c"SMTPUTF8", 0)

    extensions = [{~c"SIZE", Integer.to_charlist(state.config[:max_size])} | extensions]

    extensions =
      if state.config[:tls_options] != [] and not state.tls,
        do: extensions ++ [{~c"STARTTLS", true}],
        else: extensions

    {:ok, extensions, %{state | helo: hostname}}
  end

  @impl true
  def handle_STARTTLS(state), do: %{state | tls: true, helo: nil}

  @impl true
  def handle_MAIL(_from, state), do: {:ok, state}

  @impl true
  def handle_MAIL_extension(_extension, _state), do: :error

  @impl true
  def handle_RCPT(to, state) do
    case call_adapter(state.config[:adapter], :accept_recipient, to) do
      :ok -> {:ok, state}
      {:error, reply} -> {:error, reply, state}
    end
  end

  @impl true
  def handle_RCPT_extension(_extension, _state), do: :error

  @impl true
  def handle_DATA(from, to, data, state) do
    # The DATA reader removes the CRLF preceding the SMTP terminator along with it.
    # Restore the final message line ending before handing the MIME bytes over.
    data = data <> "\r\n"

    message = %Message{
      from: from,
      to: to,
      data: data,
      peer: state.peer,
      helo: state.helo,
      tls: state.tls
    }

    result =
      if byte_size(data) > state.config[:max_size],
        do: {:error, ~c"552 Message too large"},
        else: call_adapter(state.config[:adapter], :handle_message, message)

    case result do
      :ok -> {:ok, ~c"2.0.0 Message accepted", state}
      {:error, reply} -> {:error, reply, state}
    end
  end

  @impl true
  def handle_RSET(state), do: state

  @impl true
  def handle_VRFY(_address, state), do: {:error, ~c"252 Cannot verify user", state}

  @impl true
  def handle_other(_verb, _arguments, state), do: {~c"500 Command unrecognized", state}

  @impl true
  def code_change(_version, state, _extra), do: {:ok, state}

  @impl true
  def terminate(reason, state), do: {:ok, reason, state}

  @spec call_adapter(Postbeam.Inbound.adapter(), atom(), term()) :: :ok | {:error, charlist()}
  defp call_adapter({module, options}, function, argument) do
    module |> apply(function, [argument, options]) |> response()
  rescue
    _ -> temporary_failure()
  catch
    _, _ -> temporary_failure()
  end

  defp call_adapter(module, function, argument),
    do: call_adapter({module, []}, function, argument)

  @spec response(term()) :: :ok | {:error, charlist()}
  defp response(:ok), do: :ok

  defp response({:error, {kind, message}}) when kind in [:temporary, :permanent] do
    if Config.header?(message) and byte_size(message) in 1..400 do
      prefix = if kind == :temporary, do: "451 4.3.0 ", else: "550 5.7.1 "
      {:error, :binary.bin_to_list(prefix <> message)}
    else
      temporary_failure()
    end
  end

  defp response(_), do: temporary_failure()

  @spec temporary_failure() :: {:error, charlist()}
  defp temporary_failure, do: {:error, ~c"451 4.3.0 Incoming mail handler failed"}
end
