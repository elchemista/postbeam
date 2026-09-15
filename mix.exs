defmodule Postbeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :postbeam,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: [:yecc, :leex] ++ Mix.compilers(),
      erlc_paths: ["src"],
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        summary: [threshold: 80],
        ignore_modules: [
          :postbeam_smtp_rfc822_parse,
          :postbeam_smtp_rfc5322_parse,
          :postbeam_smtp_rfc5322_scan,
          Postbeam.TestDNS,
          Postbeam.TestTransport,
          Postbeam.TestReceiver,
          Postbeam.TestInboundAdapter,
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
          "docs/inbound.md",
          "docs/domain-setup.md",
          "docs/dkim.md",
          "docs/adapters.md",
          "docs/smtp.md"
        ]
      ],
      description:
        "Direct-to-MX SMTP delivery and incoming email with application-owned adapters",
      package: [
        licenses: ["Apache-2.0", "BSD-2-Clause", "MIT"],
        links: %{"GitHub" => "https://github.com/elchemista/postbeam"},
        files: [
          "lib",
          "src/*.xrl",
          "src/*.yrl",
          "licenses",
          "examples",
          "docs",
          "mix.exs",
          "README.md",
          "LICENSE",
          "NOTICE",
          ".formatter.exs",
          ".credo.exs"
        ]
      ]
    ]
  end

  def application,
    do: [
      mod: {Postbeam.Application, []},
      extra_applications:
        [:logger, :crypto, :public_key, :ssl] ++ if(Mix.env() == :test, do: [:eunit], else: [])
    ]

  defp deps do
    [
      {:ranch, "~> 2.1"},
      {:eiconv, "~> 1.0", optional: true},
      {:proper, "~> 1.4", only: :test, runtime: false},
      {:swoosh, "~> 1.28", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
