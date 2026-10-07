defmodule PatientMatching.EMTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Config, Model, Synthetic, TestModels, Trainer}

  test "EM recovers known m within 0.05 from pattern counts with u and lambda fixed" do
    m = %{
      a: %{exact: 0.85, jw_0_85: 0.10, else: 0.05},
      b: %{exact: 0.80, jw_0_85: 0.15, else: 0.05},
      c: %{exact: 0.75, jw_0_85: 0.20, else: 0.05},
      d: %{exact: 0.90, jw_0_85: 0.05, else: 0.05}
    }

    u = %{
      a: %{exact: 0.05, jw_0_85: 0.10, else: 0.85},
      b: %{exact: 0.03, jw_0_85: 0.12, else: 0.85},
      c: %{exact: 0.02, jw_0_85: 0.08, else: 0.90},
      d: %{exact: 0.08, jw_0_85: 0.12, else: 0.80}
    }

    comparisons =
      for field <- [:a, :b, :c, :d], do: %{TestModels.name_comparison() | field: field}

    config = Config.new(comparisons: comparisons, em_tol: 1.0e-8)
    initial = Trainer.initial_m(config)

    params =
      Map.new(initial, fn {f, masses} ->
        {f, Map.new(masses, fn {l, mass} -> {l, %{m: mass, u: u[f][l]}} end)}
      end)

    model = %Model{config: config, comparisons: comparisons, lambda: 0.15, parameters: params}
    result = Trainer.estimate_m(Synthetic.patterns(m, u, 0.15), model, config)

    for {field, masses} <- m, {level, truth} <- masses do
      assert_in_delta result.parameters[field][level].m, truth, 0.05
      assert result.parameters[field][level].u == u[field][level]
    end

    assert result.lambda == 0.15
    assert result.trained.em_iters <= 25
    refute result.trained.unstable
  end

  test "all-null patterns cannot move m or enter field denominators" do
    model = TestModels.fixed()
    config = %{model.config | em_tol: 1.0e-8}
    patterns = %{{:exact} => 100, {:jw_0_85} => 50, {:else} => 1000}
    original = Trainer.estimate_m(patterns, model, config)
    with_nulls = Trainer.estimate_m(Map.put(patterns, {:null}, 100_000), model, config)
    assert with_nulls.parameters == original.parameters
    assert with_nulls.trained.em_iters == original.trained.em_iters
  end

  test "unstable exact evidence restores the whole field's initial m" do
    model = TestModels.fixed()
    result = Trainer.estimate_m(%{{:else} => 1000}, model, model.config)
    assert result.trained.unstable
    assert result.parameters == model.parameters
  end

  test "custom non-TF exact equality predicates trigger the unstable-field fallback" do
    model = TestModels.fixed()
    [comparison] = model.comparisons

    levels =
      Enum.map(comparison.levels, fn level ->
        if level.name == :exact, do: %{level | match?: fn a, b -> a == b end}, else: level
      end)

    model = %{model | comparisons: [%{comparison | levels: levels}]}
    config = %{model.config | comparisons: model.comparisons}
    result = Trainer.estimate_m(%{{:else} => 1000}, model, config)
    assert result.trained.unstable
    assert result.parameters == model.parameters
  end

  test "ignored else predicates cannot change EM stability or estimates" do
    model = TestModels.fixed()
    [comparison] = model.comparisons

    levels =
      Enum.map(comparison.levels, fn level ->
        if level.name == :else,
          do: %{level | match?: &PatientMatching.Comparators.exact?/2},
          else: level
      end)

    modified = %{model | comparisons: [%{comparison | levels: levels}]}
    config = %{model.config | comparisons: modified.comparisons}
    original = Trainer.estimate_m(%{{:exact} => 1000}, model, model.config)
    result = Trainer.estimate_m(%{{:exact} => 1000}, modified, config)
    refute result.trained.unstable
    assert result.parameters == original.parameters
  end

  test "identical gamma patterns aggregate before EM" do
    config = TestModels.fixed().config

    records = [
      %{id: 1, family_name: "Smith"},
      %{id: 2, family_name: "Smith"},
      %{id: 3, family_name: "Smith"},
      %{id: 4}
    ]

    patterns = Trainer.pattern_counts(records, [{1, 2}, {1, 3}, {2, 3}, {1, 4}], config)
    assert patterns == %{{:exact} => 3, {:null} => 1}
  end

  test "initial m overrides are floored and normalized" do
    config = TestModels.fixed().config
    m = Trainer.initial_m(config, %{family_name: %{exact: 0.8, jw_0_85: 0.2, else: 0.0}})
    assert m.family_name.else >= 1.0e-6
    assert_in_delta Enum.sum(Map.values(m.family_name)), 1.0, 1.0e-12
    assert_in_delta m.family_name.exact, 0.8, 1.0e-6
  end
end
