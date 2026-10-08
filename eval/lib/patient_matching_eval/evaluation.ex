defmodule PatientMatchingEval.Evaluation do
  @moduledoc "Matcher evaluation over immutable stored datasets, independent of generation."
  alias PatientMatchingEval.{
    Artifacts,
    Challenges,
    Dataset,
    Execute,
    Golden,
    Metrics,
    Reference,
    Validation
  }

  @doc "Runs selected suite entries, training each on its stored population's input."
  def population(dir, opts \\ []) do
    suite = Reference.json!("eval/suite.json")
    wanted = Keyword.get_values(opts, :run)
    unknown = wanted -- Enum.map(suite["runs"], & &1["name"])
    if unknown != [], do: Mix.raise("unknown eval runs: #{Enum.join(unknown, ", ")}")
    dataset = Dataset.load(dir)
    Enum.each(dataset.warnings, &Mix.shell().info("warning: #{&1}"))

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
        model = enterprise_model(dataset, Map.new(models))
        suite["scenarios"] |> Golden.load() |> Golden.evaluate(model)
      end

    %{
      runs: metrics,
      golden: golden,
      population: dir,
      dataset_hashes: dataset.hashes,
      generator_version: dataset.manifest["generator_version"],
      warnings: dataset.warnings
    }
  end

  @doc "Enterprise model trained on the committed default population (or supplied input)."
  def enterprise_model(dataset, models \\ %{}) do
    suite = Reference.json!("eval/suite.json")
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

  @doc "Gates baseline deltas on identical stored dataset hashes."
  def baseline(nil, _hashes), do: {:missing, nil}
  def baseline(%{"dataset_hashes" => hashes} = baseline, hashes), do: {:verified, baseline}
  def baseline(%{"dataset_hashes" => _}, _hashes), do: {:different_dataset, nil}
  def baseline(_baseline, _hashes), do: {:unverified, nil}

  @doc "Evaluates every stored benchmark population and keeps challenge metrics separate."
  def benchmark(dir, opts \\ []) do
    validation = Validation.bundle(dir)
    if validation.errors != [], do: Mix.raise(Enum.join(validation.errors, "\n"))
    entries = validation.index["datasets"]

    populations =
      entries
      |> Enum.reject(&(&1["role"] == "challenges"))
      |> Map.new(fn entry ->
        path = Path.join(dir, entry["path"])
        Mix.shell().info("\npopulation #{entry["role"]}: #{path}")
        {entry["role"], population(path, opts)}
      end)

    challenge = Enum.find(entries, &(&1["role"] == "challenges"))
    default = Dataset.load("eval/data/population")
    model = enterprise_model(default)
    path = Path.join(dir, challenge["path"])
    cases = Artifacts.rows(Path.join(path, "cases.jsonl"))

    results =
      Challenges.evaluate(cases, model)
      |> Map.merge(%{
        dataset_hashes: validation.datasets["challenges"].hashes,
        training_dataset_hashes: default.hashes
      })

    %{
      populations: populations,
      summary: summary(populations),
      challenges: results,
      bundle_index_hash: Artifacts.hash(Path.join(dir, "index.json"))
    }
  end

  @doc "Minimum and maximum population metrics per suite entry, without pooling people."
  def summary(populations) do
    populations
    |> Map.values()
    |> Enum.flat_map(& &1.runs)
    |> Enum.group_by(& &1.name)
    |> Map.new(fn {name, rows} ->
      {name,
       Map.new(
         ~w(blocking_recall precision recall recall_with_review false_matches review)a,
         fn metric ->
           values = Enum.map(rows, & &1[metric]) |> Enum.reject(&is_nil/1)

           {metric,
            if(values == [],
              do: %{min: nil, max: nil},
              else: %{min: Enum.min(values), max: Enum.max(values)}
            )}
         end
       )}
    end)
  end
end
