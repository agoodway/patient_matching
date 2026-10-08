defmodule Mix.Tasks.Eval.Run do
  @shortdoc "Runs the patient-matching eval suite and prints a report"
  @moduledoc """
  Trains and links/deduplicates every run in `eval/suite.json` against the
  generated population, scores the golden scenarios, and prints a report.
  Reporting by default; `--check` exits unsuccessfully on quality target violations.

      mix eval.run                      # all runs + golden scenarios
      mix eval.run --run enterprise_mpi # one or more named runs (repeatable)
      mix eval.run --golden-only        # golden scenarios only (trains the golden model)
      mix eval.run --no-golden
      mix eval.run --save-baseline      # also write eval/baseline.json
      mix eval.run --check              # enforce suite acceptance targets
      mix eval.run --json path.json     # full metrics (default eval/results/latest.json)

  The golden model is the run named by `golden_model` in the suite, trained
  on the full population.
  """
  use Mix.Task
  alias PatientMatchingEval.{Acceptance, Artifacts, Evaluation, Reference, Report}

  @suite "eval/suite.json"
  @baseline "eval/baseline.json"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          run: :keep,
          golden_only: :boolean,
          no_golden: :boolean,
          save_baseline: :boolean,
          json: :string,
          population: :string,
          check: :boolean
        ]
      )

    if positional != [] or invalid != [],
      do: Mix.raise("invalid eval arguments: #{inspect(positional ++ invalid)}")

    Mix.Task.run("app.start")
    Logger.configure(level: :error)
    suite = Reference.json!(@suite)
    result = Evaluation.population(opts[:population] || suite["population"], opts)
    metrics = result.runs
    golden = result.golden
    stored_baseline = if File.exists?(@baseline), do: Reference.json!(@baseline)
    {status, baseline} = Evaluation.baseline(stored_baseline, result.dataset_hashes)
    Mix.shell().info("baseline: #{status}")
    Mix.shell().info(Report.render(metrics, golden, baseline))

    json_path = opts[:json] || "eval/results/latest.json"

    Artifacts.report!(json_path, Artifacts.jsonable(Map.put(result, :baseline_status, status)), [
      result.population
    ])

    Mix.shell().info("\nfull metrics → #{json_path}")

    if opts[:check] do
      case Acceptance.failures(metrics, golden, suite) do
        [] -> Mix.shell().info("acceptance targets passed")
        failures -> Mix.raise("acceptance targets failed:\n" <> Enum.join(failures, "\n"))
      end
    end

    if opts[:save_baseline],
      do: save_baseline(metrics, golden, result.dataset_hashes, result.population)
  end

  defp save_baseline(metrics, golden, hashes, population) do
    keys = ~w(blocking_recall precision recall recall_with_review false_matches review)a

    baseline = %{
      dataset_hashes: hashes,
      saved_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      runs: Map.new(metrics, fn m -> {m.name, Map.take(m, keys)} end),
      golden: Map.new(golden || [], &{&1.id, &1.pass})
    }

    Artifacts.report!(@baseline, baseline, [population, "eval/data/population"])
    Mix.shell().info("baseline → #{@baseline}")
  end
end
