defmodule Mix.Tasks.Eval.Benchmark do
  @shortdoc "Evaluates a stored benchmark bundle; never generates data"
  @moduledoc """
      mix eval.benchmark --datasets eval/data/benchmark

  Supports --run NAME, --golden-only, --no-golden and --json PATH. Population
  metrics and min/max summaries are separate from challenge results. Quality
  and golden failures are reporting-only.
  """
  use Mix.Task
  alias PatientMatchingEval.{Artifacts, Evaluation, Report}

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          datasets: :string,
          run: :keep,
          golden_only: :boolean,
          no_golden: :boolean,
          json: :string
        ]
      )

    if positional != [] or invalid != [],
      do: Mix.raise("invalid benchmark arguments: #{inspect(positional ++ invalid)}")

    Mix.Task.run("app.start")
    Logger.configure(level: :error)
    dir = opts[:datasets] || "eval/data/benchmark"
    result = Evaluation.benchmark(dir, opts)

    Enum.each(Enum.sort(result.populations), fn {role, population} ->
      Mix.shell().info("\n#{role}\n" <> Report.render(population.runs, population.golden, nil))
    end)

    Mix.shell().info(
      "\npopulation minimum/maximum metrics:\n" <> Jason.encode!(result.summary, pretty: true)
    )

    Mix.shell().info(
      "\nchallenge results (model trained on committed default population):\n" <>
        Jason.encode!(result.challenges.groups, pretty: true)
    )

    Mix.shell().info(
      "challenge summary:\n" <> Jason.encode!(result.challenges.summary, pretty: true)
    )

    out = opts[:json] || "eval/results/benchmark.json"
    Artifacts.report!(out, Artifacts.jsonable(result), [dir, "eval/data/population"])
    Mix.shell().info("benchmark report → #{out}")
  end
end
