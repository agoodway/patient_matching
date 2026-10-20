defmodule PatientMatching.Trainer do
  @moduledoc false
  alias PatientMatching.{Blocking, Comparison, Config, Model, Scorer}
  @floor 1.0e-6
  @min_lambda 1.0e-9
  @max_lambda 0.5
  @m_prior_message "m_prior must map comparison fields to non-null level names with nonnegative counts"

  @doc """
  Estimates a model from one file: a random-pair prior, random-pair u, and m
  from one EM session per training blocking rule.
  """
  def train(records, config, opts \\ []) do
    config = Config.validate!(config)
    prior = prior!(config.comparisons, opts)
    records = Blocking.prepare(records, config.placeholders, config.strip_mrn_leading_zeros)
    n = length(records)
    if n < 2, do: raise(ArgumentError, "training requires at least 2 records, got #{n}")

    if config.comparisons == [],
      do: raise(ArgumentError, "training requires comparisons, got 0 for #{n} records")

    deterministic = deterministic_pairs(records, config)
    sessions = Enum.map(config.training_blocking, &session(records, &1, config))

    if Enum.all?(sessions, &(&1.pairs == [])),
      do: raise(ArgumentError, "0 training candidate pairs for #{n} records")

    {lambda, source} =
      if Keyword.has_key?(opts, :lambda) do
        {clamp_lambda(Keyword.fetch!(opts, :lambda)), :fixed}
      else
        {lambda_from(deterministic, n, config), :deterministic}
      end

    u = estimate_u_prepared(records, config, deterministic)
    m = initial_m(config, Keyword.get(opts, :m_init, %{}), opts)

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
      trained: %{
        lambda_source: source,
        unstable: false,
        em_iters: 0,
        tf_records: n,
        lambda_train: [],
        m_prior: prior.totals,
        m_prior_strength: prior.strength,
        m_prior_base_weight: prior.base_weight
      }
    }

    deterministic = MapSet.new(deterministic)
    prior_opts = Keyword.take(opts, [:m_prior, :m_prior_strength])

    sessions
    |> Enum.reject(&(&1.pairs == []))
    |> Enum.map(&run_session(&1, records, model, config, deterministic, prior_opts))
    |> combine_sessions(model, config)
  end

  # EM for one training session, starting from its share of deterministic pairs.
  defp run_session(session, records, model, config, deterministic, prior_opts) do
    hits = Enum.count(session.pairs, &MapSet.member?(deterministic, &1))
    start = clamp_train(hits / length(session.pairs) / config.lambda_recall)
    patterns = pattern_counts_prepared(records, session.pairs, config)
    opts = [fields: session.fields, lambda_train: start] ++ prior_opts

    %{estimated: session.fields, model: estimate_m(patterns, model, config, opts)}
  end

  # Fields a blocking rule conditions on can't be estimated from its pairs:
  # every pair agrees on them, matches or not.
  defp session(records, rule, config) do
    blocked =
      Blocking.candidates_prepared(records, [rule], :dedupe_only,
        max_block_size: config.training_block_size,
        oversized: {:sample, config.seed}
      )

    used = Blocking.rule_fields(rule)

    fields =
      for c <- config.comparisons,
          not Enum.any?(Comparison.fields(c), &(&1 in used)),
          do: c.field

    %{pairs: blocked.pairs, fields: fields}
  end

  # Averages each field's m over the sessions that estimated it.
  defp combine_sessions(results, model, config) do
    parameters =
      Map.new(config.comparisons, fn comparison ->
        field = comparison.field
        estimates = for r <- results, field in r.estimated, do: r.model.parameters[field]

        {field, average_m(model.parameters[field], estimates)}
      end)

    %{
      model
      | parameters: parameters,
        trained:
          Map.merge(model.trained, %{
            em_iters: Enum.sum(Enum.map(results, & &1.model.trained.em_iters)),
            unstable: Enum.any?(results, & &1.model.trained.unstable),
            lambda_train: Enum.map(results, & &1.model.trained.lambda_train)
          })
    }
  end

  defp average_m(params, []), do: params

  defp average_m(params, estimates) do
    params
    |> Map.new(fn {level, _} ->
      {level, Enum.sum(Enum.map(estimates, & &1[level].m)) / length(estimates)}
    end)
    |> distribution()
    |> Map.new(fn {level, m} -> {level, %{params[level] | m: m}} end)
  end

  @doc """
  Prior probability that two random records in the file are the same patient:
  deterministic agreements (same name and DOB, or same SSN) over all n(n-1)/2
  pairs, divided by `lambda_recall`. This is the prior that matches u, which
  is also estimated from random pairs.
  """
  def estimate_lambda(records, config) do
    records = Blocking.prepare(records, config.placeholders, config.strip_mrn_leading_zeros)
    lambda_from(deterministic_pairs(records, config), length(records), config)
  end

  defp lambda_from(pairs, n, config),
    do: clamp_lambda(length(pairs) / max(div(n * (n - 1), 2), 1) / config.lambda_recall)

  defp deterministic_pairs(records, config) do
    Blocking.candidates_prepared(
      records,
      [[:family_name, :given_name, :dob], [:ssn]],
      :dedupe_only,
      max_block_size: config.max_block_size
    ).pairs
  end

  defp clamp_train(value), do: min(0.99, max(@floor, value))

  defp clamp_lambda(value) when is_number(value),
    do: min(@max_lambda, max(@min_lambda, value * 1.0))

  defp clamp_lambda(_), do: raise(ArgumentError, "lambda must be numeric")

  @doc "Uniform unordered pairs without replacement; a local RNG leaves caller state untouched."
  def sample_pairs(records, config),
    do:
      records
      |> Blocking.prepare(config.placeholders, config.strip_mrn_leading_zeros)
      |> sample_pairs_prepared(config)

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
  def estimate_u(records, config) do
    records = Blocking.prepare(records, config.placeholders, config.strip_mrn_leading_zeros)
    estimate_u_prepared(records, config, deterministic_pairs(records, config))
  end

  # Pairs that agree deterministically are probably the same patient, so they
  # are left out of the non-match sample.
  defp estimate_u_prepared(records, config, deterministic) do
    index = Map.new(records, &{&1.id, &1})
    deterministic = MapSet.new(deterministic)

    pairs =
      records |> sample_pairs_prepared(config) |> Enum.reject(&MapSet.member?(deterministic, &1))

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
    do:
      records
      |> Blocking.prepare(config.placeholders, config.strip_mrn_leading_zeros)
      |> term_frequencies_prepared(config)

  defp term_frequencies_prepared(records, config) do
    n = length(records)

    config
    |> Config.frequency_fields()
    |> Map.new(fn field ->
      frequencies =
        records
        |> Enum.map(&Map.get(&1.normalized, field))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      {field, Map.new(frequencies, fn {value, count} -> {value, count / max(n, 1)} end)}
    end)
  end

  @doc "Aggregate ordered comparison-level tuples before running EM."
  def pattern_counts(records, pairs, config),
    do:
      records
      |> Blocking.prepare(config.placeholders, config.strip_mrn_leading_zeros)
      |> pattern_counts_prepared(pairs, config)

  # Chunks carry only the records their pairs reference (see Linker).
  defp pattern_counts_prepared(records, pairs, config) do
    index = Map.new(records, &{&1.id, &1})
    workers = System.schedulers_online()

    pairs
    |> Enum.chunk_every(max(div(length(pairs), workers * 4), 1_000))
    |> Enum.map(fn chunk ->
      {chunk, Map.take(index, Enum.flat_map(chunk, fn {a, b} -> [a, b] end))}
    end)
    |> Task.async_stream(
      fn {chunk, index} -> count_patterns(chunk, index, config.comparisons) end,
      max_concurrency: workers,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, counts}, acc ->
      Map.merge(acc, counts, fn _, x, y -> x + y end)
    end)
  end

  defp count_patterns(pairs, index, comparisons) do
    Enum.reduce(pairs, %{}, fn {a, b}, counts ->
      pattern =
        comparisons
        |> Enum.map(&Comparison.run(&1, index[a], index[b]).name)
        |> List.to_tuple()

      Map.update(counts, pattern, 1, &(&1 + 1))
    end)
  end

  @doc """
  Initial masses follow the brief. If agreement masses exceed one, normalize
  them with a floored else remainder. Unknown custom levels start at 0.5.

  `prior_opts` takes the `:m_prior`, `:m_prior_strength` and
  `:m_prior_base_weight` options of `train/3`. For each active prior field the
  base m (defaults merged with `overrides`) is blended with the prior counts as
  `(k * base + strength * count) / (k + strength * total)`. Fields without an
  active prior keep the base m untouched.
  """
  def initial_m(config, overrides \\ %{}, prior_opts \\ []) do
    %{prior: prior, strength: strength, base_weight: k} =
      prior!(config.comparisons, prior_opts)

    Map.new(config.comparisons, fn comparison ->
      base = base_m(comparison, Map.get(overrides, comparison.field, %{}))

      case Map.fetch(prior, comparison.field) do
        {:ok, counts} -> {comparison.field, blend(base, counts, strength, k)}
        :error -> {comparison.field, base}
      end
    end)
  end

  # The built-in defaults merged with `m_init`, floored and normalized.
  defp base_m(comparison, supplied) do
    agreements =
      comparison
      |> non_null()
      |> Enum.reject(&(&1.name == :else))
      |> Map.new(&{&1.name, initial_mass(&1)})

    defaults = Map.put(agreements, :else, max(1 - Enum.sum(Map.values(agreements)), @floor))
    validate_initial_m!(supplied, defaults)
    distribution(Map.merge(defaults, supplied))
  end

  defp blend(base, counts, strength, k) do
    total = counts |> Map.values() |> Enum.sum()

    base
    |> Map.new(fn {level, mass} ->
      {level, (k * mass + strength * counts[level]) / (k + strength * total)}
    end)
    |> distribution()
  end

  @doc """
  Validates the m prior options and returns the normalized prior.

  Reads `:m_prior` (default `%{}`), `:m_prior_strength` (default `1.0`) and
  `:m_prior_base_weight` (default `10.0`) from `opts`. Returns a map with:

    * `:prior` - only the active fields (raw total times strength above 0),
      each filled to every non-null level with missing levels as `0`
    * `:totals` - raw count totals before strength, for every field with a
      nonzero total
    * `:strength` and `:base_weight` - the two numbers, as floats

  Raises `ArgumentError` with a fixed message when an option is invalid.
  """
  def prior!(comparisons, opts) do
    raw = Keyword.get(opts, :m_prior, %{})
    strength = Keyword.get(opts, :m_prior_strength, 1.0)
    base_weight = Keyword.get(opts, :m_prior_base_weight, 10.0)

    unless is_number(strength) and strength >= 0,
      do: raise(ArgumentError, "m_prior_strength must be a nonnegative number")

    unless is_number(base_weight) and base_weight > 0,
      do: raise(ArgumentError, "m_prior_base_weight must be a positive number")

    unless is_map(raw), do: raise(ArgumentError, @m_prior_message)

    levels_by_field =
      Map.new(comparisons, fn comparison ->
        {comparison.field, comparison |> non_null() |> Enum.map(& &1.name)}
      end)

    totals =
      Map.new(raw, fn {field, counts} ->
        unless valid_counts?(counts, Map.get(levels_by_field, field)),
          do: raise(ArgumentError, @m_prior_message)

        {field, counts |> Map.values() |> Enum.sum()}
      end)

    prior =
      for {field, counts} <- raw, totals[field] * strength > 0, into: %{} do
        {field, Map.new(levels_by_field[field], &{&1, Map.get(counts, &1, 0)})}
      end

    %{
      prior: prior,
      totals: Map.reject(totals, fn {_, total} -> total == 0 end),
      strength: strength * 1.0,
      base_weight: base_weight * 1.0
    }
  end

  # `levels` is nil when the field is not a comparison name.
  defp valid_counts?(counts, levels) when is_map(counts) and is_list(levels),
    do:
      Enum.all?(counts, fn {level, count} ->
        level in levels and is_number(count) and count >= 0
      end)

  defp valid_counts?(_counts, _levels), do: false

  @doc """
  EM over pattern counts. Estimates m for the comparisons in `:fields`
  (default: all) together with the prior within the training pairs, which
  starts at `:lambda_train` (default: the model's lambda). u, the model's
  prediction lambda, and the m of fields outside `:fields` stay fixed. Nulls
  are excluded from each field's denominator; TF is not applied during EM.

  `:m_prior` and `:m_prior_strength` are validated as in `train/3`. Each
  M-step adds `strength * count` pseudo-counts to the expected match counts of
  an estimated field that has non-null observations. They never enter
  lambda's update. `:m_prior_base_weight` is validated but unused here: the
  blended start arrives through `model.parameters`.
  """
  def estimate_m(patterns, model, config, opts \\ []) do
    fields = Keyword.get(opts, :fields, Enum.map(config.comparisons, & &1.field))
    lambda_train = Keyword.get(opts, :lambda_train, model.lambda)
    scaled = scaled_prior(config.comparisons, fields, opts)

    initial =
      Map.new(model.parameters, fn {field, params} ->
        {field, Map.new(params, fn {level, params} -> {level, params.m} end)}
      end)

    active = Enum.filter(config.comparisons, &(&1.field in fields))

    patterns =
      patterns
      |> Enum.map(fn {pattern, count} ->
        {observed_levels(pattern, config.comparisons, fields), count}
      end)
      |> Enum.reject(fn {observed, _} -> observed == [] end)

    {estimated, lambda_train, iters} =
      em(patterns, initial, lambda_train, model, config, scaled, 0)

    {estimated, unstable} =
      Enum.map_reduce(active, false, fn comparison, unstable ->
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
      Map.new(model.parameters, fn {field, params} ->
        case List.keyfind(estimated, field, 0) do
          nil ->
            {field, params}

          {_, masses} ->
            {field, Map.new(masses, fn {level, m} -> {level, %{params[level] | m: m}} end)}
        end
      end)

    %{
      model
      | parameters: parameters,
        trained:
          Map.merge(model.trained, %{
            em_iters: iters,
            unstable: unstable,
            lambda_train: lambda_train
          })
    }
  end

  # Active prior counts times strength, restricted to the session's fields.
  defp scaled_prior(comparisons, fields, opts) do
    %{prior: prior, strength: strength} = prior!(comparisons, opts)

    prior
    |> Map.take(fields)
    |> Map.new(fn {field, counts} ->
      {field, Map.new(counts, fn {level, count} -> {level, strength * count} end)}
    end)
  end

  defp em(_patterns, masses, lambda, _model, config, _scaled, iters)
       when iters >= config.em_max_iters,
       do: {masses, lambda, iters}

  defp em(patterns, masses, lambda, model, config, scaled, iters) do
    counts =
      Map.new(masses, fn {field, levels} ->
        {field, Map.new(levels, fn {name, _} -> {name, 0.0} end)}
      end)

    {counts, matched, total} =
      Enum.reduce(patterns, {counts, 0.0, 0}, fn {observed, count}, {counts, matched, total} ->
        weight =
          Scorer.log2(lambda / (1 - lambda)) +
            Enum.sum(
              Enum.map(observed, fn {f, l} ->
                Scorer.log2(masses[f][l] / model.parameters[f][l].u)
              end)
            )

        expected = count * Scorer.probability(weight)

        counts =
          Enum.reduce(observed, counts, fn {field, level}, counts ->
            update_in(counts, [field, level], &(&1 + expected))
          end)

        {counts, matched + expected, total + count}
      end)

    updated =
      Map.new(counts, fn {field, levels} ->
        {field, m_step(levels, masses[field], Map.get(scaled, field))}
      end)

    lambda_next = if total == 0, do: lambda, else: clamp_train(matched / total)
    change = for {f, levels} <- updated, {l, mass} <- levels, do: abs(mass - masses[f][l])
    change = [abs(lambda_next - lambda) | change]

    if Enum.max(change) < config.em_tol,
      do: {updated, lambda_next, iters + 1},
      else: em(patterns, updated, lambda_next, model, config, scaled, iters + 1)
  end

  # A field without observations keeps its masses; the prior is not counted
  # as an observation. With no prior the expected counts go straight to
  # distribution/1, which keeps results bit-identical to training without one.
  defp m_step(levels, masses, prior) do
    cond do
      Enum.sum(Map.values(levels)) == 0 ->
        masses

      is_nil(prior) ->
        distribution(levels)

      true ->
        levels |> Map.merge(prior, fn _, count, extra -> count + extra end) |> distribution()
    end
  end

  defp observed_levels(pattern, comparisons, fields) do
    comparisons
    |> Enum.with_index()
    |> Enum.flat_map(fn {comparison, i} ->
      name = elem(pattern, i)
      level = Enum.find(comparison.levels, &(&1.name == name))

      if level.null_level? or comparison.field not in fields,
        do: [],
        else: [{comparison.field, name}]
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

  # Variant levels that the preset adds; true matches rarely land on them.
  @variant_levels [
    :nickname,
    :compound,
    :prefix,
    :part,
    :initial,
    :swapped,
    :month_day_swapped,
    :one_digit,
    :phone,
    :street_and_zip,
    :building_and_zip,
    :zip,
    :near
  ]

  defp initial_mass(level) do
    cond do
      Comparison.exact_style?(level) or
          level.name in [:exact, :jw_0_92, :dob_exact, :phone_and_zip] ->
        0.90

      level.name in [:jw_0_85, :within_1_day, :zip3, :last7, :last4, :phone_last7, :ssn_last4] ->
        0.70

      level.name in @variant_levels ->
        0.05

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
