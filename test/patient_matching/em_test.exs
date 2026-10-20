defmodule PatientMatching.EMTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Config, Model, Synthetic, TestModels, Trainer}

  # Known m and u for the four-field EM fixture.
  @four_m %{
    a: %{exact: 0.85, jw_0_85: 0.10, else: 0.05},
    b: %{exact: 0.80, jw_0_85: 0.15, else: 0.05},
    c: %{exact: 0.75, jw_0_85: 0.20, else: 0.05},
    d: %{exact: 0.90, jw_0_85: 0.05, else: 0.05}
  }

  @four_u %{
    a: %{exact: 0.05, jw_0_85: 0.10, else: 0.85},
    b: %{exact: 0.03, jw_0_85: 0.12, else: 0.85},
    c: %{exact: 0.02, jw_0_85: 0.08, else: 0.90},
    d: %{exact: 0.08, jw_0_85: 0.12, else: 0.80}
  }

  test "EM recovers known m within 0.05 from pattern counts with u and lambda fixed" do
    {patterns, model, config} = four_field_fixture(em_tol: 1.0e-8)
    result = Trainer.estimate_m(patterns, model, config)

    for {field, masses} <- @four_m, {level, truth} <- masses do
      assert_in_delta result.parameters[field][level].m, truth, 0.05
      assert result.parameters[field][level].u == @four_u[field][level]
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

  describe "m prior validation and initial m" do
    setup do
      config = TestModels.fixed().config
      {:ok, config: config, base: Trainer.initial_m(config).family_name}
    end

    test "no prior or zero strength leaves initial m bit-identical", %{config: config} do
      assert Trainer.initial_m(config, %{}, m_prior: %{}) == Trainer.initial_m(config)

      assert Trainer.initial_m(config, %{},
               m_prior: %{family_name: %{exact: 5}},
               m_prior_strength: 0
             ) == Trainer.initial_m(config)
    end

    test "one label blends 1/11 toward the prior with k = 10", %{config: config, base: base} do
      m = Trainer.initial_m(config, %{}, m_prior: %{family_name: %{exact: 1}}).family_name
      # The default else sits at the 1e-6 floor, so renormalizing shifts the others by about 5e-8.
      assert_in_delta m.exact, (10 * base.exact + 1) / 11, 1.0e-6
      assert_in_delta m.jw_0_85, 10 * base.jw_0_85 / 11, 1.0e-6
      # no level drops to the floor unless its default is already there
      for {l, v} <- m, base[l] > 1.0e-6, do: assert(v > 1.0e-6)
    end

    test "huge strength makes initial m the prior proportions", %{config: config} do
      m =
        Trainer.initial_m(config, %{},
          m_prior: %{family_name: %{exact: 3, jw_0_85: 1}},
          m_prior_strength: 1.0e9
        ).family_name

      assert_in_delta m.exact, 0.75, 1.0e-5
      assert_in_delta m.jw_0_85, 0.25, 1.0e-5
      assert m.else >= 1.0e-6
    end

    test "float counts and m_init combine with the prior", %{config: config} do
      init = %{family_name: %{exact: 0.6, jw_0_85: 0.3, else: 0.1}}
      base = Trainer.initial_m(config, init).family_name

      m =
        Trainer.initial_m(config, init,
          m_prior: %{family_name: %{exact: 2.5}},
          m_prior_base_weight: 2.5
        ).family_name

      assert_in_delta m.exact, (2.5 * base.exact + 2.5) / 5, 1.0e-9
    end

    test "multi-field comparisons are keyed by comparison name" do
      config = PatientMatching.Presets.patient_mpi()

      assert %{name_order: %{swapped: 2, else: 0}} =
               Trainer.prior!(config.comparisons, m_prior: %{name_order: %{swapped: 2}}).prior
    end

    test "prior! returns raw totals and float numbers even when inactive", %{config: config} do
      assert Trainer.prior!(config.comparisons,
               m_prior: %{family_name: %{exact: 3}},
               m_prior_strength: 0,
               m_prior_base_weight: 4
             ) == %{prior: %{}, totals: %{family_name: 3}, strength: 0.0, base_weight: 4.0}
    end

    test "invalid priors raise fixed messages without values", %{config: config} do
      comparisons = config.comparisons

      for opts <- [
            [m_prior: %{zzz_secret: %{exact: 1}}],
            [m_prior: %{family_name: %{zzz_secret: 1}}],
            [m_prior: %{family_name: %{null: 1}}],
            [m_prior: %{family_name: %{exact: -1}}],
            [m_prior: %{family_name: %{exact: "zzz_secret"}}],
            [m_prior: [family_name: [exact: 1]]],
            [m_prior: %{family_name: [exact: 1]}],
            [m_prior_strength: -1],
            [m_prior_strength: "zzz_secret"],
            [m_prior_base_weight: 0],
            [m_prior_base_weight: -1.0]
          ] do
        error = assert_raise ArgumentError, fn -> Trainer.prior!(comparisons, opts) end
        refute error.message =~ "zzz_secret"
        refute error.message =~ "-1"
      end

      # A preset underlying field that is not a comparison name is unknown.
      preset = PatientMatching.Presets.patient_mpi()

      assert_raise ArgumentError, fn ->
        Trainer.prior!(preset.comparisons, m_prior: %{zip: %{exact: 1}})
      end
    end
  end

  describe "m prior in the M-step" do
    test "a large prior pins an estimated field to its proportions" do
      model = TestModels.fixed()

      r =
        Trainer.estimate_m(
          %{{:exact} => 100, {:jw_0_85} => 50, {:else} => 1000},
          model,
          model.config,
          m_prior: %{family_name: %{exact: 3, jw_0_85: 1}},
          m_prior_strength: 1.0e9
        )

      assert_in_delta r.parameters.family_name.exact.m, 0.75, 1.0e-5
      assert_in_delta r.parameters.family_name.jw_0_85.m, 0.25, 1.0e-5
    end

    test "a one-count prior barely moves a converged estimate" do
      {patterns, model, config} = four_field_fixture()
      plain = Trainer.estimate_m(patterns, model, config)
      primed = Trainer.estimate_m(patterns, model, config, m_prior: %{a: %{jw_0_85: 1}})
      # Each direct call converges on its own; train/3's em_iters is a sum over sessions.
      assert plain.trained.em_iters < config.em_max_iters
      assert primed.trained.em_iters < config.em_max_iters

      for {l, p} <- plain.parameters.a,
          do: assert_in_delta(primed.parameters.a[l].m, p.m, 1.0e-3)
    end

    test "a prior on a field outside the session's fields changes nothing for it" do
      {model, config} = two_field_model()
      patterns = %{{:exact, :exact} => 100, {:else, :jw_0_85} => 200, {:else, :else} => 1000}

      r =
        Trainer.estimate_m(patterns, model, config,
          fields: [:family_name],
          m_prior: %{b: %{exact: 1000}},
          m_prior_strength: 1.0e6
        )

      assert r.parameters.b == model.parameters.b
    end

    test "a field with no observations keeps its blended initial m" do
      prior = %{b: %{exact: 1}}
      {model, config} = two_field_model(m_prior: prior)
      defaults = Trainer.initial_m(config).b
      patterns = %{{:exact, :null} => 500, {:else, :null} => 500}

      r = Trainer.estimate_m(patterns, model, config, m_prior: prior)
      assert r.parameters.b == model.parameters.b

      for {l, p} <- model.parameters.b do
        assert abs(p.m - defaults[l]) <= 1 / 11
        if defaults[l] > 1.0e-6, do: assert(p.m > 1.0e-6)
      end

      opts = [m_prior: prior, m_prior_strength: 1.0e9]
      {model, config} = two_field_model(opts)
      r = Trainer.estimate_m(patterns, model, config, opts)
      assert r.parameters.b == model.parameters.b
      assert_in_delta r.parameters.b.exact.m, 1.0, 1.0e-5
      assert_in_delta r.parameters.b.jw_0_85.m, 0.0, 1.0e-5
      assert_in_delta r.parameters.b.else.m, 0.0, 1.0e-5
    end

    test "the prior never enters lambda's numerator or denominator" do
      model = TestModels.fixed()
      config = %{model.config | em_max_iters: 1}
      p = %{{:exact} => 100, {:jw_0_85} => 50, {:else} => 1000}
      plain = Trainer.estimate_m(p, model, config)
      primed = Trainer.estimate_m(p, model, config, m_prior: %{family_name: %{exact: 1.0e6}})
      assert primed.trained.lambda_train == plain.trained.lambda_train
    end

    test "an unstable field reverts to the blended initial m" do
      # Even a pinned exact m (0.8) is <= u (0.97), so the field is always unstable.
      proportions = %{exact: 0.8, jw_0_85: 0.15, else: 0.05}
      u = %{exact: 0.97, jw_0_85: 0.02, else: 0.01}
      fixed = TestModels.fixed()
      base = Trainer.initial_m(fixed.config).family_name

      for {total, tolerance, target} <- [{1, 1 / 11, base}, {10_000, 2.0e-3, proportions}] do
        prior = %{family_name: Map.new(proportions, fn {l, p} -> {l, p * total} end)}
        m = Trainer.initial_m(fixed.config, %{}, m_prior: prior).family_name
        params = Map.new(m, fn {l, mass} -> {l, %{m: mass, u: u[l]}} end)
        model = %{fixed | parameters: %{family_name: params}}

        r = Trainer.estimate_m(%{{:else} => 1000}, model, model.config, m_prior: prior)
        assert r.trained.unstable
        assert r.parameters == model.parameters

        for {l, p} <- r.parameters.family_name,
            do: assert_in_delta(p.m, target[l], tolerance)
      end
    end

    test "estimate_m validates its prior" do
      model = TestModels.fixed()

      assert_raise ArgumentError, fn ->
        Trainer.estimate_m(%{{:exact} => 1}, model, model.config,
          m_prior: %{family_name: %{zzz: 1}}
        )
      end
    end
  end

  # Four name fields with known m and u, lambda 0.15, starting from the default initial m.
  defp four_field_fixture(config_opts \\ []) do
    comparisons =
      for field <- [:a, :b, :c, :d], do: %{TestModels.name_comparison() | field: field}

    config = Config.new([comparisons: comparisons] ++ config_opts)
    model = model_from(config, Trainer.initial_m(config), @four_u, 0.15)
    {Synthetic.patterns(@four_m, @four_u, 0.15), model, config}
  end

  # :family_name and a second name comparison on :b, both with the fixed model's u.
  defp two_field_model(prior_opts \\ []) do
    comparisons = [TestModels.name_comparison(), %{TestModels.name_comparison() | field: :b}]
    config = Config.new(comparisons: comparisons)
    u = %{exact: 0.1, jw_0_85: 0.2, else: 0.7}
    initial = Trainer.initial_m(config, %{}, prior_opts)
    {model_from(config, initial, %{family_name: u, b: u}, 0.1), config}
  end

  defp model_from(config, initial, u, lambda) do
    params =
      Map.new(initial, fn {f, masses} ->
        {f, Map.new(masses, fn {l, mass} -> {l, %{m: mass, u: u[f][l]}} end)}
      end)

    %Model{config: config, comparisons: config.comparisons, lambda: lambda, parameters: params}
  end
end
