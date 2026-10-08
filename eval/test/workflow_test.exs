defmodule PatientMatchingEval.WorkflowTest do
  use ExUnit.Case
  alias PatientMatchingEval.{Challenges, Dataset, Generation, Validation}

  setup do
    dir = Path.join(System.tmp_dir!(), "patient-eval-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "generation persists deterministic bytes, hashes, and requires explicit overwrite", %{
    dir: dir
  } do
    a = Path.join(dir, "a")
    b = Path.join(dir, "b")
    Generation.population(a, 100, 2026)
    Generation.population(b, 100, 2026)

    for file <- ~w(records.jsonl truth.jsonl people.jsonl manifest.json) do
      assert File.read!(Path.join(a, file)) == File.read!(Path.join(b, file))
    end

    assert_raise Mix.Error, ~r/--force/, fn -> Generation.population(a, 100, 2027) end
    assert Dataset.load(a).hashes != %{}
    before = File.read!(Path.join(a, "records.jsonl"))
    report = Validation.population(a)
    assert report.errors == []
    assert File.read!(Path.join(a, "records.jsonl")) == before
    File.write!(Path.join(a, "records.jsonl"), before <> "\n")
    assert_raise Mix.Error, ~r/hash mismatch/, fn -> Dataset.load(a) end
  end

  test "force replacement is limited to generated datasets, preserving unrelated directories", %{
    dir: dir
  } do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "user.txt"), "keep")

    assert_raise Mix.Error, ~r/generated dataset/, fn ->
      Generation.population(dir, 50, 2026, true)
    end

    assert File.read!(Path.join(dir, "user.txt")) == "keep"
  end

  test "structural validation rejects corrupt sets, relations and truth attributes" do
    p = %{
      "person_id" => 1,
      "household" => 1,
      "group" => "white",
      "origin" => "us_white",
      "foreign_born" => false,
      "dob" => "2000-01-01",
      "sex" => "M"
    }

    r = %{"id" => "a", "source" => "hospital_a"}

    t =
      Map.merge(Map.take(p, ~w(household group origin foreign_born)), %{
        "id" => "a",
        "source" => "hospital_a",
        "person_id" => 1,
        "age" => 26,
        "as_of" => "2026-09-30",
        "tags" => []
      })

    assert Validation.structural([r], [t], [p]) == []
    assert Validation.structural([r, r], [t], [p]) != []
    assert Validation.structural([r], [t, t], [p]) != []
    assert Validation.structural([r], [t], [p, p]) != []
    assert Validation.structural([], [t], [p]) != []
    assert Validation.structural([r], [], [p]) != []
    assert Validation.structural([r], [%{t | "person_id" => 2}], [p]) != []
    assert Validation.structural([r], [%{t | "group" => "black"}], [p]) != []
    assert Validation.structural([r], [%{t | "source" => "payer"}], [p]) != []
    assert Validation.structural([r], [%{t | "as_of" => "1999-01-01"}], [p]) != []

    for relation <- ~w(mother father spouse twin junior_of ssn_lender) do
      assert Validation.structural([r], [t], [Map.put(p, relation, 1)]) != []
      assert Validation.structural([r], [t], [Map.put(p, relation, 999)]) != []
    end

    q = Map.merge(p, %{"person_id" => 2, "dob" => "1970-01-01", "sex" => "F"})
    assert Validation.structural([r], [t], [Map.put(p, "father", 2), q]) != []
    assert Validation.structural([r], [t], [Map.put(p, "spouse", 2), q]) != []
    assert Validation.structural([r], [t], [Map.put(p, "twin", 2), Map.put(q, "twin", 1)]) != []
    assert Validation.structural([r], [t], [p, q]) == []

    assert Validation.structural([r, Map.put(r, "id", "b")], [t, Map.put(t, "id", "b")], [p]) ==
             []
  end

  test "structural validation rejects missing or malformed consumer metadata" do
    p = %{"person_id" => 1, "dob" => "2000-01-01"}
    r = %{"id" => "a"}
    t = %{"id" => "a", "person_id" => 1, "as_of" => "2026-09-30", "age" => 26}
    assert Validation.structural([r], [t], [p]) != []

    assert Validation.structural(
             [%{"id" => "a", "source" => "hospital_a"}],
             [Map.put(t, "tags", "nickname")],
             [p]
           ) != []
  end

  test "challenge quotas require actual family evidence" do
    cases = Challenges.build(2029)

    stripped =
      Enum.map(cases, fn c ->
        c
        |> Map.update!("left", &Map.take(&1, ["id"]))
        |> Map.update!("right", &Map.take(&1, ["id"]))
      end)

    assert Challenges.validate(stripped) != []

    for category <-
          ~w(borrowed_ssn placeholder_dob mrn_reuse common_name_dob twins newborns evaluation_only_alias) do
      corrupted =
        Enum.map(cases, fn c ->
          if c["category"] == category,
            do:
              Map.update!(
                c,
                "right",
                &Map.drop(&1, ~w(ssn dob mrn given_name family_name phone zip street))
              ),
            else: c
        end)

      assert Challenges.validate(corrupted) != []
    end
  end

  test "coverage includes zero support and warns below 100 true pairs", %{dir: dir} do
    Generation.population(dir, 50, 2026)
    report = Validation.population(dir)
    assert report.warnings != []
    assert report.coverage.tags["ssn_borrowed"].true_pairs == 0
    assert report.coverage.tags["ssn_borrowed"].support == "zero-support"
    assert Enum.any?(report.coverage.tags, fn {_, row} -> row.support == "low-support" end)
    assert report.coverage.records_per_person != %{}
    assert report.coverage.missingness_by_source != %{}
  end

  test "challenge quotas, distinct ids despite reused MRNs, deterministic aliases", %{dir: dir} do
    cases = Challenges.build(2029)
    assert length(cases) == 1600
    assert Challenges.validate(cases) == []
    assert Challenges.build(2029) == cases
    ids = Enum.flat_map(cases, &[&1["left"]["id"], &1["right"]["id"]])
    assert Enum.uniq(ids) == ids

    for c <- Enum.filter(cases, &(&1["category"] == "mrn_reuse")) do
      assert c["left"]["mrn"] == c["right"]["mrn"]
      refute c["left"]["id"] == c["right"]["id"]
    end

    assert length(Challenges.aliases()) == 10
    for {a, b} <- Challenges.aliases(), do: refute(PatientMatching.Nicknames.nickname?(a, b))
    assert Challenges.validate(tl(cases)) != []
    Generation.challenges(dir, 2029)
    assert Validation.challenges(dir).errors == []
  end

  test "invalid generation flags and missing data have actionable errors", %{dir: dir} do
    assert_raise Mix.Error, ~r/--people|--seed/, fn ->
      Mix.Tasks.Eval.Gen.run(["--benchmark", "--people", "10"])
    end

    assert_raise Mix.Error, fn -> Mix.Tasks.Eval.Gen.run(["--typo"]) end
    assert_raise Mix.Error, ~r/mix eval.gen.*--out/, fn -> Dataset.load(dir) end
  end
end
