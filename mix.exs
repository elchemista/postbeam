defmodule Postbeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :postbeam,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        summary: [threshold: 80],
        ignore_modules: [
          Postbeam.TestDNS,
          Postbeam.TestTransport,
          Postbeam.TestReceiver,
          Postbeam.TestDNSServer,
          Postbeam.TestMailer,
          Postbeam.SecondTestMailer,
          Postbeam.StorageTest.Store,
          Postbeam.StorageTest.FailingKeyStore
        ]
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/swoosh.md",
          "docs/configuration.md",
          "docs/delivery.md",
          "docs/domain-setup.md",
          "docs/dkim.md",
          "docs/adapters.md"
        ]
      ],
      description: "A small outbound SMTP sender that delivers directly to recipient MX servers",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/elchemista/postbeam"},
        files: [
          "lib",
          "examples",
          "docs",
          "mix.exs",
          "README.md",
          "LICENSE",
          ".formatter.exs",
          ".credo.exs"
        ]
      ]
    ]
  end

  def application,
    do: [
      extra_applications: [:logger, :crypto, :public_key, :ssl]
    ]

  defp deps do
    [
      {:gen_smtp, "~> 1.3.0"},
      {:swoosh, "~> 1.28", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
