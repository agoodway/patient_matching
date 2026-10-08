defmodule PatientMatchingEval.ReportingTest do
  use ExUnit.Case
  alias PatientMatchingEval.{Artifacts, Dataset, Evaluation, Generation, Report, Validation}

  setup do
    dir = Path.join(System.tmp_dir!(), "eval-reporting-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "matcher reports retain zero-support conditions and distinct-person denominators", %{
    dir: dir
  } do
    Generation.population(dir, 100, 2026)
    result = Evaluation.population(dir, run: "enterprise_mpi", no_golden: true)
    [run] = result.runs
    assert run.tags["ssn_borrowed"].pairs == 0
    assert run.tags["ssn_borrowed"].support == "zero-support"
    assert Enum.all?(run.slices["group"], fn {_, row} -> Map.has_key?(row, :distinct_people) end)
    assert Report.render(result.runs, nil, nil) =~ "zero-support"
    coverage = Validation.coverage(Dataset.load(dir))

    for {tag, row} <- coverage.tags,
        do: assert(run.tags[tag].distinct_people == row.distinct_people)
  end

  test "legacy manifests warn and preserve bytes", %{dir: dir} do
    Generation.population(dir, 50, 2026)
    path = Path.join(dir, "manifest.json")

    manifest =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.drop(~w(generator_version output_hashes input_hashes reference_date parameters))

    Artifacts.json(path, manifest)
    before = Artifacts.hash(path)
    assert Dataset.load(dir).warnings == ["legacy population manifest: provenance unverified"]
    assert Validation.population(dir).errors == []
    assert Artifacts.hash(path) == before
  end

  test "reports cannot overwrite input datasets", %{dir: dir} do
    Generation.population(dir, 50, 2026)
    before = Artifacts.hashes(dir, ~w(records.jsonl truth.jsonl people.jsonl manifest.json))

    assert_raise Mix.Error, ~r/outside dataset/, fn ->
      Mix.Tasks.Eval.Validate.run([
        "--population",
        dir,
        "--json",
        Path.join(dir, "records.jsonl")
      ])
    end

    assert before ==
             Artifacts.hashes(dir, ~w(records.jsonl truth.jsonl people.jsonl manifest.json))
  end

  test "reports cannot reach dataset files through symlink directories", %{dir: dir} do
    dataset = Path.join(dir, "dataset")
    Generation.population(dataset, 50, 2026)
    File.ln_s!(dataset, Path.join(dir, "alias"))
    before = Artifacts.hash(Path.join(dataset, "records.jsonl"))

    assert_raise Mix.Error, ~r/outside dataset/, fn ->
      Artifacts.report!(Path.join(dir, "alias/records.jsonl"), %{}, [dataset])
    end

    assert Artifacts.hash(Path.join(dataset, "records.jsonl")) == before
  end

  test "report replacement cannot mutate a hard-linked dataset file", %{dir: dir} do
    dataset = Path.join(dir, "dataset")
    Generation.population(dataset, 50, 2026)
    input = Path.join(dataset, "records.jsonl")
    out = Path.join(dir, "report.json")
    File.ln!(input, out)
    before = Artifacts.hash(input)
    Artifacts.report!(out, %{}, [dataset])
    assert Artifacts.hash(input) == before
    assert Jason.decode!(File.read!(out)) == %{}
  end

  test "every population summary metric is reported as minimum and maximum" do
    rows =
      for recall <- [0.6, 0.8],
          do: %{
            name: "mpi",
            recall: recall,
            precision: 1.0,
            blocking_recall: 0.9,
            recall_with_review: 0.95,
            false_matches: 0,
            review: 10
          }

    summary = Evaluation.summary(%{"a" => %{runs: [hd(rows)]}, "b" => %{runs: [List.last(rows)]}})
    assert summary["mpi"].recall == %{min: 0.6, max: 0.8}
  end
end
