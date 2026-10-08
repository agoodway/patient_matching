defmodule PatientMatching.Scorer do
  @moduledoc false
  alias PatientMatching.{Comparison, Guards}
  @floor 1.0e-6

  @doc """
  Scores normalized records in log space. A same-source MRN agreement scores
  probability 1 (reason `:mrn`) unless a guard fires. When guards fire, the
  weight loses the guards' penalties and the probability is capped just below
  the match threshold (`:match_threshold` option, else the config's); an MRN
  pair is then scored statistically with reason `:mrn_conflict`.
  """
  def score(left, right, model, opts \\ []) do
    mrn = mrn?(left, right)
    fired = Guards.fired_for_model(model, left.normalized, right.normalized)

    if mrn and fired == [] and not Keyword.get(opts, :explain, false) do
      %{probability: 1.0, weight: 50.0, levels: [], tf_adjustments: [], reason: :mrn, guards: []}
    else
      threshold = Keyword.get(opts, :match_threshold, model.config.match_threshold)
      statistical_score(left, right, model, mrn, fired, threshold)
    end
  end

  defp statistical_score(left, right, model, mrn, fired, threshold) do
    {levels, adjustments} =
      Enum.map_reduce(model.comparisons, [], fn comparison, adjustments ->
        level = Comparison.run(comparison, left, right)
        {evidence, tf} = comparison_evidence(level, comparison, {left, right}, model)
        {evidence, tf ++ adjustments}
      end)

    weight =
      log2(model.lambda / (1 - model.lambda)) + Enum.sum(Enum.map(levels, & &1.weight)) +
        Enum.sum(Enum.map(adjustments, & &1.adjustment))

    {probability, weight, reason} =
      cond do
        fired != [] ->
          weight = weight - Enum.sum(Enum.map(fired, &elem(&1, 1)))
          cap = threshold * (1 - 1.0e-9)
          {min(probability(weight), cap), weight, if(mrn, do: :mrn_conflict, else: :scored)}

        mrn ->
          {1.0, 50.0, :mrn}

        true ->
          {probability(weight), weight, :scored}
      end

    %{
      probability: probability,
      weight: weight,
      levels: levels,
      tf_adjustments: Enum.reverse(adjustments),
      reason: reason,
      guards: Enum.map(fired, &elem(&1, 0))
    }
  end

  defp comparison_evidence(%{null_level?: true} = level, comparison, _records, _model) do
    {%{field: comparison.field, level: level.name, m: nil, u: nil, weight: 0.0}, []}
  end

  defp comparison_evidence(level, comparison, {left, right}, model) do
    %{m: m, u: u} = model.parameters[comparison.field][level.name]
    a = Map.get(left.normalized, comparison.field)
    b = Map.get(right.normalized, comparison.field)
    tf = if level.tf? and a == b, do: [tf_adjustment(comparison.field, a, u, model)], else: []
    {%{field: comparison.field, level: level.name, m: m, u: u, weight: log2(m / u)}, tf}
  end

  # A value never seen in training is treated as appearing once in it, not as
  # vanishingly rare: an unseen name is weak evidence that it is unusual.
  defp tf_adjustment(field, value, u, model) do
    unseen = 1 / max(Map.get(model.trained, :tf_records, 1 / @floor), 1)
    tf = model.term_frequencies |> Map.get(field, %{}) |> Map.get(value, unseen)
    %{field: field, value: value, adjustment: log2(u / max(tf, @floor))}
  end

  @doc "Checks non-nil normalized source and MRN equality."
  def mrn?(left, right) do
    a = left.normalized
    b = right.normalized
    a[:source] != nil and a[:mrn] != nil and a[:source] == b[:source] and a[:mrn] == b[:mrn]
  end

  @doc "Returns the base-two logarithm of a positive value."
  def log2(x), do: :math.log(x) / :math.log(2)

  @doc "Converts a base-two log-odds weight to probability without exponential overflow."
  def probability(weight) when weight >= 0, do: 1 / (1 + :math.exp(-weight * :math.log(2)))

  def probability(weight) do
    odds = :math.exp(weight * :math.log(2))
    odds / (1 + odds)
  end
end
