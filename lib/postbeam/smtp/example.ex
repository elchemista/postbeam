# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Readability.FunctionNames
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Postbeam.SMTP.Example do
  @moduledoc "Example `Postbeam.SMTP.Handler` implementation demonstrating protocol callbacks.\n\nFor local experiments; replace the sample recipient and authentication policies\nwith your application policies before accepting real mail."
  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  require Record
  @behaviour Postbeam.SMTP.Handler
  Record.defrecordp(:state, :state, options: [])
  @typep error_message() :: {:error, charlist(), record(:state, options: list())}
  @spec init(:inet.hostname(), non_neg_integer(), :inet.ip_address(), list()) ::
          {:ok, iodata(), record(:state, options: list())} | {:stop, any(), iodata()}
  def init(hostname, session_count, address, options) do
    Postbeam.SMTP.Log.info(~c"peer: ~p", [address], %{domain: [:postbeam, :example_handler]})

    case session_count > 20 do
      false ->
        banner = [hostname, ~c" ESMTP smtp_server_example"]
        state = state(options: options)
        {:ok, banner, state}

      true ->
        Postbeam.SMTP.Log.warning(~c"Connection limit exceeded", %{
          domain: [:postbeam, :example_handler]
        })

        {:stop, :normal, [~c"421 ", hostname, ~c" is too busy to accept mail right now"]}
    end
  end

  @spec handle_HELO(binary(), record(:state, options: list())) ::
          {:ok, pos_integer(), record(:state, options: list())}
          | {:ok, record(:state, options: list())}
          | error_message()
  def handle_HELO("invalid", state) do
    {:error, ~c"554 invalid hostname", state}
  end

  def handle_HELO("trusted_host", state) do
    {:ok, state}
  end

  def handle_HELO(hostname, state) do
    Postbeam.SMTP.Log.info(~c"HELO from ~s", [hostname], %{domain: [:postbeam, :example_handler]})
    max_size = :proplists.get_value(:size, state(state, :options), 655_360)
    {:ok, max_size, state}
  end

  @spec handle_EHLO(binary(), list(), record(:state, options: list())) ::
          {:ok, list(), record(:state, options: list())} | error_message()
  def handle_EHLO("invalid", _extensions, state) do
    {:error, ~c"554 invalid hostname", state}
  end

  def handle_EHLO(hostname, extensions, state) do
    Postbeam.SMTP.Log.info(~c"EHLO from ~s", [hostname], %{domain: [:postbeam, :example_handler]})

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

  @spec handle_MAIL(binary(), record(:state, options: list())) ::
          {:ok, record(:state, options: list())} | error_message()
  def handle_MAIL("badguy@blacklist.com", state) do
    {:error, ~c"552 go away", state}
  end

  def handle_MAIL(from, state) do
    Postbeam.SMTP.Log.info(~c"Mail from ~s", [from], %{domain: [:postbeam, :example_handler]})
    {:ok, state}
  end

  @spec handle_MAIL_extension(binary(), record(:state, options: list())) ::
          {:ok, record(:state, options: list())} | :error
  def handle_MAIL_extension("X-SomeExtension" = extension, state) do
    Postbeam.SMTP.Log.info(~c"Mail from extension ~s", [extension], %{
      domain: [:postbeam, :example_handler]
    })

    {:ok, state}
  end

  def handle_MAIL_extension(extension, _state) do
    Postbeam.SMTP.Log.warning(~c"Unknown MAIL FROM extension ~s", [extension], %{
      domain: [:postbeam, :example_handler]
    })

    :error
  end

  @spec handle_RCPT(binary(), record(:state, options: list())) ::
          {:ok, record(:state, options: list())}
          | {:error, charlist(), record(:state, options: list())}
  def handle_RCPT("nobody@example.com", state) do
    {:error, ~c"550 No such recipient", state}
  end

  def handle_RCPT(to, state) do
    Postbeam.SMTP.Log.info(~c"Mail to ~s", [to], %{domain: [:postbeam, :example_handler]})
    {:ok, state}
  end

  @spec handle_RCPT_extension(binary(), record(:state, options: list())) ::
          {:ok, record(:state, options: list())} | :error
  def handle_RCPT_extension("X-SomeExtension" = extension, state) do
    Postbeam.SMTP.Log.info(~c"Mail to extension ~s", [extension], %{
      domain: [:postbeam, :example_handler]
    })

    {:ok, state}
  end

  def handle_RCPT_extension(extension, _state) do
    Postbeam.SMTP.Log.warning(~c"Unknown RCPT TO extension ~s", [extension], %{
      domain: [:postbeam, :example_handler]
    })

    :error
  end

  @spec handle_DATA(
          binary(),
          nonempty_list(binary()),
          binary(),
          record(:state, options: list())
        ) ::
          {:ok | :error, charlist(), record(:state, options: list())}
          | {:multiple, list({:ok | :error, charlist()}), record(:state, options: list())}
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

        case :proplists.get_value(:parse, state(state, :options), false) do
          false ->
            :ok

          true ->
            try do
              Postbeam.SMTP.MIME.decode(data)
            catch
              what, why ->
                Postbeam.SMTP.Log.warning(~c"Message decode FAILED with ~p:~p", [what, why], %{
                  domain: [:postbeam, :example_handler]
                })

                case :proplists.get_value(:dump, state(state, :options), false) do
                  false ->
                    :ok

                  true ->
                    file = ~c"dump/" ++ reference

                    case :filelib.ensure_dir(file) do
                      :ok -> :file.write_file(file, data)
                      _ -> :ok
                    end
                end
            else
              _result ->
                Postbeam.SMTP.Log.info(~c"Message decoded successfully!", %{
                  domain: [:postbeam, :example_handler]
                })
            end
        end

        queue_or_deliver(from, to, data, reference, state)
    end
  end

  @spec handle_RSET(record(:state, options: list())) :: record(:state, options: list())
  def handle_RSET(state) do
    state
  end

  @spec handle_VRFY(binary(), record(:state, options: list())) ::
          {:ok, charlist(), record(:state, options: list())}
          | {:error, charlist(), record(:state, options: list())}
  def handle_VRFY("someuser", state) do
    {:ok, ~c"someuser@" ++ Postbeam.SMTP.Util.guess_FQDN(), state}
  end

  def handle_VRFY(_address, state) do
    {:error, ~c"252 VRFY disabled by policy, just send some mail", state}
  end

  @spec handle_other(binary(), binary(), record(:state, options: list())) ::
          {charlist(), record(:state, options: list())}
  def handle_other(verb, _args, state) do
    {[~c"500 Error: command not recognized : '", verb, ~c"'"], state}
  end

  @spec handle_AUTH(
          :login | :plain | :"cram-md5",
          binary(),
          binary() | {binary(), binary()},
          record(:state, options: list())
        ) :: {:ok, record(:state, options: list())} | :error
  def handle_AUTH(type, "username", "PaSSw0rd", state) when type === :login or type === :plain do
    {:ok, state}
  end

  def handle_AUTH(:"cram-md5", "username", {digest, seed}, state) do
    case Postbeam.SMTP.Util.compute_cram_digest("PaSSw0rd", seed) do
      ^digest -> {:ok, state}
      _ -> :error
    end
  end

  def handle_AUTH(_type, _username, _password, _state) do
    :error
  end

  @spec handle_STARTTLS(record(:state, options: list())) :: record(:state, options: list())
  def handle_STARTTLS(state) do
    Postbeam.SMTP.Log.info(~c"TLS Started", %{domain: [:postbeam, :example_handler]})
    state
  end

  @spec handle_info(term(), term()) ::
          {:noreply, term()}
          | {:noreply, term(), timeout() | :hibernate}
          | {:stop, term(), term()}
  def handle_info(info, state) do
    Postbeam.SMTP.Log.info(~c"handle_info(~p, ~p)", [info, state], %{
      domain: [:postbeam, :example_handler]
    })

    {:noreply, state}
  end

  @spec handle_error(
          Postbeam.SMTP.Session.error_class(),
          any(),
          record(:state, options: list())
        ) ::
          {:ok, record(:state, options: list())} | {:stop, any(), record(:state, options: list())}
  def handle_error(class, details, state) do
    Postbeam.SMTP.Log.info(~c"handle_error(~p, ~p, ~p)", [class, details, state], %{
      domain: [:postbeam, :example_handler]
    })

    {:ok, state}
  end

  @spec code_change(any(), record(:state, options: list()), any()) ::
          {:ok, record(:state, options: list())}
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  @spec terminate(any(), record(:state, options: list())) ::
          {:ok, any(), record(:state, options: list())}
  def terminate(reason, state) do
    {:ok, reason, state}
  end

  defp unique_id() do
    :erlang.unique_integer()
  end

  @spec relay(binary(), list(binary()), binary()) :: :ok
  defp relay(_, [], _) do
    :ok
  end

  defp relay(from, [to | rest], data) do
    [_user, host] = :string.tokens(:erlang.binary_to_list(to), ~c"@")
    Postbeam.SMTP.Client.send({from, [to], :erlang.binary_to_list(data)}, relay: host)
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
  defp queue_or_deliver(from, to, data, reference, state) do
    var_length = byte_size(data)

    case :proplists.get_value(:protocol, state(state, :options), :smtp) do
      :smtp ->
        Postbeam.SMTP.Log.info(
          ~c"message from ~s to ~p queued as ~s, body length ~p",
          [from, to, reference, var_length],
          %{domain: [:postbeam, :example_handler]}
        )

        {:ok, [~c"queued as ", reference], state}

      :lmtp ->
        Postbeam.SMTP.Log.info(
          ~c"message from ~s delivered to ~p, body length ~p",
          [from, to, var_length],
          %{domain: [:postbeam, :example_handler]}
        )

        multiple = for recipient <- to, into: [], do: {:ok, [~c"delivered to ", recipient]}
        {:multiple, multiple, state}
    end
  end
end
