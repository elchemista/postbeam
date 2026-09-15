defmodule Postbeam.SMTP.Handler do
  @moduledoc """
  Callbacks for an SMTP or LMTP server.

  Pass an implementing module to `Postbeam.SMTP.Server`. Each connection owns its
  callback state. Callback names and return tuples match the original gen_smtp
  API. `Postbeam.SMTP.Example` demonstrates authentication, extensions and delivery.

  `handle_DATA/4` must acknowledge only after the message has been accepted by
  your storage or delivery system. Callbacks execute in the session process.
  """
  @type state() :: term()
  @type error_message() :: {:error, charlist(), state()}
  @type error_class() :: Postbeam.SMTP.Session.error_class()
  @type protocol_message() :: Postbeam.SMTP.Session.protocol_message()

  @callback init(:inet.hostname(), session_count, :inet.ip_address(), any()) ::
              {:ok, iodata(), state()} | {:stop, any(), iodata()} | :ignore
            when session_count: any()
  @callback code_change(any(), state(), any()) :: {:ok, state()}
  @callback handle_HELO(binary(), state()) ::
              {:ok, pos_integer() | :infinity, state()} | {:ok, state()} | error_message()
  @callback handle_EHLO(binary(), list(), state()) :: {:ok, list(), state()} | error_message()
  @callback handle_STARTTLS(state()) :: state()
  @callback handle_AUTH(
              :login | :plain | :"cram-md5",
              binary(),
              binary() | {binary(), binary()},
              state()
            ) :: {:ok, state()} | any()
  @callback handle_MAIL(binary(), state()) :: {:ok, state()} | {:error, charlist(), state()}
  @callback handle_MAIL_extension(binary(), state()) :: {:ok, state()} | :error
  @callback handle_RCPT(binary(), state()) :: {:ok, state()} | {:error, charlist(), state()}
  @callback handle_RCPT_extension(binary(), state()) :: {:ok, state()} | :error
  @callback handle_DATA(binary(), nonempty_list(binary()), binary(), state()) ::
              {:ok | :error, protocol_message(), state()}
              | {:multiple, list({:ok | :error, protocol_message()}), state()}
  @callback handle_RSET(state()) :: state()
  @callback handle_VRFY(binary(), state()) ::
              {:ok, charlist(), state()} | {:error, charlist(), state()}
  @callback handle_other(binary(), binary(), state()) :: {charlist() | :noreply, state()}
  @callback handle_info(term(), state()) ::
              {:noreply, state()}
              | {:noreply, state(), timeout() | :hibernate}
              | {:stop, term(), term()}
  @callback handle_error(error_class(), any(), state()) ::
              {:ok, state()} | {:stop, any(), state()}
  @callback terminate(any(), state()) :: {:ok, any(), state()}
  @optional_callbacks handle_info: 2, handle_AUTH: 4, handle_error: 3
end
