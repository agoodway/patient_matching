defmodule PatientMatchingEval.Golden do
  @moduledoc """
  Hand-written scenario cases in `eval/scenarios/*.json`, scored with a model
  trained on the synthetic population (so term frequencies and m/u reflect the
  metro, not the two records in the case).

  A file holds `{"category": ..., "cases": [...]}`. A pair case has `left`,
  `right` and `expect`; a cluster case has `records` and `expect_clusters`
  (groups of ids that should end up together; everything else stays apart).

  Expectations for pairs:

    * `match`            – must auto-match
    * `match_or_review`  – must be found (auto-match or review)
    * `review`           – ambiguous; a human should decide
    * `not_match`        – must not auto-match (review is acceptable)
    * `non_match`        – must not be matched or reviewed

  `risk` is `overlay` (a wrong merge: clinically dangerous) or `duplicate`
  (a missed link: a split chart).
  """

  @doc "Loads every case, tagging each with its file's category."
  def load(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      file = path |> File.read!() |> Jason.decode!()
      Enum.map(file["cases"], &Map.put(&1, "category", file["category"]))
    end)
  end

  @doc "Evaluates all cases against a trained model."
  def evaluate(cases, model) do
    Enum.map(cases, fn c ->
      if c["records"], do: cluster_case(c, model), else: pair_case(c, model)
    end)
  end

  defp pair_case(c, model) do
    left = record(c["left"])
    right = record(c["right"])
    result = PatientMatching.link([left], [right], model, review_threshold: 0.0)
    explanation = PatientMatching.explain(left, right, model)

    outcome =
      case result.matches ++ result.review do
        [] -> "unblocked"
        [pair] -> decision(pair.probability, model)
      end

    %{
      id: c["id"],
      category: c["category"],
      title: c["title"],
      risk: c["risk"],
      expect: c["expect"],
      outcome: outcome,
      probability: explanation.probability,
      levels: Enum.map(explanation.levels, &{&1.field, &1.level, Float.round(&1.weight, 2)}),
      pass: pass?(c["expect"], outcome)
    }
  end

  defp cluster_case(c, model) do
    records = Enum.map(c["records"], &record/1)
    result = PatientMatching.dedupe(records, model)
    expected = c["expect_clusters"] |> Enum.map(&Enum.sort/1) |> Enum.sort()
    actual = result.clusters |> Enum.map(&Enum.sort(&1.member_ids)) |> Enum.sort()

    %{
      id: c["id"],
      category: c["category"],
      title: c["title"],
      risk: c["risk"],
      expect: "clusters #{inspect(expected)}",
      outcome: "clusters #{inspect(actual)}",
      probability: nil,
      levels: [],
      pass: actual == expected
    }
  end

  defp decision(p, model) do
    cond do
      p >= model.config.match_threshold -> "match"
      p > model.config.review_threshold -> "review"
      true -> "non_match"
    end
  end

  defp pass?("match", outcome), do: outcome == "match"
  defp pass?("match_or_review", outcome), do: outcome in ["match", "review"]
  defp pass?("review", outcome), do: outcome == "review"
  defp pass?("not_match", outcome), do: outcome != "match"
  defp pass?("non_match", outcome), do: outcome in ["non_match", "unblocked"]

  @fields Map.new(
            ~w(id source mrn given_name family_name dob sex zip phone ssn street)a,
            &{Atom.to_string(&1), &1}
          )
  defp record(map),
    do: map |> Map.take(Map.keys(@fields)) |> Map.new(fn {k, v} -> {@fields[k], v} end)
end
