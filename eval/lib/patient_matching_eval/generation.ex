defmodule PatientMatchingEval.Generation do
  @moduledoc "Explicit generation of persistent synthetic populations and benchmark bundles."
  alias PatientMatchingEval.{
    Artifacts,
    Challenges,
    Population,
    Records,
    Reference,
    Rng,
    Validation
  }

  @version "2"
  @files ~w(records.jsonl truth.jsonl people.jsonl)

  @doc "Generates, structurally validates, then persists one population."
  def population(out, target, seed, force \\ false, opts \\ []) do
    Artifacts.available!(out, force)
    if target < 1, do: Mix.raise("--people must be positive")
    Rng.seed(seed)
    ref = Reference.load()
    population = Population.build(ref, target, exact: opts[:exact] || false)
    {records, truth} = Records.build(ref, population)
    people = Enum.map(population.people, &person_json/1)
    errors = Validation.structural(records, truth, people)

    if errors != [],
      do: Mix.raise("generated population failed validation:\n" <> Enum.join(errors, "\n"))

    write_dataset(out, force, fn stage ->
      Artifacts.jsonl(Path.join(stage, "records.jsonl"), records)
      Artifacts.jsonl(Path.join(stage, "truth.jsonl"), truth)
      Artifacts.jsonl(Path.join(stage, "people.jsonl"), people)

      manifest =
        provenance(seed, %{"people" => target, "exact_people" => opts[:exact] || false})
        |> Map.merge(%{
          "people" => length(people),
          "records" => length(records),
          "households" => people |> Enum.uniq_by(& &1["household"]) |> length(),
          "records_by_source" => Enum.frequencies_by(records, & &1["source"]),
          "people_by_group" => Enum.frequencies_by(people, & &1["group"]),
          "tag_counts" => truth |> Enum.flat_map(& &1["tags"]) |> Enum.frequencies(),
          "output_hashes" => Artifacts.hashes(stage, @files)
        })

      Artifacts.json(Path.join(stage, "manifest.json"), manifest)
      manifest
    end)
  end

  @doc "Generates challenges separately from population metrics."
  def challenges(out, seed, force \\ false) do
    Artifacts.available!(out, force)
    cases = Challenges.build(seed)
    errors = Challenges.validate(cases)
    if errors != [], do: Mix.raise(Enum.join(errors, "\n"))

    write_dataset(out, force, fn stage ->
      Artifacts.jsonl(Path.join(stage, "cases.jsonl"), cases)

      manifest =
        provenance(seed, %{"people" => nil, "cases_per_family" => 200})
        |> Map.merge(%{
          "cases" => length(cases),
          "coverage" => Challenges.coverage(cases),
          "output_hashes" => Artifacts.hashes(stage, ["cases.jsonl"])
        })

      Artifacts.json(Path.join(stage, "manifest.json"), manifest)
      manifest
    end)
  end

  @doc "Generates the fixed 50k/10k/10k/challenges benchmark bundle and hash index."
  def benchmark(out, force \\ false) do
    Artifacts.available!(out, force)

    write_dataset(out, force, fn stage ->
      entries =
        for {role, target, seed} <- [
              {"primary", 50000, 2026},
              {"holdout_2027", 10000, 2027},
              {"holdout_2028", 10000, 2028},
              {"challenges", nil, 2029}
            ] do
          path = Path.join(stage, role)

          manifest =
            if target,
              do: population(path, target, seed, false, exact: true),
              else: challenges(path, seed)

          Mix.shell().info("generated #{role} (seed #{seed})")

          %{
            "role" => role,
            "path" => role,
            "seed" => seed,
            "people_target" => target,
            "hashes" => manifest["output_hashes"],
            "manifest_hash" => Artifacts.hash(Path.join(path, "manifest.json"))
          }
        end

      index = %{
        "generator_version" => @version,
        "reference_date" => Date.to_iso8601(Population.today()),
        "datasets" => entries
      }

      Artifacts.json(Path.join(stage, "index.json"), index)
      index
    end)
  end

  defp provenance(seed, parameters) do
    %{
      "generator_version" => @version,
      "reference_date" => Date.to_iso8601(Population.today()),
      "seed" => seed,
      "parameters" => Map.put(parameters, "seed", seed),
      "input_hashes" => Artifacts.inputs()
    }
  end

  # Build beside the destination, and replace only after validation and all writes succeed.
  defp write_dataset(out, force, fun) do
    File.mkdir_p!(Path.dirname(out))
    stage = out <> ".staging-#{System.unique_integer([:positive])}"
    File.mkdir!(stage)

    try do
      result = fun.(stage)
      Artifacts.available!(out, force)
      if File.exists?(out), do: File.rm_rf!(out)
      File.rename!(stage, out)
      result
    after
      File.rm_rf!(stage)
    end
  end

  defp person_json(p) do
    %{
      "person_id" => p.pid,
      "household" => p.household,
      "group" => to_string(p.group),
      "origin" => p.origin,
      "foreign_born" => p.foreign_born,
      "sex" => p.sex,
      "dob" => Date.to_iso8601(p.dob),
      "given" => p.given,
      "middle" => p.middle,
      "surnames" => Enum.map(p.surnames, fn {d, s} -> [Date.to_iso8601(d), s] end),
      "suffix" => p.suffix,
      "ssn_kind" => p.ssn |> elem(0) |> to_string(),
      "ssn_lender" => Map.get(p, :ssn_lender),
      "insured" => p.insured,
      "spouse" => p.spouse,
      "mother" => p.mother,
      "father" => p.father,
      "twin" => p.twin,
      "junior_of" => p.junior_of
    }
  end
end
