defmodule PatientMatching.Linker do
  @moduledoc false
  alias PatientMatching.{Blocking, Config, Scorer}
  @parallel_min 2_000

  @doc "Links two files, or deduplicates their union when requested, using model blocking and thresholds."
  def link(left, right, model, opts \\ []) do
    type = Keyword.get(opts, :link_type, :link_only)

    placeholders = model.config.placeholders

    case type do
      :link_only ->
        score(
          {Blocking.prepare(left, placeholders), Blocking.prepare(right, placeholders)},
          type,
          model,
          opts
        )

      :dedupe_only ->
        score(Blocking.prepare(left ++ right, placeholders), type, model, opts)

      _ ->
        raise ArgumentError, "invalid link_type"
    end
  end

  @doc "Scores blocked normalized candidates and MRN agreements, counting non-matches instead of retaining them."
  def score(records, type, model, opts) do
    match_threshold = Keyword.get(opts, :match_threshold, model.config.match_threshold)
    review_threshold = Keyword.get(opts, :review_threshold, model.config.review_threshold)
    Config.thresholds!(match_threshold, review_threshold)

    blocked =
      Blocking.candidates_prepared(records, model.config.blocking, type,
        max_block_size: model.config.max_block_size
      )

    pairs =
      (blocked.pairs ++ Blocking.mrn_pairs(records, type)) |> Enum.uniq() |> Blocking.sort_pairs()

    {left, right} =
      case type do
        :link_only -> records
        :dedupe_only -> {records, records}
      end

    left = Map.new(left, &{&1.id, &1})
    right = Map.new(right, &{&1.id, &1})

    pairs
    |> score_pairs(left, right, model)
    |> Enum.reduce(
      %{matches: [], review: [], non_match_count: 0, dropped_blocks: blocked.dropped_blocks},
      fn pair, result ->
        case classify(pair.probability, match_threshold, review_threshold) do
          :match -> %{result | matches: [pair | result.matches]}
          :review -> %{result | review: [pair | result.review]}
          :non_match -> %{result | non_match_count: result.non_match_count + 1}
        end
      end
    )
    |> then(&%{&1 | matches: Enum.reverse(&1.matches), review: Enum.reverse(&1.review)})
  end

  # Each chunk carries only the records its pairs reference, so a worker copies
  # O(chunk) data instead of the whole file.
  defp score_pairs(pairs, left, right, model) when length(pairs) < @parallel_min,
    do: Enum.map(pairs, &score_pair(&1, left, right, model))

  defp score_pairs(pairs, left, right, model) do
    workers = System.schedulers_online()
    size = max(div(length(pairs), workers * 4), 1)

    pairs
    |> Enum.chunk_every(size)
    |> Enum.map(fn chunk ->
      {chunk, Map.take(left, Enum.map(chunk, &elem(&1, 0))),
       Map.take(right, Enum.map(chunk, &elem(&1, 1)))}
    end)
    |> Task.async_stream(
      fn {chunk, l, r} -> Enum.map(chunk, &score_pair(&1, l, r, model)) end,
      max_concurrency: workers,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, scored} -> scored end)
  end

  defp score_pair({a, b}, left, right, model) do
    scored = Scorer.score(Map.fetch!(left, a), Map.fetch!(right, b), model)

    %{
      left_id: a,
      right_id: b,
      probability: scored.probability,
      weight: scored.weight,
      reason: scored.reason
    }
  end

  @doc "Classifies probabilities with inclusive match and non-match boundaries."
  def classify(p, match, _review) when p >= match, do: :match
  def classify(p, _match, review) when p <= review, do: :non_match
  def classify(_, _, _), do: :review
end
