defmodule Postbeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :postbeam,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        ignore_modules: [Postbeam.TestDNS, Postbeam.TestTransport, Postbeam.TestReceiver]
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "readme",
        extras: ["README.md", "guides/adapters.md", "guides/quality.md"]
      ],
      dialyzer: [flags: [:error_handling, :unmatched_returns]],
      description: "A small outbound SMTP sender that delivers directly to recipient MX servers",
      package: [
        licenses: ["Apache-2.0"],
        files: [
          "lib",
          "examples",
          "guides",
          "mix.exs",
          "README.md",
          "LICENSE",
          ".formatter.exs",
          ".credo.exs"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto, :public_key, :ssl]]

  defp deps do
    [
      {:gen_smtp, "~> 1.3.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
