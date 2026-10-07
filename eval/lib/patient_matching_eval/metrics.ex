defmodule PatientMatchingEval.Metrics do
  @moduledoc """
  Scores a run against ground truth. Everything is pairwise over record ids:

    * blocking: how many true pairs ever became candidates
    * decisions at the model's thresholds: auto-match precision/recall, review load
    * missed true pairs by stage (unblocked / scored non-match / sent to review)
    * false matches by real-world relationship (twins, juniors, spouses, borrowed SSN, …)
    * recall by data-quality tag and by demographic slice
    * threshold sweep, and for dedupe the clusters (overlays, chaining, B-cubed)
  """
  alias PatientMatchingEval.Dataset

  @sweep [0.5, 0.8, 0.9, 0.95, 0.99, 0.999]
  @placeholder_tags ~w(unknown_patient dob_placeholder ssn_placeholder phone_placeholder newborn_placeholder)

  @doc "Computes the metrics map for one executed run."
  def compute(raw, dataset) do
    %{model: model, truth: truth, kind: kind} = raw
    match_t = model.config.match_threshold
    review_t = model.config.review_threshold
    scored = Map.new(raw.scored, &{Dataset.key(kind, {&1.left_id, &1.right_id}), &1})
    matches = for {k, p} <- scored, p.probability >= match_t, into: MapSet.new(), do: k

    review =
      for {k, p} <- scored,
          p.probability > review_t and p.probability < match_t,
          into: MapSet.new(),
          do: k

    found = MapSet.union(matches, review)
    tp = MapSet.intersection(matches, truth)
    false_matches = MapSet.difference(matches, truth)
    blocked_true = MapSet.intersection(raw.candidates, truth)

    %{
      name: raw.spec["name"],
      kind: kind,
      description: raw.spec["description"],
      diagnostic: raw.spec["diagnostic"] == true,
      records: length(raw.records),
      true_pairs: MapSet.size(truth),
      candidates: MapSet.size(raw.candidates),
      dropped_blocks: raw.result.dropped_blocks,
      blocking_recall: ratio(MapSet.size(blocked_true), MapSet.size(truth)),
      matches: MapSet.size(matches),
      review: MapSet.size(review),
      review_true: MapSet.size(MapSet.intersection(review, truth)),
      precision: ratio(MapSet.size(tp), MapSet.size(matches)),
      recall: ratio(MapSet.size(tp), MapSet.size(truth)),
      recall_with_review:
        ratio(MapSet.size(MapSet.intersection(found, truth)), MapSet.size(truth)),
      f1:
        f1(
          ratio(MapSet.size(tp), MapSet.size(matches)),
          ratio(MapSet.size(tp), MapSet.size(truth))
        ),
      missed_by_stage: missed_by_stage(truth, raw.candidates, matches, review),
      false_matches: MapSet.size(false_matches),
      false_match_causes: false_match_causes(false_matches, dataset),
      false_match_examples: examples(false_matches, scored, raw, dataset, 5),
      missed_examples: examples(MapSet.difference(truth, found), scored, raw, dataset, 5),
      tags: tag_recall(truth, raw.candidates, matches, found, dataset),
      false_match_tags: false_match_tags(false_matches, dataset),
      slices: slices(truth, matches, found, false_matches, raw.records, dataset),
      sweep: sweep(scored, truth),
      clusters: clusters(raw, dataset),
      assignment: assignment(raw, truth),
      model: model_summary(model),
      timings: raw.timings
    }
  end

  defp missed_by_stage(truth, candidates, matches, review) do
    Enum.reduce(truth, %{unblocked: 0, scored_non_match: 0, review: 0}, fn pair, acc ->
      cond do
        MapSet.member?(matches, pair) -> acc
        MapSet.member?(review, pair) -> Map.update!(acc, :review, &(&1 + 1))
        MapSet.member?(candidates, pair) -> Map.update!(acc, :scored_non_match, &(&1 + 1))
        true -> Map.update!(acc, :unblocked, &(&1 + 1))
      end
    end)
  end

  # ------------------------------------------------------------ false matches

  @doc "Classifies a falsely matched pair by the real-world relationship of the two people, then by data cause."
  def cause(dataset, {a, b}) do
    ta = dataset.truth[a]
    tb = dataset.truth[b]
    pa = dataset.people[ta["person_id"]]
    pb = dataset.people[tb["person_id"]]
    tags = ta["tags"] ++ tb["tags"]
    ids = {pa["person_id"], pb["person_id"]}

    cond do
      related?(pa, pb, "twin") ->
        "twins"

      related?(pa, pb, "junior_of") ->
        "junior_senior"

      related?(pa, pb, "spouse") ->
        "spouses"

      related?(pa, pb, "mother") or related?(pa, pb, "father") ->
        "parent_child"

      siblings?(pa, pb) ->
        "siblings"

      pa["household"] == pb["household"] ->
        "same_household_other"

      pa["ssn_lender"] in Tuple.to_list(ids) or pb["ssn_lender"] in Tuple.to_list(ids) ->
        "borrowed_ssn"

      Enum.any?(tags, &(&1 in @placeholder_tags)) ->
        "placeholder_values"

      "ssn_guarantor" in tags ->
        "guarantor_ssn"

      "jan1_dob" in tags or "dob_estimated_jan1" in tags ->
        "jan1_birthdays"

      true ->
        "unrelated_lookalikes"
    end
  end

  defp related?(pa, pb, key), do: pa[key] == pb["person_id"] or pb[key] == pa["person_id"]

  defp siblings?(pa, pb) do
    (pa["mother"] != nil and pa["mother"] == pb["mother"]) or
      (pa["father"] != nil and pa["father"] == pb["father"])
  end

  defp false_match_causes(pairs, dataset),
    do: pairs |> Enum.map(&cause(dataset, &1)) |> Enum.frequencies()

  defp false_match_tags(pairs, dataset) do
    pairs
    |> Enum.flat_map(fn {a, b} ->
      Enum.uniq(dataset.truth[a]["tags"] ++ dataset.truth[b]["tags"])
    end)
    |> Enum.frequencies()
  end

  defp examples(pairs, scored, raw, dataset, n) do
    index = Map.new(raw.records, &{&1.id, &1})

    pairs
    |> Enum.sort()
    |> Enum.take_every(max(div(MapSet.size(pairs), n), 1))
    |> Enum.take(n)
    |> Enum.map(fn {a, b} = pair ->
      %{
        left: index[a],
        right: index[b],
        probability: probability(scored[pair], index[a], index[b], raw.model),
        stage: if(scored[pair], do: "scored", else: "unblocked"),
        cause:
          if(dataset.truth[a]["person_id"] != dataset.truth[b]["person_id"],
            do: cause(dataset, pair)
          ),
        tags: Enum.uniq(dataset.truth[a]["tags"] ++ dataset.truth[b]["tags"])
      }
    end)
  end

  # Unblocked pairs were never scored; show what the model would have said.
  defp probability(nil, left, right, model),
    do: PatientMatching.explain(left, right, model).probability

  defp probability(pair, _, _, _), do: pair.probability

  # ---------------------------------------------------------------- slices

  defp tag_recall(truth, candidates, matches, found, dataset) do
    truth
    |> Enum.flat_map(fn {a, b} = pair ->
      tags = Enum.uniq(dataset.truth[a]["tags"] ++ dataset.truth[b]["tags"])
      Enum.map(tags, &{&1, pair})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {tag, pairs} -> {tag, rates(pairs, candidates, matches, found)} end)
  end

  defp rates(pairs, candidates, matches, found) do
    n = length(pairs)

    %{
      pairs: n,
      blocked: ratio(Enum.count(pairs, &MapSet.member?(candidates, &1)), n),
      recall: ratio(Enum.count(pairs, &MapSet.member?(matches, &1)), n),
      recall_with_review: ratio(Enum.count(pairs, &MapSet.member?(found, &1)), n)
    }
  end

  defp slices(truth, matches, found, false_matches, records, dataset) do
    dims = %{
      "group" => fn t, _p -> t["group"] end,
      "origin" => fn t, _p -> t["origin"] end,
      "foreign_born" => fn t, _p -> to_string(t["foreign_born"]) end,
      "age_band" => fn _t, p -> age_band(p["dob"]) end
    }

    Map.new(dims, fn {dim, f} ->
      value = fn id -> f.(dataset.truth[id], dataset.people[dataset.truth[id]["person_id"]]) end
      by_true = Enum.group_by(truth, fn {a, _} -> value.(a) end)
      record_counts = Enum.frequencies_by(records, &value.(&1.id))

      fm =
        false_matches
        |> Enum.flat_map(fn {a, b} -> Enum.uniq([value.(a), value.(b)]) end)
        |> Enum.frequencies()

      rows =
        for {v, count} <- record_counts, into: %{} do
          pairs = Map.get(by_true, v, [])

          {v,
           Map.merge(rates(pairs, MapSet.new(), matches, found) |> Map.delete(:blocked), %{
             records: count,
             false_matches_per_1k_records:
               Float.round(1000 * Map.get(fm, v, 0) / max(count, 1), 2)
           })}
        end

      {dim, rows}
    end)
  end

  defp age_band(dob) do
    age = Date.diff(PatientMatchingEval.Population.today(), Date.from_iso8601!(dob)) / 365.25

    cond do
      age < 1 -> "infant"
      age < 18 -> "child"
      age < 65 -> "adult"
      true -> "senior"
    end
  end

  defp sweep(scored, truth) do
    probabilities = Enum.map(scored, fn {k, p} -> {k, p.probability} end)

    for t <- @sweep do
      predicted = for {k, p} <- probabilities, p >= t, do: k
      tp = Enum.count(predicted, &MapSet.member?(truth, &1))

      %{
        threshold: t,
        matches: length(predicted),
        precision: ratio(tp, length(predicted)),
        recall: ratio(tp, MapSet.size(truth))
      }
    end
  end

  # -------------------------------------------------------------- clusters

  defp clusters(%{kind: :dedupe, result: result, records: records}, dataset) do
    clustered = Map.new(for c <- result.clusters, id <- c.member_ids, do: {id, c.root_id})
    entity = fn id -> Map.get(clustered, id, {:singleton, id}) end
    by_cluster = Enum.group_by(records, &entity.(&1.id), &Dataset.person(dataset, &1.id))
    by_person = Enum.group_by(records, &Dataset.person(dataset, &1.id), &entity.(&1.id))

    # B-cubed: per record, overlap of its predicted cluster and its true person.
    {p_sum, r_sum} =
      Enum.reduce(records, {0.0, 0.0}, fn r, {ps, rs} ->
        persons = by_cluster[entity.(r.id)]
        entities = by_person[Dataset.person(dataset, r.id)]
        me = Dataset.person(dataset, r.id)
        mine = entity.(r.id)

        {ps + Enum.count(persons, &(&1 == me)) / length(persons),
         rs + Enum.count(entities, &(&1 == mine)) / length(entities)}
      end)

    n = max(length(records), 1)
    overlays = Enum.filter(by_cluster, fn {_, persons} -> length(Enum.uniq(persons)) > 1 end)

    %{
      clusters: length(result.clusters),
      largest: result.clusters |> Enum.map(&length(&1.member_ids)) |> Enum.max(fn -> 0 end),
      overlay_clusters: length(overlays),
      records_in_overlays: overlays |> Enum.map(fn {_, p} -> length(p) end) |> Enum.sum(),
      people_merged_into_overlays:
        overlays |> Enum.map(fn {_, p} -> length(Enum.uniq(p)) end) |> Enum.sum(),
      bcubed_precision: p_sum / n,
      bcubed_recall: r_sum / n
    }
  end

  defp clusters(_, _), do: nil

  defp assignment(%{kind: :link, result: result}, truth) do
    assigned = PatientMatching.assign(result.matches)
    tp = Enum.count(assigned, &MapSet.member?(truth, {&1.left_id, &1.right_id}))

    %{
      pairs: length(assigned),
      precision: ratio(tp, length(assigned)),
      recall: ratio(tp, MapSet.size(truth))
    }
  end

  defp assignment(_, _), do: nil

  defp model_summary(model) do
    weights =
      for {field, levels} <- model.parameters, into: %{} do
        {field,
         Map.new(levels, fn {level, %{m: m, u: u}} ->
           {level, %{m: m, u: u, weight: :math.log2(m / u)}}
         end)}
      end

    %{lambda: model.lambda, trained: model.trained, weights: weights}
  end

  defp ratio(_, 0), do: nil
  defp ratio(a, b), do: a / b

  defp f1(nil, _), do: nil
  defp f1(_, nil), do: nil
  defp f1(p, r) when p + r == 0, do: 0.0
  defp f1(p, r), do: 2 * p * r / (p + r)
end
