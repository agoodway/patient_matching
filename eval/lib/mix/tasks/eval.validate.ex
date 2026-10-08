defmodule Mix.Tasks.Eval.Validate do
  @shortdoc "Validates stored synthetic datasets and reports coverage without changing them"
  @moduledoc """
      mix eval.validate --population DIR [--json eval/results/validation.json]
      mix eval.validate --datasets DIR [--json eval/results/validation.json]

  Structural errors, hash mismatches and missing challenge quotas fail. Sparse
  ordinary population slices warn; matcher quality is evaluated separately.
  """
  use Mix.Task
  alias PatientMatchingEval.{Artifacts, Validation}

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [population: :string, datasets: :string, json: :string])

    if positional != [] or invalid != [] or (opts[:population] && opts[:datasets]),
      do: Mix.raise("use --population DIR or --datasets DIR")

    report =
      if opts[:datasets],
        do: Validation.bundle(opts[:datasets]),
        else: Validation.population(opts[:population] || "eval/data/population")

    out = opts[:json] || "eval/results/validation.json"

    Artifacts.report!(out, Artifacts.jsonable(report), [
      opts[:datasets] || opts[:population] || "eval/data/population"
    ])

    reports = Map.get(report, :datasets, %{"population" => report})

    Enum.each(reports, fn {role, row} ->
      Mix.shell().info(
        "#{role}: #{length(row.errors)} structural errors, #{length(row.warnings)} warnings"
      )

      Enum.each(row.warnings, &Mix.shell().info("  warning: #{&1}"))
    end)

    Mix.shell().info("coverage report → #{out}")
    if report.errors != [], do: Mix.raise(Enum.join(report.errors, "\n"))
  end
end
