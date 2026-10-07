defmodule PatientMatching.Linker do
  @moduledoc false
  alias PatientMatching.{Blocking, Config, Scorer}

  @doc "Links two files, or deduplicates their union when requested, using model blocking and thresholds."
  def link(left, right, model, opts \\ []) do
    type = Keyword.get(opts, :link_type, :link_only)

    case type do
      :link_only -> score({Blocking.prepare(left), Blocking.prepare(right)}, type, model, opts)
      :dedupe_only -> score(Blocking.prepare(left ++ right), type, model, opts)
      _ -> raise ArgumentError, "invalid link_type"
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

    result =
      pairs
      |> Task.async_stream(
        fn {a, b} ->
          scored = Scorer.score(Map.fetch!(left, a), Map.fetch!(right, b), model)

          pair = %{
            left_id: a,
            right_id: b,
            probability: scored.probability,
            weight: scored.weight,
            reason: scored.reason
          }

          {classify(scored.probability, match_threshold, review_threshold), pair}
        end,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.reduce(
        %{matches: [], review: [], non_match_count: 0, dropped_blocks: blocked.dropped_blocks},
        fn
          {:ok, {:match, pair}}, result ->
            %{result | matches: [pair | result.matches]}

          {:ok, {:review, pair}}, result ->
            %{result | review: [pair | result.review]}

          {:ok, {:non_match, _}}, result ->
            %{result | non_match_count: result.non_match_count + 1}
        end
      )

    %{result | matches: Enum.reverse(result.matches), review: Enum.reverse(result.review)}
  end

  @doc "Classifies probabilities with inclusive match and non-match boundaries."
  def classify(p, match, _review) when p >= match, do: :match
  def classify(p, _match, review) when p <= review, do: :non_match
  def classify(_, _, _), do: :review
end
