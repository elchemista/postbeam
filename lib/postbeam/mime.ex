defmodule Postbeam.MIME do
  @moduledoc false

  alias Postbeam.Attachment
  alias Postbeam.Config
  alias Postbeam.Headers
  alias Postbeam.Message

  @type part :: {String.t(), String.t(), Headers.t(), map(), binary() | [part()]}

  @doc false
  @spec encode(Message.t(), Config.t()) ::
          {:ok, Message.encoded()} | {:error, Message.composition_error()}
  def encode(message, config) do
    with {:ok, attachments} <- Attachment.load(message.attachments) do
      compose(%{message | attachments: attachments}, config)
    end
  end

  @spec compose(Message.t(), Config.t()) ::
          {:ok, Message.encoded()} | {:error, {:composition, atom()}}
  defp compose(message, config) do
    id =
      "<" <>
        Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <>
        "@" <> Keyword.fetch!(config, :hostname) <> ">"

    headers = headers(message) ++ [{"Message-ID", id}]
    {type, subtype, _, params, body} = content(message)
    mime = {type, subtype, headers, params, body}
    options = if config[:dkim], do: [dkim: config[:dkim]], else: []
    {:ok, %{message | data: Postbeam.SMTP.MIME.encode(mime, options), message_id: id}}
  rescue
    # Encoder and crypto exception arguments can contain content or private keys.
    error -> {:error, {:composition, error.__struct__}}
  catch
    kind, _ -> {:error, {:composition, kind}}
  end

  @spec headers(Message.t()) :: Headers.t()
  defp headers(%Message{headers: nil} = message),
    do: [{"From", message.from}, {"To", message.to}, {"Subject", message.subject}]

  defp headers(%Message{headers: headers}), do: headers

  @spec content(Message.t()) :: part()
  defp content(message) do
    {inline, ordinary} = Enum.split_with(message.attachments, &(&1.type == :inline))
    html = related(text_part("html", message.html), inline)
    bodies = Enum.reject([text_part("plain", message.text), html], &is_nil/1)
    body = multipart("alternative", bodies)
    multipart("mixed", [body | Enum.map(ordinary, &attachment_part/1)])
  end

  @spec text_part(String.t(), String.t() | nil) :: part() | nil
  defp text_part(_, nil), do: nil

  defp text_part(type, body) do
    {"text", type, [],
     %{content_type_params: [{"charset", "utf-8"}], transfer_encoding: "base64"}, body}
  end

  @spec related(part() | nil, [Attachment.t()]) :: part() | nil
  defp related(html, []), do: html

  defp related(html, inline),
    do: multipart("related", [html | Enum.map(inline, &attachment_part/1)])

  @spec multipart(String.t(), [part()]) :: part()
  defp multipart(_, [part]), do: part
  defp multipart(subtype, parts), do: {"multipart", subtype, [], %{}, parts}

  @spec attachment_part(Attachment.t()) :: part()
  defp attachment_part(attachment) do
    [type, subtype] = String.split(attachment.content_type, "/")

    headers =
      if attachment.type == :inline,
        do: [{"Content-ID", "<" <> attachment.cid <> ">"} | attachment.headers],
        else: attachment.headers

    params = %{
      disposition: Atom.to_string(attachment.type),
      disposition_params: [{"filename", attachment.filename}],
      transfer_encoding: "base64"
    }

    {type, subtype, headers, params, attachment.data}
  end
end
