defmodule PatientMatchingEval.Validation do
  @moduledoc "Read-only structural validation and synthetic coverage diagnostics."
  alias PatientMatchingEval.{Artifacts, Challenges, Dataset, Population, Reference}

  @relations ~w(mother father spouse twin junior_of ssn_lender)
  @required_tags ~w(accented apostrophe compound_surname_partial dob_day_month_swap dob_estimated_jan1 dob_format_compact dob_format_dmy dob_format_mdy_dash dob_format_mdy_nopad dob_off_by_one_day dob_placeholder dob_typo english_name evaluation_only_alias goes_by_middle jan1_dob middle_in_given name_swap newborn_mother_surname newborn_placeholder nickname particle_spacing phone_country_code phone_household phone_missing phone_of_parent phone_placeholder phone_stale phone_typo phone_work sex_error sex_missing sex_numeric_code sex_unknown_code spelling_variant ssn_borrowed ssn_guarantor ssn_itin ssn_last4_only ssn_missing ssn_none ssn_placeholder ssn_typo suffix_in_family surname_changed_since truncated_family truncated_given typo_family typo_given unknown_patient zip_missing zip_stale zip_typo)

  @doc "All modeled record conditions, including absent conditions."
  def tag_names, do: @required_tags

  @doc "Checks raw rows before indexing so duplicate IDs cannot disappear."
  def structural(records, truth, people) do
    r = Map.new(records, &{&1["id"], &1})
    p = Map.new(people, &{&1["person_id"], &1})
    record_ids = MapSet.new(records, & &1["id"])
    truth_ids = MapSet.new(truth, & &1["id"])

    Enum.flat_map(records, &metadata_errors(&1, :record)) ++
      Enum.flat_map(truth, &metadata_errors(&1, :truth)) ++
      Enum.flat_map(people, &metadata_errors(&1, :person)) ++
      duplicate_errors(records, "id", "record") ++
      duplicate_errors(truth, "id", "truth") ++
      duplicate_errors(people, "person_id", "person") ++
      check(record_ids == truth_ids, "mismatched record/truth ID sets") ++
      Enum.flat_map(truth, &truth_errors(&1, r, p)) ++
      Enum.flat_map(people, &person_errors(&1, p))
  end

  defp metadata_errors(row, kind) do
    required =
      case kind do
        :record -> ~w(id source)
        :truth -> ~w(id person_id source household group origin foreign_born age as_of tags)
        :person -> ~w(person_id household group origin foreign_born sex dob)
      end

    Enum.flat_map(required, fn field ->
      value = row[field]

      valid =
        case field do
          "tags" -> is_list(value) and Enum.all?(value, &is_binary/1)
          "foreign_born" -> is_boolean(value)
          field when field in ~w(person_id household) -> is_integer(value) and value > 0
          "age" -> is_integer(value) and value >= 0
          "sex" -> value in ["M", "F"]
          _ -> is_binary(value) and value != ""
        end

      check(
        valid,
        "missing or malformed #{kind} #{field} for #{inspect(row["id"] || row["person_id"])}"
      )
    end)
  end

  defp duplicate_errors(rows, key, label) do
    rows
    |> Enum.frequencies_by(& &1[key])
    |> Enum.flat_map(fn {id, count} ->
      check(id != nil and count == 1, "duplicate or missing #{label} ID #{inspect(id)}")
    end)
  end

  defp truth_errors(t, records, people) do
    case {records[t["id"]], people[t["person_id"]]} do
      {nil, _} ->
        ["dangling truth record #{t["id"]}"]

      {_, nil} ->
        ["dangling truth person #{inspect(t["person_id"])}"]

      {r, p} ->
        Enum.flat_map(~w(household group origin foreign_born), fn field ->
          check(t[field] == p[field], "inconsistent truth #{field} for #{t["id"]}")
        end) ++
          check(t["source"] == r["source"], "inconsistent truth source for #{t["id"]}") ++
          snapshot_errors(t, p)
    end
  end

  defp snapshot_errors(t, p) do
    with {:ok, birth} <- parse_date(p["dob"]), {:ok, snapshot} <- parse_date(t["as_of"]) do
      check(Date.compare(snapshot, birth) != :lt, "snapshot before birth for #{t["id"]}") ++
        check(
          t["age"] == Population.age(birth, snapshot),
          "inconsistent truth age for #{t["id"]}"
        )
    else
      _ -> ["invalid birth/snapshot date for #{t["id"]}"]
    end
  end

  defp person_errors(p, people) do
    check(match?({:ok, _}, parse_date(p["dob"])), "invalid DOB for person #{p["person_id"]}") ++
      Enum.flat_map(@relations, fn role ->
        id = p[role]

        cond do
          id == nil -> []
          id == p["person_id"] -> ["self-relation #{role} for person #{id}"]
          people[id] == nil -> ["dangling #{role} for person #{p["person_id"]}"]
          true -> relation_errors(p, people[id], role)
        end
      end)
  end

  defp relation_errors(p, other, role) when role in ["spouse", "twin"] do
    check(other[role] == p["person_id"], "nonreciprocal #{role} for person #{p["person_id"]}") ++
      if(role == "twin",
        do: check(p["dob"] == other["dob"], "unequal twin DOBs for person #{p["person_id"]}"),
        else: []
      )
  end

  defp relation_errors(p, other, role) when role in ["mother", "father"] do
    sex = if role == "mother", do: "F", else: "M"

    check(other["sex"] == sex, "incorrect synthetic #{role} role for person #{p["person_id"]}") ++
      check(
        other["household"] == p["household"],
        "parent outside household for person #{p["person_id"]}"
      ) ++
      check(other["dob"] < p["dob"], "parent born after child for person #{p["person_id"]}")
  end

  defp relation_errors(_p, _other, _role), do: []
  defp check(true, _message), do: []
  defp check(false, message), do: [message]
  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)
  defp parse_date(_), do: {:error, :invalid_date}

  @doc "Assesses one stored population without writing dataset files."
  def population(dir) do
    dataset = Dataset.load(dir)
    coverage = coverage(dataset)

    sparse =
      for {tag, row} <- coverage.tags,
          row.true_pairs < 100,
          do: "#{tag}: #{row.support} (#{row.true_pairs} true pairs)"

    %{
      errors: [],
      warnings: dataset.warnings ++ sparse,
      hashes: dataset.hashes,
      coverage: coverage
    }
  end

  @doc "Coverage denominators and configured demographic differences (diagnostics only)."
  def coverage(dataset) do
    records = dataset.records
    people = Map.values(dataset.people)
    counts = Enum.frequencies_by(records, &Dataset.person(dataset, &1.id))
    true_pairs = Dataset.true_pairs_dedupe(dataset, records)
    tagged = Enum.group_by(dataset.truth, fn {_id, t} -> t["person_id"] end)

    tags =
      (@required_tags ++ Enum.flat_map(Map.values(dataset.truth), & &1["tags"]))
      |> Enum.uniq()
      |> Enum.sort()

    pairs_by_tag =
      Enum.reduce(true_pairs, %{}, fn {a, b}, acc ->
        Enum.reduce(Enum.uniq(dataset.truth[a]["tags"] ++ dataset.truth[b]["tags"]), acc, fn tag,
                                                                                             acc ->
          Map.update(acc, tag, 1, &(&1 + 1))
        end)
      end)

    tag_counts = Enum.frequencies(Enum.flat_map(Map.values(dataset.truth), & &1["tags"]))

    tags =
      Map.new(tags, fn tag ->
        distinct =
          Enum.count(tagged, fn {_, rows} ->
            Enum.any?(rows, fn {_, t} -> tag in t["tags"] end)
          end)

        n = Map.get(pairs_by_tag, tag, 0)

        {tag,
         %{
           records: Map.get(tag_counts, tag, 0),
           distinct_people: distinct,
           true_pairs: n,
           support: support(n)
         }}
      end)

    source_sets =
      Enum.group_by(records, & &1.source, &Dataset.person(dataset, &1.id))
      |> Map.new(fn {s, ids} -> {s, MapSet.new(ids)} end)

    metro = Reference.json!("eval/data/curated/metro.json")
    group_counts = Enum.frequencies_by(people, & &1["group"])

    %{
      people: length(people),
      records: length(records),
      distinct_people_with_records: map_size(counts),
      true_pairs: MapSet.size(true_pairs),
      records_per_person:
        Enum.frequencies(Enum.map(people, &Map.get(counts, &1["person_id"], 0))),
      missingness_by_source: missingness(records),
      source_overlap:
        for(
          {a, aset} <- source_sets,
          {b, bset} <- source_sets,
          a < b,
          into: %{},
          do: {"#{a} × #{b}", MapSet.size(MapSet.intersection(aset, bset))}
        ),
      relationships:
        Map.new(@relations, fn role -> {role, Enum.count(people, &(&1[role] != nil))} end),
      identifier_collisions: collisions(records, dataset),
      tags: tags,
      demographics:
        Map.new(~w(group origin foreign_born sex), fn key ->
          {key, Enum.frequencies_by(people, &to_string(&1[key]))}
        end)
        |> Map.put("age_band", Enum.frequencies_by(people, &age_band(&1["dob"]))),
      group_assumption_differences:
        Map.new(metro["group_shares"], fn {group, share} ->
          {group, Map.get(group_counts, group, 0) / max(length(people), 1) - share}
        end),
      demographic_note:
        "Differences from configured synthetic assumptions are diagnostics, not evidence of real-world representativeness."
    }
  end

  @doc "Support label for a true-pair denominator."
  def support(0), do: "zero-support"
  def support(n) when n < 100, do: "low-support"
  def support(_), do: "supported"

  defp missingness(records) do
    records
    |> Enum.group_by(& &1.source)
    |> Map.new(fn {source, rows} ->
      {source,
       %{
         records: length(rows),
         missing:
           Map.new(~w(given_name family_name dob sex zip phone ssn street)a, fn field ->
             {field, Enum.count(rows, &(Map.get(&1, field) in [nil, ""]))}
           end)
       }}
    end)
  end

  defp collisions(records, dataset) do
    Map.new([:mrn, :ssn, :phone], fn field ->
      groups =
        records
        |> Enum.reject(&(Map.get(&1, field) in [nil, ""]))
        |> Enum.group_by(fn r -> if field == :mrn, do: {r.source, r.mrn}, else: r[field] end)

      {field,
       %{
         shared_values: Enum.count(groups, fn {_, rows} -> length(rows) > 1 end),
         distinct_person_collisions:
           Enum.count(groups, fn {_, rows} ->
             length(Enum.uniq_by(rows, &Dataset.person(dataset, &1.id))) > 1
           end)
       }}
    end)
  end

  defp age_band(dob) do
    age = Population.age(Date.from_iso8601!(dob), Population.today())

    cond do
      age < 1 -> "infant"
      age < 18 -> "child"
      age < 65 -> "adult"
      true -> "senior"
    end
  end

  @doc "Validates stored challenges and verifies their manifest hashes."
  def challenges(dir) do
    Artifacts.require!(
      dir,
      ~w(cases.jsonl manifest.json),
      "mix eval.gen --benchmark --out #{Path.dirname(dir)}"
    )

    manifest = Reference.json!(Path.join(dir, "manifest.json"))
    hashes = Artifacts.verify!(dir, manifest, ["cases.jsonl"])
    cases = Artifacts.rows(Path.join(dir, "cases.jsonl"))

    %{
      errors: Challenges.validate(cases),
      warnings: [],
      hashes: hashes,
      coverage: Challenges.coverage(cases)
    }
  end

  @doc "Loads and validates the fixed benchmark index and every dataset."
  def bundle(dir) do
    Artifacts.require!(dir, ["index.json"], "mix eval.gen --benchmark --out #{dir}")
    index = Reference.json!(Path.join(dir, "index.json"))

    expected = [
      {"primary", 2026, 50000},
      {"holdout_2027", 2027, 10000},
      {"holdout_2028", 2028, 10000},
      {"challenges", 2029, nil}
    ]

    actual = Enum.map(index["datasets"], &{&1["role"], &1["seed"], &1["people_target"]})

    if actual != expected,
      do: Mix.raise("benchmark index does not describe the required fixed datasets")

    reports =
      Map.new(index["datasets"], fn entry ->
        path = Path.join(dir, entry["path"])

        if Artifacts.hash(Path.join(path, "manifest.json")) != entry["manifest_hash"],
          do: Mix.raise("dataset manifest hash mismatch: #{path}")

        manifest = Reference.json!(Path.join(path, "manifest.json"))

        if manifest["seed"] != entry["seed"] or
             manifest["parameters"]["people"] != entry["people_target"],
           do: Mix.raise("dataset parameters mismatch: #{path}")

        if entry["people_target"] && manifest["people"] != entry["people_target"],
          do: Mix.raise("benchmark population count mismatch: #{path}")

        report = if entry["role"] == "challenges", do: challenges(path), else: population(path)

        if report.hashes != entry["hashes"],
          do: Mix.raise("bundle dataset hash mismatch: #{path}")

        {entry["role"], report}
      end)

    %{
      index: index,
      datasets: reports,
      errors:
        Enum.flat_map(reports, fn {role, report} -> Enum.map(report.errors, &"#{role}: #{&1}") end)
    }
  end
end
