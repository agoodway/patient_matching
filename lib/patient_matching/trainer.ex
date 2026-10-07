defmodule PatientMatching.Trainer do
  @moduledoc false
  alias PatientMatching.{Blocking, Comparison, Config, Model, Scorer}
  @floor 1.0e-6

  @doc "Estimates a model from one file using a fixed or deterministic prior, random-pair u and pattern-count EM."
  def train(records, config, opts \\ []) do
    config = Config.validate!(config)
    records = Blocking.prepare(records)
    n = length(records)
    if n < 2, do: raise(ArgumentError, "training requires at least 2 records, got #{n}")

    if config.comparisons == [],
      do: raise(ArgumentError, "training requires comparisons, got 0 for #{n} records")

    prediction =
      Blocking.candidates_prepared(records, config.blocking, :dedupe_only,
        max_block_size: config.max_block_size
      )

    training =
      Blocking.candidates_prepared(records, config.training_blocking, :dedupe_only,
        max_block_size: config.max_block_size
      )

    if prediction.pairs == [],
      do: raise(ArgumentError, "0 prediction candidate pairs for #{n} records")

    if training.pairs == [],
      do: raise(ArgumentError, "0 training candidate pairs for #{n} records")

    {lambda, source} =
      if Keyword.has_key?(opts, :lambda) do
        {clamp_lambda(Keyword.fetch!(opts, :lambda)), :fixed}
      else
        {estimate_lambda_prepared(records, config, length(prediction.pairs)), :deterministic}
      end

    u = estimate_u_prepared(records, config)
    m = initial_m(config, Keyword.get(opts, :m_init, %{}))

    parameters =
      Map.new(m, fn {field, levels} ->
        {field, Map.new(levels, fn {name, m} -> {name, %{m: m, u: u[field][name]}} end)}
      end)

    model = %Model{
      lambda: lambda,
      config: config,
      comparisons: config.comparisons,
      parameters: parameters,
      term_frequencies: term_frequencies_prepared(records, config),
      trained: %{lambda_source: source, unstable: false, em_iters: 0}
    }

    estimate_m(pattern_counts_prepared(records, training.pairs, config), model, config)
  end

  @doc "Rough prior from deterministic agreements divided by prediction candidate count and recall; not a likelihood. Single-file training uses within-file pairs, even for a link_only config."
  def estimate_lambda(records, config) do
    records = Blocking.prepare(records)

    budget =
      Blocking.candidates_prepared(records, config.blocking, :dedupe_only,
        max_block_size: config.max_block_size
      ).pairs
      |> length()

    estimate_lambda_prepared(records, config, budget)
  end

  defp estimate_lambda_prepared(records, config, budget) do
    count =
      Blocking.candidates_prepared(
        records,
        [[:family_name, :given_name, :dob], [:ssn]],
        :dedupe_only,
        max_block_size: :infinity
      ).pairs
      |> length()

    clamp_lambda(count / max(budget, 1) / config.lambda_recall)
  end

  defp clamp_lambda(value) when is_number(value), do: min(0.5, max(@floor, value * 1.0))
  defp clamp_lambda(_), do: raise(ArgumentError, "lambda must be numeric")

  @doc "Uniform unordered pairs without replacement; a local RNG leaves caller state untouched."
  def sample_pairs(records, config),
    do: records |> Blocking.prepare() |> sample_pairs_prepared(config)

  defp sample_pairs_prepared(records, config) do
    records = records |> Enum.sort_by(&Blocking.sort_key(&1.id)) |> List.to_tuple()

    n = tuple_size(records)
    total = div(n * (n - 1), 2)
    count = min(config.u_sample_size, total)

    ranks =
      if count == total do
        if total == 0, do: [], else: Enum.to_list(0..(total - 1))
      else
        state = :rand.seed_s(:exsss, {config.seed + 1, config.seed + 2, config.seed + 3})

        {ranks, _state} =
          Enum.reduce((total - count)..(total - 1), {MapSet.new(), state}, &sample_rank/2)

        ranks |> MapSet.to_list() |> Enum.sort()
      end

    Enum.map(ranks, fn rank ->
      i = row(rank, n, 0, n - 2)
      offset = div(i * (2 * n - i - 1), 2)
      j = i + 1 + rank - offset
      {elem(records, i).id, elem(records, j).id}
    end)
  end

  @doc "Estimates non-null level frequencies from unblocked random pairs and floors each field distribution."
  def estimate_u(records, config),
    do: records |> Blocking.prepare() |> estimate_u_prepared(config)

  defp estimate_u_prepared(records, config) do
    index = Map.new(records, &{&1.id, &1})
    pairs = sample_pairs_prepared(records, config)

    counts =
      Map.new(config.comparisons, fn comparison ->
        {comparison.field, Map.new(non_null(comparison), &{&1.name, 0})}
      end)

    counts =
      Enum.reduce(pairs, counts, fn {a, b}, counts ->
        count_levels(config.comparisons, index[a], index[b], counts)
      end)

    Map.new(counts, fn {field, counts} -> {field, distribution(counts)} end)
  end

  @doc "TF uses the whole training file as N; nil values do not receive a count."
  def term_frequencies(records, config),
    do: records |> Blocking.prepare() |> term_frequencies_prepared(config)

  defp term_frequencies_prepared(records, config) do
    n = length(records)

    config.comparisons
    |> Enum.filter(fn c -> Enum.any?(c.levels, & &1.tf?) end)
    |> Map.new(fn comparison ->
      frequencies =
        records
        |> Enum.map(&Map.get(&1.normalized, comparison.field))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      {comparison.field,
       Map.new(frequencies, fn {value, count} -> {value, count / max(n, 1)} end)}
    end)
  end

  @doc "Aggregate ordered comparison-level tuples before running EM."
  def pattern_counts(records, pairs, config),
    do: records |> Blocking.prepare() |> pattern_counts_prepared(pairs, config)

  defp pattern_counts_prepared(records, pairs, config) do
    index = Map.new(records, &{&1.id, &1})

    Enum.reduce(pairs, %{}, fn {a, b}, counts ->
      pattern =
        config.comparisons
        |> Enum.map(&Comparison.run(&1, index[a], index[b]).name)
        |> List.to_tuple()

      Map.update(counts, pattern, 1, &(&1 + 1))
    end)
  end

  @doc "Initial masses follow the brief. If agreement masses exceed one, normalize them with a floored else remainder. Unknown custom levels start at 0.5."
  def initial_m(config, overrides \\ %{}) do
    Map.new(config.comparisons, fn comparison ->
      levels = non_null(comparison)

      agreements =
        levels |> Enum.reject(&(&1.name == :else)) |> Map.new(&{&1.name, initial_mass(&1)})

      defaults = Map.put(agreements, :else, max(1 - Enum.sum(Map.values(agreements)), @floor))
      supplied = Map.get(overrides, comparison.field, %{})

      validate_initial_m!(supplied, defaults)

      {comparison.field, distribution(Map.merge(defaults, supplied))}
    end)
  end

  @doc "EM estimates m alone from pattern counts. Nulls are excluded from each field's denominator; TF is not applied during EM."
  def estimate_m(patterns, model, config) do
    initial =
      Map.new(model.parameters, fn {field, params} ->
        {field, Map.new(params, fn {level, params} -> {level, params.m} end)}
      end)

    patterns =
      Enum.map(patterns, fn {pattern, count} ->
        {observed_levels(pattern, config.comparisons), count}
      end)

    {estimated, iters} = em(patterns, initial, model, config, 0)

    {estimated, unstable} =
      Enum.map_reduce(config.comparisons, false, fn comparison, unstable ->
        failed =
          Enum.any?(non_null(comparison), fn level ->
            Comparison.exact_style?(level) and
              estimated[comparison.field][level.name] <=
                model.parameters[comparison.field][level.name].u
          end)

        {{comparison.field,
          if(failed, do: initial[comparison.field], else: estimated[comparison.field])},
         unstable or failed}
      end)

    parameters =
      Map.new(estimated, fn {field, masses} ->
        {field,
         Map.new(masses, fn {level, m} -> {level, %{model.parameters[field][level] | m: m}} end)}
      end)

    %{
      model
      | parameters: parameters,
        trained: Map.merge(model.trained, %{em_iters: iters, unstable: unstable})
    }
  end

  defp em(_patterns, masses, _model, config, iters) when iters >= config.em_max_iters,
    do: {masses, iters}

  defp em(patterns, masses, model, config, iters) do
    counts =
      Map.new(masses, fn {field, levels} ->
        {field, Map.new(levels, fn {name, _} -> {name, 0.0} end)}
      end)

    counts =
      Enum.reduce(patterns, counts, fn {observed, count}, counts ->
        weight =
          Scorer.log2(model.lambda / (1 - model.lambda)) +
            Enum.sum(
              Enum.map(observed, fn {f, l} ->
                Scorer.log2(masses[f][l] / model.parameters[f][l].u)
              end)
            )

        expected = count * Scorer.probability(weight)

        Enum.reduce(observed, counts, fn {field, level}, counts ->
          update_in(counts, [field, level], &(&1 + expected))
        end)
      end)

    updated =
      Map.new(counts, fn {field, levels} ->
        {field,
         if(Enum.sum(Map.values(levels)) == 0, do: masses[field], else: distribution(levels))}
      end)

    change = for {f, levels} <- updated, {l, mass} <- levels, do: abs(mass - masses[f][l])

    if Enum.max(change, fn -> 0 end) < config.em_tol,
      do: {updated, iters + 1},
      else: em(patterns, updated, model, config, iters + 1)
  end

  defp observed_levels(pattern, comparisons) do
    comparisons
    |> Enum.with_index()
    |> Enum.flat_map(fn {comparison, i} ->
      name = elem(pattern, i)
      level = Enum.find(comparison.levels, &(&1.name == name))
      if level.null_level?, do: [], else: [{comparison.field, name}]
    end)
  end

  defp sample_rank(k, {ranks, state}) do
    {draw, state} = :rand.uniform_s(k + 1, state)
    rank = draw - 1
    selected = if MapSet.member?(ranks, rank), do: k, else: rank
    {MapSet.put(ranks, selected), state}
  end

  defp count_levels(comparisons, left, right, counts) do
    Enum.reduce(comparisons, counts, fn comparison, counts ->
      level = Comparison.run(comparison, left, right)

      if level.null_level?,
        do: counts,
        else: update_in(counts, [comparison.field, level.name], &(&1 + 1))
    end)
  end

  defp validate_initial_m!(supplied, defaults) do
    unless is_map(supplied) and
             Enum.all?(supplied, fn {name, mass} ->
               Map.has_key?(defaults, name) and is_number(mass) and mass >= 0
             end),
           do: raise(ArgumentError, "m_init must map non-null level names to nonnegative masses")
  end

  defp initial_mass(level) do
    cond do
      Comparison.exact_style?(level) or level.name in [:exact, :jw_0_92, :dob_exact] ->
        0.90

      level.name in [:jw_0_85, :within_1_day, :zip3, :last7, :last4, :phone_last7, :ssn_last4] ->
        0.70

      level.name == :same_year_month ->
        0.50

      true ->
        0.50
    end
  end

  @doc "Returns the ordered levels eligible for parameter estimation."
  def non_null(comparison), do: Enum.reject(comparison.levels, & &1.null_level?)

  @doc "Floor and normalize; retain the 1e-6 lower bound even after renormalization. All-zero counts are uniform."
  def distribution(values) do
    values = Map.new(values, fn {key, value} -> {key, max(value, 0.0)} end)

    if Enum.sum(Map.values(values)) == 0 do
      Map.new(values, fn {key, _} -> {key, 1 / map_size(values)} end)
    else
      normalize_active(values, %{})
    end
  end

  defp normalize_active(active, fixed) do
    total = Enum.sum(Map.values(active))
    available = 1 - map_size(fixed) * @floor
    {low, high} = Enum.split_with(active, fn {_, value} -> value / total * available < @floor end)

    if low == [] do
      Map.merge(fixed, Map.new(high, fn {key, value} -> {key, value / total * available} end))
    else
      normalize_active(
        Map.new(high),
        Map.merge(fixed, Map.new(low, fn {key, _} -> {key, @floor} end))
      )
    end
  end

  defp row(_rank, _n, low, high) when low >= high, do: low

  defp row(rank, n, low, high) do
    mid = div(low + high + 1, 2)
    offset = div(mid * (2 * n - mid - 1), 2)
    if offset <= rank, do: row(rank, n, mid, high), else: row(rank, n, low, mid - 1)
  end
end
