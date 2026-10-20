defmodule PatientMatching.MixProject do
  use Mix.Project

  def project do
    [
      app: :patient_matching,
      version: "0.2.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Explainable Fellegi–Sunter probabilistic patient record linkage",
      package: [
        licenses: ["MIT"],
        links: %{},
        files: [
          "lib",
          "test",
          "mix.exs",
          ".formatter.exs",
          ".credo.exs",
          ".doctor.exs",
          ".sobelow-conf",
          "README.md",
          "CHANGELOG.md",
          "LICENSE"
        ]
      ],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [plt_file: {:no_warn, "priv/plts/dialyzer.plt"}, plt_add_apps: [:ex_unit]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  # The eval harness (mix eval.*) is a dev-only tool and never ships in the package.
  defp elixirc_paths(:dev), do: ["lib", "eval/lib"]
  defp elixirc_paths(_), do: ["lib"]

  def cli, do: [preferred_envs: [check: :test, precommit: :test]]

  defp aliases do
    [
      check: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "doctor",
        "sobelow --config",
        "dialyzer",
        "test"
      ],
      precommit: ["check"]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, github: "dannote/ex_dna", branch: "master", only: [:dev, :test], runtime: false},
      {:ex_slop,
       github: "dannote/ex_slop", branch: "master", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end
end
