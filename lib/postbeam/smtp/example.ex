# credo:disable-for-this-file Credo.Check.Readability.FunctionNames
defmodule Postbeam.SMTP.Example do
  @moduledoc "Example `Postbeam.SMTP.Handler` implementation demonstrating protocol callbacks.\n\nFor local experiments; replace the sample recipient and authentication policies\nwith your application policies before accepting real mail."

  alias Postbeam.SMTP.Client
  alias Postbeam.SMTP.Handler
  alias Postbeam.SMTP.Log
  alias Postbeam.SMTP.MIME
  alias Postbeam.SMTP.Session
  alias Postbeam.SMTP.Util

  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  require Record
  @behaviour Handler
  Record.defrecordp(:state, :state, options: [])
  @typep error_message() :: {:error, charlist(), record(:state, options: list())}
  @impl Handler
  @spec init(:inet.hostname(), non_neg_integer(), :inet.ip_address(), list()) ::
          {:ok, iodata(), record(:state, options: list())} | {:stop, any(), iodata()}
  @doc false
  def init(hostname, session_count, _address, options) do
    case session_count > 20 do
      false ->
        banner = [hostname, ~c" ESMTP smtp_server_example"]
        state = state(options: options)
        {:ok, banner, state}

      true ->
        Log.warning(~c"Connection limit exceeded", %{
          domain: [:postbeam, :example_handler]
        })

        {:stop, :normal, [~c"421 ", hostname, ~c" is too busy to accept mail right now"]}
    end
  end

  @impl Handler
  @spec handle_HELO(binary(), record(:state, options: list())) ::
          {:ok, pos_integer(), record(:state, options: list())}
          | {:ok, record(:state, options: list())}
          | error_message()
  @doc false
  def handle_HELO("invalid", state) do
    {:error, ~c"554 invalid hostname", state}
  end

  def handle_HELO("trusted_host", state) do
    {:ok, state}
  end

  def handle_HELO(_hostname, state) do
    max_size = :proplists.get_value(:size, state(state, :options), 655_360)
    {:ok, max_size, state}
  end

  @impl Handler
  @spec handle_EHLO(binary(), list(), record(:state, options: list())) ::
          {:ok, list(), record(:state, options: list())} | error_message()
  @doc false
  def handle_EHLO("invalid", _extensions, state) do
    {:error, ~c"554 invalid hostname", state}
  end

  def handle_EHLO(_hostname, extensions, state) do
    my_extensions1 =
      case :proplists.get_value(:auth, state(state, :options), false) do
        true -> extensions ++ [{~c"AUTH", ~c"PLAIN LOGIN CRAM-MD5"}, {~c"STARTTLS", true}]
        false -> extensions
      end

    my_extensions2 =
      case :proplists.get_value(:size, state(state, :options)) do
        :undefined ->
          my_extensions1

        :infinity ->
          [{~c"SIZE", ~c"0"} | :lists.keydelete(~c"SIZE", 1, my_extensions1)]

        size when is_integer(size) and size > 0 ->
          [
            {~c"SIZE", :erlang.integer_to_list(size)}
            | :lists.keydelete(~c"SIZE", 1, my_extensions1)
          ]
      end

    {:ok, my_extensions2, state}
  end

  @impl Handler
  @spec handle_MAIL(binary(), record(:state, options: list())) ::
          {:ok, record(:state, options: list())} | error_message()
  @doc false
  def handle_MAIL("badguy@blacklist.com", state) do
    {:error, ~c"552 go away", state}
  end

  def handle_MAIL(_from, state) do
    {:ok, state}
  end

  @impl Handler
  @spec handle_MAIL_extension(binary(), record(:state, options: list())) ::
          {:ok, record(:state, options: list())} | :error
  @doc false
  def handle_MAIL_extension("X-SomeExtension", state) do
    {:ok, state}
  end

  def handle_MAIL_extension(extension, _state) do
    Log.warning(~c"Unknown MAIL FROM extension ~s", [extension], %{
      domain: [:postbeam, :example_handler]
    })

    :error
  end

  @impl Handler
  @spec handle_RCPT(binary(), record(:state, options: list())) ::
          {:ok, record(:state, options: list())}
          | {:error, charlist(), record(:state, options: list())}
  @doc false
  def handle_RCPT("nobody@example.com", state) do
    {:error, ~c"550 No such recipient", state}
  end

  def handle_RCPT(_to, state) do
    {:ok, state}
  end

  @impl Handler
  @spec handle_RCPT_extension(binary(), record(:state, options: list())) ::
          {:ok, record(:state, options: list())} | :error
  @doc false
  def handle_RCPT_extension("X-SomeExtension", state) do
    {:ok, state}
  end

  def handle_RCPT_extension(extension, _state) do
    Log.warning(~c"Unknown RCPT TO extension ~s", [extension], %{
      domain: [:postbeam, :example_handler]
    })

    :error
  end

  @impl Handler
  @spec handle_DATA(
          binary(),
          nonempty_list(binary()),
          binary(),
          record(:state, options: list())
        ) ::
          {:ok | :error, charlist(), record(:state, options: list())}
          | {:multiple, list({:ok | :error, charlist()}), record(:state, options: list())}
  @doc false
  def handle_DATA(_from, _to, <<>>, state) do
    {:error, ~c"552 Message too small", state}
  end

  def handle_DATA(from, to, data, state) do
    case :proplists.get_value(:relay, state(state, :options), false) do
      true ->
        relay(from, to, data)

      false ->
        reference =
          :lists.flatten(
            for <<x <- :erlang.md5(:erlang.term_to_binary(unique_id()))>>,
              into: [],
              do: :io_lib.format(~c"~2.16.0b", [x])
          )

        maybe_parse(data, reference, state(state, :options))

        queue_or_deliver(from, to, data, reference, state)
    end
  end

  @impl Handler
  @spec handle_RSET(record(:state, options: list())) :: record(:state, options: list())
  @doc false
  def handle_RSET(state) do
    state
  end

  @impl Handler
  @spec handle_VRFY(binary(), record(:state, options: list())) ::
          {:ok, charlist(), record(:state, options: list())}
          | {:error, charlist(), record(:state, options: list())}
  @doc false
  def handle_VRFY("someuser", state) do
    {:ok, ~c"someuser@" ++ Util.guess_FQDN(), state}
  end

  def handle_VRFY(_address, state) do
    {:error, ~c"252 VRFY disabled by policy, just send some mail", state}
  end

  @impl Handler
  @spec handle_other(binary(), binary(), record(:state, options: list())) ::
          {charlist(), record(:state, options: list())}
  @doc false
  def handle_other(verb, _args, state) do
    {[~c"500 Error: command not recognized : '", verb, ~c"'"], state}
  end

  @impl Handler
  @spec handle_AUTH(
          :login | :plain | :"cram-md5",
          binary(),
          binary() | {binary(), binary()},
          record(:state, options: list())
        ) :: {:ok, record(:state, options: list())} | :error
  @doc false
  def handle_AUTH(type, "username", "PaSSw0rd", state) when type === :login or type === :plain do
    {:ok, state}
  end

  def handle_AUTH(:"cram-md5", "username", {digest, seed}, state) do
    case Util.compute_cram_digest("PaSSw0rd", seed) do
      ^digest -> {:ok, state}
      _ -> :error
    end
  end

  def handle_AUTH(_type, _username, _password, _state) do
    :error
  end

  @impl Handler
  @spec handle_STARTTLS(record(:state, options: list())) :: record(:state, options: list())
  @doc false
  def handle_STARTTLS(state) do
    state
  end

  @impl Handler
  @spec handle_info(term(), term()) ::
          {:noreply, term()}
          | {:noreply, term(), timeout() | :hibernate}
          | {:stop, term(), term()}
  @doc false
  def handle_info(_info, state) do
    {:noreply, state}
  end

  @impl Handler
  @spec handle_error(
          Session.error_class(),
          any(),
          record(:state, options: list())
        ) ::
          {:ok, record(:state, options: list())} | {:stop, any(), record(:state, options: list())}
  @doc false
  def handle_error(_class, _details, state) do
    {:ok, state}
  end

  @impl Handler
  @spec code_change(any(), record(:state, options: list()), any()) ::
          {:ok, record(:state, options: list())}
  @doc false
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  @impl Handler
  @spec terminate(any(), record(:state, options: list())) ::
          {:ok, any(), record(:state, options: list())}
  @doc false
  def terminate(reason, state) do
    {:ok, reason, state}
  end

  @spec maybe_parse(binary(), charlist(), list()) :: term()
  defp maybe_parse(data, reference, options) do
    if :proplists.get_value(:parse, options, false), do: parse_message(data, reference, options)
  end

  @spec parse_message(binary(), charlist(), list()) :: term()
  defp parse_message(data, reference, options) do
    MIME.decode(data)
  catch
    what, why ->
      Log.warning(~c"Message decode failed with ~p:~p", [what, why], %{
        domain: [:postbeam, :example_handler]
      })

      if :proplists.get_value(:dump, options, false), do: dump_message(data, reference)
  end

  @spec dump_message(binary(), charlist()) :: :ok | {:error, term()}
  defp dump_message(data, reference) do
    file = ~c"dump/" ++ reference
    with :ok <- :filelib.ensure_dir(file), do: :file.write_file(file, data)
  end

  @spec unique_id() :: integer()
  defp unique_id do
    :erlang.unique_integer()
  end

  @spec relay(binary(), list(binary()), binary()) :: :ok
  defp relay(_, [], _) do
    :ok
  end

  defp relay(from, [to | rest], data) do
    [_user, host] = :string.tokens(:erlang.binary_to_list(to), ~c"@")
    Client.send({from, [to], :erlang.binary_to_list(data)}, relay: host)
    relay(from, rest, data)
  end

  @spec queue_or_deliver(
          binary(),
          nonempty_list(binary()),
          binary(),
          charlist(),
          record(:state, options: list())
        ) ::
          {:ok | :error, charlist(), record(:state, options: list())}
          | {:multiple, list({:ok | :error, charlist()}), record(:state, options: list())}
  defp queue_or_deliver(_from, to, _data, reference, state) do
    case :proplists.get_value(:protocol, state(state, :options), :smtp) do
      :smtp ->
        {:ok, [~c"queued as ", reference], state}

      :lmtp ->
        multiple = for recipient <- to, into: [], do: {:ok, [~c"delivered to ", recipient]}
        {:multiple, multiple, state}
    end
  end
end
