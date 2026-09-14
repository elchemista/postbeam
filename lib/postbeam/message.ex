defmodule Postbeam.Message do
  @moduledoc """
  Validated, encoded email passed to transport adapters.

  `new/1` validates a keyword list or map. `encode/2` composes MIME and optional
  DKIM once; `data` and `message_id` then remain identical across MX attempts.
  Addresses are ASCII dot-atom mailboxes; use punycode for international domains.
  Text and HTML bodies and the subject support UTF-8.

  `from` and `to` are always SMTP envelope mailboxes. Internal `headers` and
  `attachments` fields are populated by the Swoosh boundary; they are not accepted
  by `new/1`. Visible To/Cc headers can differ from the current envelope recipient.
  Encoded attachments contain loaded bytes and no source paths.
  """

  alias Postbeam.Address
  alias Postbeam.Config
  alias Postbeam.DKIM
  alias Postbeam.MIME

  @enforce_keys [:from, :to, :subject, :domain]
  defstruct [
    :from,
    :to,
    :subject,
    :domain,
    :text,
    :html,
    :data,
    :message_id,
    :headers,
    attachments: []
  ]

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
  @type composition_error ::
          {:composition, atom()}
          | Postbeam.DKIM.error()
          | {:attachment, non_neg_integer(), atom()}
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
           message_id: id,
           headers: Postbeam.Headers.t() | nil,
           attachments: [Postbeam.Attachment.t()]
         }

  @doc """
  Validates input without DNS, network access or signing.

  Domain names are lowercased while local-part case is preserved. Empty subjects
  and bodies are valid; at least one body must be supplied. Control characters
  in addresses/subjects, unknown fields and duplicate keyword keys are rejected.
  Display names must be supplied through Swoosh, rather than embedded in a mailbox.

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
         {:ok, from, _} <- Address.new(input[:from], :from),
         {:ok, to, domain} <- Address.new(input[:to], :to),
         :ok <- validate(Config.header?(input[:subject]), :subject),
         :ok <- validate(body?(input[:text]), :text),
         :ok <- validate(body?(input[:html]), :html),
         :ok <- validate(is_binary(input[:text]) or is_binary(input[:html]), :body) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(input, %{
           from: from,
           to: to,
           domain: domain
         })
       )}
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
  so Unicode bodies alone do not require SMTPUTF8. The encoder
  supplies Date and MIME headers, then signs the final headers when DKIM is configured. Managed keys are loaded
  or generated through `Postbeam.DKIM` before composing bytes.

  Reuse the returned `data` for fallback attempts. Composition failures return
  only the error class, never exception arguments that could contain a key.
  """
  @spec encode(t(), Config.t()) :: {:ok, encoded()} | {:error, composition_error()}
  def encode(message, config) do
    with {:ok, config} <- DKIM.prepare(config), do: MIME.encode(message, config)
  end

  @spec body?(term()) :: boolean()
  defp body?(nil), do: true
  defp body?(body), do: is_binary(body) and String.valid?(body)

  @spec validate(boolean(), atom()) :: :ok | {:error, {:invalid, atom()}}
  defp validate(true, _), do: :ok
  defp validate(false, field), do: {:error, {:invalid, field}}
end
