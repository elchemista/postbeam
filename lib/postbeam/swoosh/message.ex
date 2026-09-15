if Code.ensure_loaded?(Swoosh.Email) do
  defmodule Postbeam.Swoosh.Message do
    @moduledoc false

    alias Postbeam.Address
    alias Postbeam.Attachment
    alias Postbeam.Config
    alias Postbeam.Headers
    alias Postbeam.Message
    alias Postbeam.Validation
    alias Swoosh.Email

    @type error :: Message.validation_error() | {:unsupported, :provider_options}

    @doc false
    @spec new(Email.t()) :: {:ok, [Message.t(), ...]} | {:error, error()}
    def new(%Email{} = email) do
      with :ok <- provider_options(email.provider_options),
           {:ok, from} <- mailbox(email.from, :from),
           {:ok, to} <- mailboxes(email.to, :to),
           {:ok, cc} <- mailboxes(email.cc, :cc),
           {:ok, bcc} <- mailboxes(email.bcc, :bcc),
           {:ok, reply_to} <- mailboxes(List.wrap(email.reply_to), :reply_to),
           {:ok, headers} <- Headers.new(email.headers, :headers),
           {:ok, attachments} <- attachments(email.attachments, email.html_body),
           {:ok, recipients} <- recipients(to, cc, bcc) do
        visible =
          [{"From", Headers.render([from])}, {"Subject", email.subject} | headers] ++
            address_headers(to, cc, reply_to)

        build_messages(email, from, recipients, visible, attachments)
      end
    end

    @spec provider_options(term()) :: :ok | {:error, {:unsupported, :provider_options}}
    defp provider_options(options) when options == %{}, do: :ok
    defp provider_options(_), do: {:error, {:unsupported, :provider_options}}

    @spec mailbox(term(), atom()) :: {:ok, Headers.mailbox()} | {:error, {:invalid, atom()}}
    defp mailbox({name, address}, field) do
      with :ok <- Validation.check(Config.header?(name), field),
           {:ok, normalized, _} <- Address.new(address, field) do
        {:ok, {name, normalized}}
      end
    end

    defp mailbox(_, field), do: {:error, {:invalid, field}}

    @spec mailboxes(term(), atom()) :: {:ok, [Headers.mailbox()]} | {:error, {:invalid, atom()}}
    defp mailboxes(values, field) when is_list(values) do
      Validation.map(values, &mailbox(&1, field))
    end

    defp mailboxes(_, field), do: {:error, {:invalid, field}}

    @spec recipients([Headers.mailbox()], [Headers.mailbox()], [Headers.mailbox()]) ::
            {:ok, [String.t(), ...]} | {:error, {:invalid, :recipients}}
    defp recipients(to, cc, bcc) do
      addresses = Enum.uniq_by(to ++ cc ++ bcc, &elem(&1, 1))

      case addresses do
        [] -> {:error, {:invalid, :recipients}}
        [_ | _] -> {:ok, Enum.map(addresses, &elem(&1, 1))}
      end
    end

    @spec address_headers([Headers.mailbox()], [Headers.mailbox()], [Headers.mailbox()]) ::
            Headers.t()
    defp address_headers(to, cc, reply_to) do
      for {name, [_ | _] = addresses} <- [{"To", to}, {"Cc", cc}, {"Reply-To", reply_to}],
          do: {name, Headers.render(addresses)}
    end

    @spec attachments(term(), String.t() | nil) ::
            {:ok, [Attachment.t()]} | {:error, {:invalid, :attachments}}
    defp attachments(values, html) when is_list(values) do
      with {:ok, attachments} <- Validation.map(values, &attachment/1),
           :ok <- validate_inline(attachments, html) do
        {:ok, attachments}
      end
    end

    defp attachments(_, _), do: {:error, {:invalid, :attachments}}

    @spec validate_inline([Attachment.t()], String.t() | nil) ::
            :ok | {:error, {:invalid, :attachments}}
    defp validate_inline(attachments, html) do
      cids = for %{type: :inline, cid: cid} <- attachments, do: cid

      with :ok <- Validation.check(cids == [] or is_binary(html), :attachments) do
        Validation.check(length(cids) == MapSet.size(MapSet.new(cids)), :attachments)
      end
    end

    @spec attachment(term()) :: {:ok, Attachment.t()} | {:error, {:invalid, :attachments}}
    defp attachment(%Swoosh.Attachment{} = attachment),
      do: Attachment.new(Map.from_struct(attachment))

    defp attachment(_), do: {:error, {:invalid, :attachments}}

    @spec build_messages(Email.t(), Headers.mailbox(), [String.t()], Headers.t(), [Attachment.t()]) ::
            {:ok, [Message.t()]} | {:error, Message.validation_error()}
    defp build_messages(email, {_name, sender}, recipients, headers, attachments) do
      Validation.map(recipients, fn recipient ->
        with {:ok, message} <-
               Message.new(%{
                 from: sender,
                 to: recipient,
                 subject: email.subject,
                 text: email.text_body,
                 html: email.html_body
               }) do
          {:ok, %{message | headers: headers, attachments: attachments}}
        end
      end)
    end
  end
end
