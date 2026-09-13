defmodule Postbeam.Message do
  @moduledoc """
  Validated, encoded email passed to transport adapters.

  `new/1` validates a keyword list or map. `encode/2` composes MIME and optional
  DKIM once; `data` and `message_id` then remain identical across MX attempts.
  Addresses are ASCII dot-atom mailboxes (use punycode for international domains).
  Text and HTML bodies and the subject support UTF-8.
  """

  alias Postbeam.Config

  @enforce_keys [:from, :to, :subject, :domain]
  defstruct [:from, :to, :subject, :domain, :text, :html, :data, :message_id]

  @typedoc "Caller-provided fields; addresses must be bare mailboxes."
  @type input ::
          keyword()
          | %{
              required(:from) => String.t(),
              required(:to) => String.t(),
              required(:subject) => String.t(),
              optional(:text) => String.t() | nil,
              optional(:html) => String.t() | nil
            }
  @type validation_error :: {:invalid, atom()} | {:unknown_field, term()}
  @type composition_error :: {:composition, atom()} | Postbeam.DKIM.error()
  @typedoc "A validated message, optionally already encoded."
  @type t :: message(binary() | nil, String.t() | nil)
  @typedoc "A message whose immutable wire data and Message-ID are ready for SMTP."
  @type encoded :: message(binary(), String.t())
  @typep message(data, id) :: %__MODULE__{
           from: String.t(),
           to: String.t(),
           subject: String.t(),
           domain: String.t(),
           text: String.t() | nil,
           html: String.t() | nil,
           data: data,
           message_id: id
         }

  @doc """
  Validates input without DNS, network access or signing.

  Domain names are lowercased while local-part case is preserved. Empty subjects
  and bodies are valid; at least one body must be supplied. Control characters
  in addresses/subjects, unknown fields and duplicate keyword keys are rejected.
  Quoted local parts, display names, address literals and SMTPUTF8 are unsupported.

      iex> {:ok, message} = Postbeam.Message.new(from: "Sender@EXAMPLE.COM",
      ...>   to: "User@EXAMPLE.NET", subject: "", text: "")
      iex> {message.from, message.to, message.domain, message.data}
      {"Sender@example.com", "User@example.net", "example.net", nil}

      iex> Postbeam.Message.new(from: "invalid", to: "a@example.net", subject: "", text: "")
      {:error, {:invalid, :from}}
  """
  @spec new(term()) :: {:ok, t()} | {:error, validation_error()}
  def new(input) when is_list(input) do
    with {:ok, fields} <- Config.keyword(input, :message), do: new(Map.new(fields))
  end

  def new(input) when is_map(input) and not is_struct(input) do
    with [] <- Map.keys(input) -- [:from, :to, :subject, :text, :html],
         {:ok, from, _} <- address(input[:from], :from),
         {:ok, to, domain} <- address(input[:to], :to),
         :ok <- validate(Config.header?(input[:subject]), :subject),
         :ok <- validate(body?(input[:text]), :text),
         :ok <- validate(body?(input[:html]), :html),
         :ok <- validate(is_binary(input[:text]) or is_binary(input[:html]), :body) do
      {:ok, struct!(__MODULE__, Map.merge(input, %{from: from, to: to, domain: domain}))}
    else
      {:error, _} = error -> error
      [field | _] -> {:error, {:unknown_field, field}}
    end
  end

  def new(_), do: {:error, {:invalid, :message}}

  @doc """
  Composes a validated message using options returned by `Postbeam.Config.new/1`.

  Generates a fresh random Message-ID on each call. Text and HTML together become
  `multipart/alternative`, with text first. Bodies use base64 transfer encoding,
  so non-ASCII content does not require the SMTP 8BITMIME extension. `:mimemail`
  supplies Date, MIME headers and optional DKIM signing. Managed keys are loaded
  or generated through `Postbeam.DKIM` before composing bytes.

  Reuse the returned `data` for fallback attempts. Composition failures return
  only the error class, never exception arguments that could contain a key.
  """
  @spec encode(t(), Config.t()) :: {:ok, encoded()} | {:error, composition_error()}
  def encode(message, config) do
    with {:ok, config} <- Postbeam.DKIM.prepare(config), do: compose(message, config)
  end

  defp compose(message, config) do
    id =
      "<" <>
        Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <>
        "@" <> Keyword.fetch!(config, :hostname) <> ">"

    headers = [
      {"From", message.from},
      {"To", message.to},
      {"Subject", message.subject},
      {"Message-ID", id}
    ]

    parts =
      for {type, body} <- [{"plain", message.text}, {"html", message.html}],
          is_binary(body),
          do: part(type, body)

    mime =
      case parts do
        [{type, subtype, _, params, body}] -> {type, subtype, headers, params, body}
        parts -> {"multipart", "alternative", headers, %{}, parts}
      end

    options = if config[:dkim], do: [dkim: config[:dkim]], else: []
    {:ok, %{message | data: :mimemail.encode(mime, options), message_id: id}}
  rescue
    # Do not return exception arguments: crypto errors can contain private keys.
    error -> {:error, {:composition, error.__struct__}}
  catch
    kind, _ -> {:error, {:composition, kind}}
  end

  defp part(type, body) do
    {"text", type, [],
     %{content_type_params: [{"charset", "utf-8"}], transfer_encoding: "base64"}, body}
  end

  defp address(value, field) when is_binary(value) and byte_size(value) <= 254 do
    case String.split(value, "@") do
      [local, domain] ->
        valid =
          byte_size(local) in 1..64 and Config.domain?(domain) and
            Regex.match?(
              ~r/\A[a-zA-Z0-9!#$%&'*+\-\/=?^_`{|}~]+(?:\.[a-zA-Z0-9!#$%&'*+\-\/=?^_`{|}~]+)*\z/,
              local
            )

        if valid,
          do: {:ok, local <> "@" <> String.downcase(domain), String.downcase(domain)},
          else: {:error, {:invalid, field}}

      _ ->
        {:error, {:invalid, field}}
    end
  end

  defp address(_, field), do: {:error, {:invalid, field}}
  defp body?(nil), do: true
  defp body?(body), do: is_binary(body) and String.valid?(body)
  defp validate(true, _), do: :ok
  defp validate(false, field), do: {:error, {:invalid, field}}
end
