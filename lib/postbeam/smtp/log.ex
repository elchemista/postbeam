defmodule Postbeam.SMTP.Log do
  @moduledoc false

  for level <- [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency] do
    def unquote(level)(message), do: :logger.log(unquote(level), message)

    def unquote(level)(message, metadata) when is_map(metadata),
      do: :logger.log(unquote(level), message, metadata)

    def unquote(level)(format, args), do: :logger.log(unquote(level), format, args)

    def unquote(level)(format, args, metadata),
      do: :logger.log(unquote(level), format, args, metadata)
  end
end
