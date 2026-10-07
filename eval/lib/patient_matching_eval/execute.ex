defmodule PatientMatchingEval.Execute do
  @moduledoc """
  Runs one suite entry the way a caller would: train on the run's own input
  with the patient MPI preset, then `dedupe/3` or `link/4`.

  `review_threshold: 0.0` is passed so every scored candidate comes back with
  its probability; decisions are re-derived at the model's real thresholds,
  which also allows threshold sweeps. Blocking candidates are recomputed through
  `PatientMatching.Blocking` (an internal module) only to measure blocking recall.
  """
  alias PatientMatching.{Blocking, Presets}
  alias PatientMatchingEval.Dataset

  @doc "Executes a run spec and returns raw outputs for `Metrics`."
  def run(%{"kind" => "dedupe"} = spec, dataset) do
    records = Dataset.from_sources(dataset, spec["sources"])
    config = Presets.patient_mpi()

    {train_ms, model} =
      timed(fn ->
        PatientMatching.train(records, config, train_opts(spec, dataset, records, config))
      end)

    {score_ms, result} =
      timed(fn -> PatientMatching.dedupe(records, model, review_threshold: 0.0) end)

    %{
      spec: spec,
      kind: :dedupe,
      records: records,
      model: model,
      result: result,
      scored: result.matches ++ result.review,
      candidates: candidates(records, :dedupe_only, config),
      truth: Dataset.true_pairs_dedupe(dataset, records),
      timings: %{train_ms: train_ms, score_ms: score_ms}
    }
  end

  def run(%{"kind" => "link"} = spec, dataset) do
    left = Dataset.from_sources(dataset, spec["left"])
    right = Dataset.from_sources(dataset, spec["right"])
    config = Presets.patient_mpi()
    train_input = left ++ right

    {train_ms, model} =
      timed(fn ->
        PatientMatching.train(train_input, config, train_opts(spec, dataset, train_input, config))
      end)

    {score_ms, result} =
      timed(fn -> PatientMatching.link(left, right, model, review_threshold: 0.0) end)

    %{
      spec: spec,
      kind: :link,
      records: train_input,
      left: left,
      right: right,
      model: model,
      result: result,
      scored: result.matches ++ result.review,
      candidates: candidates({left, right}, :link_only, config),
      truth: Dataset.true_pairs_link(dataset, left, right),
      timings: %{train_ms: train_ms, score_ms: score_ms}
    }
  end

  defp candidates(input, type, config) do
    blocked =
      Blocking.candidates(input, config.blocking, type,
        max_block_size: config.max_block_size,
        placeholders: config.placeholders
      )

    prepared =
      case input do
        {l, r} ->
          {Blocking.prepare(l, config.placeholders), Blocking.prepare(r, config.placeholders)}

        records ->
          Blocking.prepare(records, config.placeholders)
      end

    kind = if type == :dedupe_only, do: :dedupe, else: :link

    (blocked.pairs ++ Blocking.mrn_pairs(prepared, type))
    |> MapSet.new(&Dataset.key(kind, &1))
  end

  defp train_opts(%{"train" => %{"lambda" => "oracle_" <> which}}, dataset, records, config) do
    rules = if which == "training", do: config.training_blocking, else: config.blocking

    pairs =
      Blocking.candidates(records, rules, :dedupe_only, max_block_size: config.max_block_size).pairs

    truth = Dataset.true_pairs_dedupe(dataset, records)
    hits = Enum.count(pairs, &MapSet.member?(truth, Dataset.key(:dedupe, &1)))
    [lambda: max(hits / max(length(pairs), 1), 1.0e-6)]
  end

  defp train_opts(%{"train" => %{"lambda" => value}}, _, _, _) when is_number(value),
    do: [lambda: value]

  defp train_opts(_, _, _, _), do: []

  defp timed(fun) do
    {us, value} = :timer.tc(fun)
    {div(us, 1000), value}
  end
end
