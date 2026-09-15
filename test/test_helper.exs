Logger.configure(level: :warning)
ExUnit.start(capture_log: true)

Code.require_file("smtp/support/handler_helper.exs", __DIR__)

# Keep the upstream protocol, MIME and property regression suites executable
# against the native modules without shipping Erlang compatibility wrappers.
for file <- Path.wildcard(Path.join(__DIR__, "smtp/**/*.erl")) do
  case :compile.file(String.to_charlist(file), [
         :binary,
         :return_errors,
         :return_warnings,
         :debug_info
       ]) do
    {:ok, module, beam, _warnings} ->
      {:module, ^module} = :code.load_binary(module, String.to_charlist(file), beam)

    {:error, errors, warnings} ->
      raise "Cannot compile #{file}: #{inspect(errors, limit: :infinity)}; #{inspect(warnings)}"
  end
end
