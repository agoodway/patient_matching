defmodule Mix.Tasks.Eval.Run do
  @shortdoc "Runs the patient-matching eval suite and prints a report"
  @moduledoc """
  Trains and links/deduplicates every run in `eval/suite.json` against the
  generated population, scores the golden scenarios, and prints a report.
  Reporting only: it never fails on quality, just on errors.

      mix eval.run                      # all runs + golden scenarios
      mix eval.run --run enterprise_mpi # one or more named runs (repeatable)
      mix eval.run --golden-only        # golden scenarios only (trains the golden model)
      mix eval.run --no-golden
      mix eval.run --save-baseline      # also write eval/baseline.json
      mix eval.run --json path.json     # full metrics (default eval/results/latest.json)

  The golden model is the run named by `golden_model` in the suite, trained
  on the full population.
  """
  use Mix.Task
  alias PatientMatchingEval.{Dataset, Execute, Golden, Metrics, Reference, Report}

  @suite "eval/suite.json"
  @baseline "eval/baseline.json"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          run: :keep,
          golden_only: :boolean,
          no_golden: :boolean,
          save_baseline: :boolean,
          json: :string,
          population: :string
        ]
      )

    Mix.Task.run("app.start")
    Logger.configure(level: :error)
    suite = Reference.json!(@suite)
    dataset = Dataset.load(opts[:population] || suite["population"])
    wanted = Keyword.get_values(opts, :run)

    specs =
      cond do
        opts[:golden_only] -> []
        wanted == [] -> suite["runs"]
        true -> Enum.filter(suite["runs"], &(&1["name"] in wanted))
      end

    {metrics, models} =
      specs
      |> Enum.map(fn spec ->
        Mix.shell().info("running #{spec["name"]} …")
        raw = Execute.run(spec, dataset)
        {Metrics.compute(raw, dataset), {spec["name"], raw.model}}
      end)
      |> Enum.unzip()

    golden =
      unless opts[:no_golden] do
        model = golden_model(suite, Map.new(models), dataset)
        suite["scenarios"] |> Golden.load() |> Golden.evaluate(model)
      end

    baseline = if File.exists?(@baseline), do: Reference.json!(@baseline)
    Mix.shell().info(Report.render(metrics, golden, baseline))

    json_path = opts[:json] || "eval/results/latest.json"
    File.mkdir_p!(Path.dirname(json_path))

    File.write!(
      json_path,
      Jason.encode!(jsonable(%{runs: metrics, golden: golden}), pretty: true)
    )

    Mix.shell().info("\nfull metrics → #{json_path}")

    if opts[:save_baseline], do: save_baseline(metrics, golden)
  end

  defp golden_model(suite, models, dataset) do
    name = suite["golden_model"]

    Map.get_lazy(models, name, fn ->
      Mix.shell().info("training golden model #{name} …")
      spec = Enum.find(suite["runs"], &(&1["name"] == name))

      PatientMatching.train(
        Dataset.from_sources(dataset, spec["sources"]),
        PatientMatching.Presets.patient_mpi()
      )
    end)
  end

  defp save_baseline(metrics, golden) do
    keys = ~w(blocking_recall precision recall recall_with_review false_matches review)a

    baseline = %{
      saved_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      runs: Map.new(metrics, fn m -> {m.name, Map.take(m, keys)} end),
      golden: Map.new(golden || [], &{&1.id, &1.pass})
    }

    File.write!(@baseline, Jason.encode!(baseline, pretty: true) <> "\n")
    Mix.shell().info("baseline → #{@baseline}")
  end

  # Tuples and atom-keyed nested data into JSON-safe terms.
  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(other), do: other
end
