defmodule Postbeam.Swoosh.Config do
  @moduledoc false

  alias Postbeam.Config

  @mailer_keys [:adapter, :otp_app, :postbeam]

  @doc false
  @spec new(term()) :: {:ok, Config.t()} | {:error, Config.error()}
  def new(config) do
    with {:ok, config} <- Config.keyword(config, :config),
         :ok <- validate_keys(config),
         {:ok, options} <- Config.keyword(Keyword.get(config, :postbeam, []), :config) do
      Config.new(options)
    end
  end

  @spec validate_keys(keyword()) :: :ok | {:error, {:invalid_config, atom()}}
  defp validate_keys(config) do
    case Enum.find(config, fn {key, _} -> key not in @mailer_keys end) do
      nil -> :ok
      {key, _} -> {:error, {:invalid_config, key}}
    end
  end
end
