%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{included: ["lib/", "test/", "examples/", "mix.exs"]}
    }
  ]
}
