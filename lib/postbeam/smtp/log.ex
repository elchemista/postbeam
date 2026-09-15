defmodule Postbeam.SMTP.Log do
  @moduledoc false

  for level <- [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency] do
    @doc false
    @spec unquote(level)(:unicode.chardata() | map() | {atom(), term()}) :: :ok
    def unquote(level)(message), do: :logger.log(unquote(level), message)

    @doc false
    @spec unquote(level)(:unicode.chardata() | map() | {atom(), term()}, map() | list()) :: :ok
    def unquote(level)(message, metadata) when is_map(metadata),
      do: :logger.log(unquote(level), message, metadata)

    def unquote(level)(format, args), do: :logger.log(unquote(level), format, args)

    @doc false
    @spec unquote(level)(:io.format(), list(), map()) :: :ok
    def unquote(level)(format, args, metadata),
      do: :logger.log(unquote(level), format, args, metadata)
  end
end
