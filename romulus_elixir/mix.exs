defmodule RomulusElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :romulus_elixir,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [:error_handling, :unknown]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :crypto, :ssl],
      mod: {RomulusElixir.Application, []}
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:nimble_options, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      
      # Libvirt interaction
      {:porcelain, "~> 2.0"},
      {:erlexec, "~> 2.0"},
      
      # Kubernetes client
      {:k8s, "~> 2.7"},
      {:mint, "~> 1.6"},
      {:castore, "~> 1.0"},
      
      # Cloud-init & templating
      # EEx is built into Elixir - no external dependency needed
      
      # CLI
      {:optimus, "~> 0.5"},
      {:table_rex, "~> 4.0"},
      {:owl, "~> 0.12"},
      
      # Configuration
      {:toml, "~> 0.7"},
      
      # Testing & Development
      {:ex_unit_notifier, "~> 1.3", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:mock, "~> 0.3", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.compile"],
      test: ["test --no-start"],
      "test.unit": ["test test/unit --no-start"],
      "test.integration": ["test test/integration --no-start --include integration"],
      "test.all": ["test --include integration"],
      quality: ["format --check-formatted", "credo --strict", "dialyzer", "sobelow"],
      
      # Romulus-specific tasks
      "romulus.plan": ["run --no-halt -e 'RomulusElixir.CLI.plan()'"],
      "romulus.apply": ["run --no-halt -e 'RomulusElixir.CLI.apply()'"],
      "romulus.destroy": ["run --no-halt -e 'RomulusElixir.CLI.destroy()'"],
      "romulus.render-cloudinit": ["run --no-halt -e 'RomulusElixir.CLI.render_cloudinit()'"],
      "romulus.k8s.bootstrap": ["run --no-halt -e 'RomulusElixir.CLI.bootstrap_k8s()'"]
    ]
  end

  defp releases do
    [
      romulus: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
