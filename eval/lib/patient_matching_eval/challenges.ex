defmodule PatientMatchingEval.Challenges do
  @moduledoc "Separate evaluation-only difficult pairs with fixed family quotas."
  alias PatientMatchingEval.{Dataset, Rng}

  @families ~w(borrowed_ssn placeholder_dob missing_identity mrn_reuse common_name_dob twins newborns evaluation_only_alias)

  @doc "Evaluation-only aliases, independent of the matcher's nickname table."
  def aliases do
    "eval/data/curated/evaluation_aliases.csv"
    |> File.read!()
    |> String.split("\n", trim: true)
    |> tl()
    |> Enum.map(fn line ->
      [a, b] = String.split(line, ",")
      {a, b}
    end)
  end

  @doc "100 same-person and 100 different-person cases per family, half sparse."
  def build(seed) do
    Rng.seed(seed)

    for family <- @families, same <- [true, false], i <- 1..100 do
      variant = if rem(i, 2) == 0, do: "corroborated", else: "sparse"
      id = "#{family}-#{if same, do: "same", else: "different"}-#{i}"
      {left, right} = pair(family, same, variant, i)

      %{
        "id" => id,
        "category" => family,
        "title" => "#{family} #{variant}",
        "same_person" => same,
        "variant" => variant,
        "tags" => [family, variant],
        "risk" => if(same, do: "duplicate", else: "overlay"),
        "expect" => if(same, do: "match_or_review", else: "not_match"),
        "left" => Map.merge(left, %{"id" => id <> ":left", "source" => "challenge"}),
        "right" => Map.merge(right, %{"id" => id <> ":right", "source" => "challenge"})
      }
    end
  end

  defp pair(family, same, variant, i) do
    dob = Date.new!(Rng.int(1950, 2000), Rng.int(1, 12), Rng.int(1, 28)) |> Date.to_iso8601()
    name = Rng.pick(~w(MARIA JAMES ROBERT LINDA MICHAEL ELIZABETH))
    surname = Rng.pick(~w(GARCIA SMITH JOHNSON NGUYEN PATEL WILLIAMS))
    a = %{"given_name" => name, "family_name" => surname, "dob" => dob, "sex" => "F"}
    b = if same, do: a, else: %{a | "given_name" => "PATRICIA", "dob" => "1981-06-17"}

    {a, b} =
      if variant == "corroborated" do
        a =
          Map.merge(a, %{
            "ssn" => "#{Rng.int(200, 699)}#{Rng.int(10, 99)}#{Rng.int(1000, 9998)}",
            "phone" => "713#{Rng.int(2_000_000, 9_999_998)}",
            "zip" => "77005",
            "street" => "#{i + 100} MAIN ST"
          })

        b = Map.merge(b, Map.take(a, ~w(ssn phone zip street)))

        b =
          if same,
            do: b,
            else:
              b
              |> Map.put("ssn", "#{Rng.int(700, 799)}#{Rng.int(10, 99)}#{Rng.int(1000, 9998)}")
              |> Map.put("phone", "832#{Rng.int(2_000_000, 9_999_998)}")
              |> Map.put("street", "#{i + 800} OAK ST")

        {a, b}
      else
        {Map.delete(a, "sex"), Map.delete(b, "sex")}
      end

    family_pair(family, same, a, b, i)
  end

  defp family_pair("borrowed_ssn", _same, a, b, i) do
    ssn = "42156" <> String.pad_leading(to_string(1000 + i), 4, "0")
    {Map.put(a, "ssn", ssn), Map.put(b, "ssn", ssn)}
  end

  defp family_pair("placeholder_dob", _same, a, b, _i),
    do: {Map.put(a, "dob", "1900-01-01"), Map.put(b, "dob", "1900-01-01")}

  defp family_pair("missing_identity", _same, a, b, i) do
    fields =
      case rem(i, 3) do
        0 -> ~w(given_name family_name dob)
        1 -> ~w(given_name family_name)
        2 -> ~w(dob)
      end

    {a, Map.drop(b, fields)}
  end

  defp family_pair("mrn_reuse", _same, a, b, i),
    do: {Map.put(a, "mrn", "REUSED#{i}"), Map.put(b, "mrn", "REUSED#{i}")}

  defp family_pair("common_name_dob", _same, a, b, _i) do
    common = %{"given_name" => "MARIA", "family_name" => "GARCIA", "dob" => "1980-01-01"}
    {Map.merge(a, common), Map.merge(b, common)}
  end

  defp family_pair("twins", same, a, b, _i) do
    b =
      b
      |> Map.put("dob", a["dob"])
      |> Map.put("given_name", if(same, do: a["given_name"], else: "JULIA"))

    {a, b}
  end

  defp family_pair("newborns", same, a, b, i) do
    a =
      a
      |> Map.put("dob", "2026-09-#{String.pad_leading(to_string(rem(i, 28) + 1), 2, "0")}")
      |> Map.delete("ssn")
      |> Map.put("given_name", "BABY GIRL")

    b =
      b
      |> Map.put("dob", a["dob"])
      |> Map.delete("ssn")
      |> Map.put("given_name", if(same, do: "EMMA", else: "BABY GIRL"))

    {a, b}
  end

  defp family_pair("evaluation_only_alias", same, a, b, i) do
    {formal, nickname} = Enum.at(aliases(), rem(div(i - 1, 2), 10))
    b = b |> Map.put("given_name", nickname) |> Map.put("family_name", a["family_name"])
    b = if same, do: Map.put(b, "dob", a["dob"]), else: b
    {Map.put(a, "given_name", formal), b}
  end

  @doc "Validates pair structure, global record IDs and all family/variant quotas."
  def validate(cases) do
    ids = Enum.flat_map(cases, &[get_in(&1, ["left", "id"]), get_in(&1, ["right", "id"])])

    errors =
      if nil in ids or length(Enum.uniq(ids)) != length(ids),
        do: ["duplicate or missing challenge record IDs"],
        else: []

    case_ids = Enum.map(cases, & &1["id"])

    errors =
      if nil in case_ids or length(Enum.uniq(case_ids)) != length(case_ids),
        do: ["duplicate or missing challenge case IDs" | errors],
        else: errors

    quotas =
      for family <- @families,
          same <- [true, false],
          variant <- ["sparse", "corroborated"],
          Enum.count(
            cases,
            &(&1["category"] == family and &1["same_person"] == same and &1["variant"] == variant)
          ) != 50,
          do: "missing challenge quota: #{family} same_person=#{same} #{variant} (requires 50)"

    malformed =
      for c <- cases,
          c["category"] not in @families or c["same_person"] not in [true, false] or
            c["variant"] not in ["sparse", "corroborated"] or
            c["expect"] != if(c["same_person"], do: "match_or_review", else: "not_match") or
            not is_map(c["left"]) or not is_map(c["right"]),
          do: "malformed challenge #{c["id"]}"

    errors ++ quotas ++ malformed ++ Enum.flat_map(cases, &payload_errors/1)
  end

  defp payload_errors(c) do
    a = c["left"] || %{}
    b = c["right"] || %{}

    source =
      is_binary(a["source"]) and a["source"] != "" and is_binary(b["source"]) and
        b["source"] != ""

    corroborated = Enum.all?(~w(phone zip street), &(is_binary(a[&1]) and is_binary(b[&1])))
    sparse = Enum.all?(~w(phone zip street), &(a[&1] == nil and b[&1] == nil))
    variant = if c["variant"] == "corroborated", do: corroborated, else: sparse
    tags = is_list(c["tags"]) and c["category"] in c["tags"] and c["variant"] in c["tags"]
    evidence = evidence?(c["category"], a, b)

    if source and variant and tags and evidence,
      do: [],
      else: ["missing challenge evidence: #{c["id"]}"]
  end

  defp evidence?("borrowed_ssn", a, b),
    do: is_binary(a["ssn"]) and byte_size(a["ssn"]) == 9 and a["ssn"] == b["ssn"]

  defp evidence?("placeholder_dob", a, b),
    do: a["dob"] == "1900-01-01" and b["dob"] == "1900-01-01"

  defp evidence?("missing_identity", a, b),
    do:
      is_binary(a["given_name"]) and is_binary(a["family_name"]) and is_binary(a["dob"]) and
        Enum.any?(~w(given_name family_name dob), &(b[&1] == nil))

  defp evidence?("mrn_reuse", a, b),
    do:
      is_binary(a["mrn"]) and a["mrn"] != "" and a["mrn"] == b["mrn"] and
        a["source"] == b["source"]

  defp evidence?("common_name_dob", a, b),
    do:
      a["given_name"] == "MARIA" and a["family_name"] == "GARCIA" and a["dob"] == "1980-01-01" and
        Map.take(a, ~w(given_name family_name dob)) == Map.take(b, ~w(given_name family_name dob))

  defp evidence?("twins", a, b),
    do:
      is_binary(a["given_name"]) and is_binary(b["given_name"]) and is_binary(a["dob"]) and
        a["dob"] == b["dob"] and a["family_name"] == b["family_name"]

  defp evidence?("newborns", a, b),
    do:
      a["given_name"] == "BABY GIRL" and is_binary(a["dob"]) and
        String.starts_with?(a["dob"], "2026-09-") and a["dob"] == b["dob"] and a["ssn"] == nil and
        b["ssn"] == nil

  defp evidence?("evaluation_only_alias", a, b),
    do: {a["given_name"], b["given_name"]} in aliases()

  defp evidence?(_, _, _), do: false

  @doc "Separate same/different-person denominators, including per-variant support."
  def coverage(cases) do
    cases
    |> Enum.group_by(& &1["category"])
    |> Map.new(fn {family, rows} ->
      {family,
       %{
         same_person: Enum.count(rows, & &1["same_person"]),
         different_person: Enum.count(rows, &(not &1["same_person"])),
         variants: Enum.frequencies_by(rows, & &1["variant"])
       }}
    end)
  end

  @doc "Scores cases with a supplied model; reports quality without enforcing targets."
  def evaluate(cases, model) do
    scored =
      Enum.map(cases, fn c ->
        result =
          PatientMatching.link([Dataset.record(c["left"])], [Dataset.record(c["right"])], model,
            review_threshold: 0.0
          )

        outcome =
          case result.matches ++ result.review do
            [] ->
              "unblocked"

            [pair] ->
              cond do
                pair.probability >= model.config.match_threshold -> "match"
                pair.probability > model.config.review_threshold -> "review"
                true -> "non_match"
              end
          end

        pair_pass =
          if(c["same_person"], do: outcome in ["match", "review"], else: outcome != "match")

        information_review =
          result.record_review != [] and outcome in ["unblocked", "non_match"]

        Map.merge(c, %{
          "outcome" => outcome,
          "record_review" => result.record_review,
          "information_status" =>
            if(result.record_review == [], do: "available", else: "insufficient_identity"),
          "pass" => pair_pass,
          "handling_pass" => pair_pass or information_review
        })
        |> Map.drop(~w(left right))
      end)

    groups =
      scored
      |> Enum.group_by(&{&1["category"], &1["variant"]})
      |> Map.new(fn {{family, variant}, rows} ->
        same = Enum.filter(rows, & &1["same_person"])
        different = Enum.reject(rows, & &1["same_person"])

        {"#{family}/#{variant}",
         %{
           true_pairs: length(same),
           different_person_pairs: length(different),
           support: "low-support",
           auto_matches: Enum.count(same, &(&1["outcome"] == "match")),
           found_with_review: Enum.count(same, &(&1["outcome"] in ["match", "review"])),
           information_review_cases:
             Enum.count(rows, &(&1["information_status"] == "insufficient_identity")),
           informationless_true_pairs:
             Enum.count(same, &(&1["information_status"] == "insufficient_identity")),
           pair_expectation_failures: Enum.count(rows, &(not &1["pass"])),
           handling_failures: Enum.count(rows, &(not &1["handling_pass"])),
           false_matches: Enum.count(different, &(&1["outcome"] == "match")),
           outcomes: Enum.frequencies_by(rows, & &1["outcome"])
         }}
      end)

    %{
      groups: groups,
      cases: scored,
      summary: %{
        cases: length(scored),
        pair_expectation_failures: Enum.count(scored, &(not &1["pass"])),
        handling_failures: Enum.count(scored, &(not &1["handling_pass"])),
        information_review_cases:
          Enum.count(scored, &(&1["information_status"] == "insufficient_identity"))
      }
    }
  end
end
