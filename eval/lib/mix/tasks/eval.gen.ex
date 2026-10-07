defmodule Mix.Tasks.Eval.Gen do
  @shortdoc "Generates the synthetic metro patient population for the eval suite"
  @moduledoc """
  Generates people, households and per-source MRN records from the static
  tables in `eval/data`, writing reproducible JSONL into `eval/data/population`.

      mix eval.gen [--people 4000] [--seed 2026] [--out eval/data/population]

  Outputs:

    * `records.jsonl` – one source record per line, exactly what a matcher sees
    * `truth.jsonl`   – per-record ground truth: person, household, group, tags
    * `people.jsonl`  – per-person facts and relationships (spouse, twin, junior, …)
    * `manifest.json` – parameters and summary counts

  Same seed and tables give byte-identical output.
  """
  use Mix.Task
  alias PatientMatchingEval.{Population, Records, Reference, Rng}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [people: :integer, seed: :integer, out: :string])

    target = Keyword.get(opts, :people, 4_000)
    seed = Keyword.get(opts, :seed, 2026)
    out = Keyword.get(opts, :out, "eval/data/population")

    Rng.seed(seed)
    ref = Reference.load()
    population = Population.build(ref, target)
    {records, truth} = Records.build(ref, population)

    File.mkdir_p!(out)
    jsonl(Path.join(out, "records.jsonl"), records)
    jsonl(Path.join(out, "truth.jsonl"), truth)
    jsonl(Path.join(out, "people.jsonl"), Enum.map(population.people, &person_json/1))

    manifest = %{
      "seed" => seed,
      "people" => length(population.people),
      "records" => length(records),
      "households" => population.people |> Enum.uniq_by(& &1.household) |> length(),
      "records_by_source" => Enum.frequencies_by(records, & &1["source"]),
      "people_by_group" => Enum.frequencies_by(population.people, &to_string(&1.group)),
      "tag_counts" => truth |> Enum.flat_map(& &1["tags"]) |> Enum.frequencies()
    }

    File.write!(Path.join(out, "manifest.json"), Jason.encode!(manifest, pretty: true) <> "\n")
    Mix.shell().info("#{manifest["people"]} people, #{manifest["records"]} records → #{out}")
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

  defp jsonl(path, rows) do
    File.write!(path, Enum.map(rows, &[Jason.encode!(&1), "\n"]))
  end
end
