%{
  configs: [
    %{
      name: "default",
      strict: false,
      files: %{included: ["lib/", "test/", "examples/", "mix.exs"]}
    }
  ]
}
