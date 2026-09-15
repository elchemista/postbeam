defmodule Postbeam.SMTP.Client.Transaction do
  @moduledoc false

  alias Postbeam.SMTP.Client
  alias Postbeam.SMTP.Client.Reply
  alias Postbeam.SMTP.Socket

  @typep phase :: :envelope | :receipt

  @doc false
  @spec deliver(Client.email(), Socket.socket(), Client.options()) ::
          binary() | nonempty_list({Client.email_address(), binary()})
  def deliver({from, recipients, body}, socket, options) do
    command(socket, ["MAIL FROM:", bracket(from), "\r\n"], options, ["250"])

    Enum.each(recipients, fn recipient ->
      command(socket, ["RCPT TO:", bracket(recipient), "\r\n"], options, ["250", "251"])
    end)

    send_body(socket, body, options)
    receipt(socket, recipients, options)
  end

  @spec bracket(Client.email_address()) :: iodata()
  defp bracket(address) when is_list(address), do: bracket(IO.iodata_to_binary(address))
  defp bracket(<<"<", _::binary>> = address), do: address
  defp bracket(address), do: ["<", address, ">"]

  @spec command(Socket.socket(), iodata(), Client.options(), [binary()]) :: :ok
  defp command(socket, command, options, accepted_codes) do
    Socket.send(socket, command)
    {:ok, reply} = Reply.read_possible_multiline_reply(socket)
    <<code::binary-size(3), _::binary>> = reply

    if code in accepted_codes, do: :ok, else: reject(reply, socket, options, :envelope)
  end

  @spec send_body(Socket.socket(), iodata() | (-> iodata()), Client.options()) ::
          :ok | {:error, term()}
  defp send_body(socket, body, options) when is_function(body, 0) do
    send_body(socket, body.(), options)
  end

  defp send_body(socket, body, options) do
    command(socket, "DATA\r\n", options, ["354"])
    escaped_body = :re.replace(body, "^\\.", "..", [:global, :multiline, return: :binary])
    Socket.send(socket, [escaped_body, terminator(escaped_body)])
  end

  @spec terminator(binary()) :: binary()
  defp terminator(""), do: ".\r\n"

  defp terminator(body) do
    if String.ends_with?(body, "\r\n"), do: ".\r\n", else: "\r\n.\r\n"
  end

  @spec receipt(Socket.socket(), [Client.email_address()], Client.options()) ::
          binary() | [{Client.email_address(), binary()}]
  defp receipt(socket, recipients, options) do
    case Keyword.fetch!(options, :protocol) do
      :smtp -> smtp_receipt(socket, options)
      :lmtp -> Enum.map(recipients, &{&1, elem(Reply.read_possible_multiline_reply(socket), 1)})
    end
  end

  @spec smtp_receipt(Socket.socket(), Client.options()) :: binary()
  defp smtp_receipt(socket, options) do
    case Reply.read_possible_multiline_reply(socket) do
      {:ok, <<"250 ", receipt::binary>>} -> receipt
      {:ok, reply} -> reject(reply, socket, options, :receipt)
    end
  end

  @spec reject(binary(), Socket.socket(), Client.options(), phase()) :: no_return()
  defp reject(<<code, _::binary>> = reply, socket, options, phase) when code in ~c"45" do
    recover(socket, Keyword.get(options, :on_transaction_error), phase)
    failure = if code == ?4, do: :temporary_failure, else: :permanent_failure
    throw({failure, reply})
  end

  defp reject(reply, socket, _options, _phase) do
    Reply.quit(socket)
    throw({:permanent_failure, reply})
  end

  @spec recover(Socket.socket(), :reset | :quit | nil, phase()) :: :ok
  defp recover(socket, :reset, :envelope), do: Reply.rset_or_quit(socket)
  defp recover(_socket, :reset, :receipt), do: :ok
  defp recover(socket, _policy, _phase), do: Reply.quit(socket)
end
