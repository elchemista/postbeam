defmodule Postbeam.Inbound.Session do
  # The callback names follow the SMTP commands in Postbeam.SMTP.Handler.
  # credo:disable-for-this-file Credo.Check.Readability.FunctionNames
  @moduledoc false

  alias Postbeam.Inbound
  alias Postbeam.SMTP.Handler
  @behaviour Handler
  @typep state :: %{
           config: keyword(),
           peer: :inet.ip_address(),
           helo: binary() | nil,
           tls: boolean()
         }

  alias Postbeam.Config
  alias Postbeam.Inbound.Message

  @impl Handler
  @doc false
  @spec init(iodata(), non_neg_integer(), :inet.ip_address(), keyword()) ::
          {:ok, iodata(), state()}
  def init(hostname, _session_count, peer, options) do
    state = %{config: options, peer: peer, helo: nil, tls: false}
    {:ok, [hostname, " ESMTP Postbeam"], state}
  end

  @impl Handler
  @doc false
  @spec handle_HELO(binary(), state()) :: {:ok, pos_integer(), state()}
  def handle_HELO(hostname, state) do
    {:ok, state.config[:max_size], %{state | helo: hostname}}
  end

  @impl Handler
  @doc false
  @spec handle_EHLO(binary(), list(), state()) :: {:ok, list(), state()}
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

  @impl Handler
  @doc false
  @spec handle_STARTTLS(state()) :: state()
  def handle_STARTTLS(state), do: %{state | tls: true, helo: nil}

  @impl Handler
  @doc false
  @spec handle_MAIL(binary(), state()) :: {:ok, state()}
  def handle_MAIL(_from, state), do: {:ok, state}

  @impl Handler
  @doc false
  @spec handle_MAIL_extension(binary(), state()) :: :error
  def handle_MAIL_extension(_extension, _state), do: :error

  @impl Handler
  @doc false
  @spec handle_RCPT(binary(), state()) :: {:ok, state()} | {:error, charlist(), state()}
  def handle_RCPT(to, state) do
    case call_adapter(state.config[:adapter], :accept_recipient, to) do
      :ok -> {:ok, state}
      {:error, reply} -> {:error, reply, state}
    end
  end

  @impl Handler
  @doc false
  @spec handle_RCPT_extension(binary(), state()) :: :error
  def handle_RCPT_extension(_extension, _state), do: :error

  @impl Handler
  @doc false
  @spec handle_DATA(binary(), [binary()], binary(), state()) ::
          {:ok | :error, charlist(), state()}
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
        else:
          call_adapter(
            state.config[:adapter],
            :handle_message,
            decode_message(message, Keyword.get(state.config, :decode, false))
          )

    case result do
      :ok -> {:ok, ~c"2.0.0 Message accepted", state}
      {:error, reply} -> {:error, reply, state}
    end
  end

  @impl Handler
  @doc false
  @spec handle_RSET(state()) :: state()
  def handle_RSET(state), do: state

  @impl Handler
  @doc false
  @spec handle_VRFY(binary(), state()) :: {:error, charlist(), state()}
  def handle_VRFY(_address, state), do: {:error, ~c"252 Cannot verify user", state}

  @impl Handler
  @doc false
  @spec handle_other(binary(), binary(), state()) :: {charlist(), state()}
  def handle_other(_verb, _arguments, state), do: {~c"500 Command unrecognized", state}

  @impl Handler
  @doc false
  @spec code_change(term(), state(), term()) :: {:ok, state()}
  def code_change(_version, state, _extra), do: {:ok, state}

  @impl Handler
  @doc false
  @spec terminate(term(), state()) :: {:ok, term(), state()}
  def terminate(reason, state), do: {:ok, reason, state}

  @spec decode_message(Message.t(), boolean()) :: Message.t()
  defp decode_message(message, false), do: message

  defp decode_message(message, true) do
    case Message.decode(message) do
      {:ok, decoded} -> decoded
      {:error, reason} -> %{message | decode_error: reason}
    end
  end

  @spec call_adapter(Inbound.adapter(), atom(), term()) :: :ok | {:error, charlist()}
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
