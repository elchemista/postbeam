defmodule Postbeam.SMTP.Session.Transaction do
  @moduledoc false

  alias Postbeam.SMTP.Binary
  alias Postbeam.SMTP.Session.Address
  alias Postbeam.SMTP.Session.Envelope
  alias Postbeam.SMTP.Session.Response
  alias Postbeam.SMTP.Session.State

  @typep result :: {:ok, State.t()}

  @doc false
  @spec mail(binary(), State.t()) :: result()
  def mail(_args, %State{envelope: %Envelope{from: from}} = state) when from != :undefined do
    Response.reply(state, "503 Error: Nested MAIL command\r\n")
  end

  def mail(args, state) do
    with {:ok, address} <- command_address(args, "FROM:", "MAIL FROM:<address>"),
         {:ok, sender, extra} <- parse_address(address, state, :sender),
         {:ok, updated} <- mail_options(extra, state) do
      accept_sender(sender, state, updated)
    else
      {:error, message} -> Response.reply(state, message)
    end
  end

  @doc false
  @spec recipient(binary(), State.t()) :: result()
  def recipient(_args, %State{envelope: %Envelope{from: :undefined}} = state) do
    Response.reply(state, "503 Error: need MAIL command\r\n")
  end

  def recipient(args, state) do
    with :ok <- recipient_capacity(state),
         {:ok, address} <- command_address(args, "TO:", "RCPT TO:<address>"),
         {:ok, recipient, extra} <- parse_address(address, state, :recipient) do
      accept_recipient(recipient, extra, state)
    else
      {:error, message} -> Response.reply(state, message)
    end
  end

  @spec recipient_capacity(State.t()) :: :ok | {:error, binary()}
  defp recipient_capacity(state) do
    if state.envelope.recipient_count < Keyword.get(state.options, :max_recipients, 100),
      do: :ok,
      else: {:error, "452 Too many recipients\r\n"}
  end

  @spec command_address(binary(), binary(), binary()) :: {:ok, binary()} | {:error, iodata()}
  defp command_address(args, prefix, syntax) do
    if String.starts_with?(Binary.to_upper(args), prefix) do
      {:ok,
       args
       |> binary_part(byte_size(prefix), byte_size(args) - byte_size(prefix))
       |> Binary.strip(:left, ?\s)}
    else
      {:error, ["501 Syntax: ", syntax, "\r\n"]}
    end
  end

  @spec parse_address(binary(), State.t(), :sender | :recipient) ::
          {:ok, binary(), binary()} | {:error, iodata()}
  defp parse_address(address, state, kind) do
    case Address.parse_encoded_address(address, extension?(state, ~c"SMTPUTF8")) do
      :error -> address_error(kind)
      {"", _extra} when kind == :recipient -> address_error(kind)
      {mailbox, extra} -> {:ok, mailbox, extra}
    end
  end

  @spec address_error(:sender | :recipient) :: {:error, iodata()}
  defp address_error(kind),
    do: {:error, ["501 Bad ", Atom.to_string(kind), " address syntax\r\n"]}

  @spec accept_sender(binary(), State.t(), State.t()) :: result()
  defp accept_sender(sender, original, updated) do
    case original.module.handle_MAIL(sender, original.callbackstate) do
      {:ok, callback_state} ->
        state = %{
          updated
          | envelope: %{updated.envelope | from: sender},
            callbackstate: callback_state
        }

        Response.reply(original, "250 sender Ok\r\n", state)

      {:error, message, callback_state} ->
        Response.reply(original, [message, "\r\n"], %{updated | callbackstate: callback_state})
    end
  end

  @spec accept_recipient(binary(), binary(), State.t()) :: result()
  defp accept_recipient(recipient, "", state) do
    case state.module.handle_RCPT(recipient, state.callbackstate) do
      {:ok, callback_state} ->
        envelope = %{
          state.envelope
          | to: [recipient | state.envelope.to],
            recipient_count: state.envelope.recipient_count + 1
        }

        Response.reply(state, "250 recipient Ok\r\n", %{
          state
          | envelope: envelope,
            callbackstate: callback_state
        })

      {:error, message, callback_state} ->
        Response.reply(state, [message, "\r\n"], %{state | callbackstate: callback_state})
    end
  end

  defp accept_recipient(_recipient, extra, state) do
    Response.reply(state, ["555 Unsupported option: ", extra, "\r\n"])
  end

  @spec mail_options(binary(), State.t()) :: {:ok, State.t()} | {:error, iodata()}
  defp mail_options("", state), do: {:ok, state}

  defp mail_options(extra, state) do
    extra
    |> Binary.split(" ")
    |> Enum.reduce_while({:ok, state}, fn option, {:ok, updated} ->
      case mail_option(Binary.to_upper(option), updated, state, extra) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @spec mail_option(binary(), State.t(), State.t(), binary()) ::
          {:ok, State.t()} | {:error, iodata()}
  defp mail_option(<<"SIZE=", size::binary>>, updated, _original, _extra) do
    with {:ok, expected} <- declared_size(size) do
      if updated.maxsize == :infinity or expected <= updated.maxsize do
        {:ok, %{updated | envelope: %{updated.envelope | expectedsize: expected}}}
      else
        {:error,
         [
           "552 Estimated message length ",
           size,
           " exceeds limit of ",
           Integer.to_string(updated.maxsize),
           "\r\n"
         ]}
      end
    end
  end

  defp mail_option(<<"BODY=", type::binary>>, updated, _original, _extra) do
    with true <- extension?(updated, ~c"8BITMIME"),
         {:ok, flag} <- body_flag(type) do
      add_flag(updated, flag)
    else
      false -> {:error, "555 Unsupported option BODY\r\n"}
      :error -> {:error, "501 Invalid BODY parameter\r\n"}
    end
  end

  defp mail_option("SMTPUTF8", updated, _original, _extra) do
    if extension?(updated, ~c"SMTPUTF8"),
      do: add_flag(updated, :smtputf8),
      else: {:error, "555 Unsupported option SMTPUTF8\r\n"}
  end

  defp mail_option(option, updated, original, extra) do
    case original.module.handle_MAIL_extension(option, original.callbackstate) do
      {:ok, callback_state} -> {:ok, %{updated | callbackstate: callback_state}}
      :error -> {:error, ["555 Unsupported option: ", extra, "\r\n"]}
    end
  end

  @spec declared_size(binary()) :: {:ok, non_neg_integer()} | {:error, binary()}
  defp declared_size(size) do
    if byte_size(size) in 1..20 and Binary.all(&(&1 in ?0..?9), size) do
      {:ok, String.to_integer(size)}
    else
      {:error, "501 Invalid SIZE parameter\r\n"}
    end
  end

  @spec body_flag(binary()) :: {:ok, :"8bitmime" | :"7bit"} | :error
  defp body_flag("8BITMIME"), do: {:ok, :"8bitmime"}
  defp body_flag("7BIT"), do: {:ok, :"7bit"}
  defp body_flag(_type), do: :error

  @spec add_flag(State.t(), atom()) :: {:ok, State.t()}
  defp add_flag(state, flag) do
    {:ok, %{state | envelope: %{state.envelope | flags: [flag | state.envelope.flags]}}}
  end

  @spec extension?(State.t(), charlist()) :: boolean()
  defp extension?(state, name), do: :proplists.get_value(name, state.extensions) != :undefined
end
