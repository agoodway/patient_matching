defmodule PatientMatching.ScoringTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias PatientMatching.{Comparators, Comparison, Config, Level, Normalize, Scorer, TestModels}

  test "ordered levels, null skipping and hand-calculated base-two weights" do
    model = TestModels.fixed()
    left = Normalize.record(%{id: 1, family_name: "Smith"})
    right = Normalize.record(%{id: 2, family_name: "Smith"})
    score = Scorer.score(left, right, model)
    assert hd(score.levels).level == :exact
    assert_in_delta score.weight, :math.log(8 / 9) / :math.log(2), 1.0e-12
    assert_in_delta score.probability, 8 / 17, 1.0e-12
    assert score.reason == :scored
    null = Scorer.score(left, Normalize.record(%{id: 3}), model)
    removed = Scorer.score(left, right, %{model | comparisons: []})
    assert null.weight == removed.weight
    assert hd(null.levels).weight == 0.0
    assert hd(null.levels).level == :null
    both = Scorer.score(Normalize.record(%{id: 4}), Normalize.record(%{id: 5}), model)
    assert both.weight == removed.weight
  end

  property "ordered m/u gives exact >= fuzzy >= disagreement" do
    check all(suffix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      model = TestModels.fixed()
      left = Normalize.record(%{id: 1, family_name: "MARTHA" <> suffix})
      exact = Scorer.score(left, left, model)

      fuzzy =
        Scorer.score(left, Normalize.record(%{id: 2, family_name: "MARHTA" <> suffix}), model)

      different = Scorer.score(left, Normalize.record(%{id: 3, family_name: "ZZZZ"}), model)
      assert exact.weight >= fuzzy.weight
      assert fuzzy.weight >= different.weight
    end
  end

  test "config rejects weakened comparison invariants and invalid thresholds" do
    good = TestModels.name_comparison()
    assert Config.new(comparisons: [good]).max_block_size == 500

    assert_raise ArgumentError, fn ->
      Config.new(comparisons: [%{good | levels: tl(good.levels)}])
    end

    assert_raise ArgumentError, fn ->
      Config.new(comparisons: [%{good | levels: Enum.reverse(good.levels)}])
    end

    assert_raise ArgumentError, fn -> Config.new(comparisons: [good, good]) end

    bad = %Comparison{
      field: :x,
      levels: [
        %Level{name: :null, null_level?: true},
        %Level{name: :fuzzy, tf?: true, match?: fn _, _ -> true end},
        %Level{name: :else}
      ]
    }

    assert_raise ArgumentError, fn -> Config.new(comparisons: [bad]) end

    assert_raise ArgumentError, fn ->
      Config.new(comparisons: [good], match_threshold: 0.1, review_threshold: 0.2)
    end

    assert_raise ArgumentError, fn -> Config.new(comparisons: [good], max_block_size: 0) end
    assert_raise ArgumentError, fn -> Config.new(comparisons: [good], unexpected: true) end
  end

  test "term frequencies add exactly the documented rarity difference" do
    model = TestModels.fixed(tf: true)

    common =
      Scorer.score(
        Normalize.record(%{id: 1, family_name: "SMITH"}),
        Normalize.record(%{id: 2, family_name: "SMITH"}),
        model
      )

    rare =
      Scorer.score(
        Normalize.record(%{id: 3, family_name: "RARE"}),
        Normalize.record(%{id: 4, family_name: "RARE"}),
        model
      )

    assert rare.weight > common.weight
    assert_in_delta rare.weight - common.weight, :math.log(100) / :math.log(2), 1.0e-9
    assert hd(rare.tf_adjustments).adjustment > 0
    assert rare.levels == common.levels
  end

  test "probabilities remain finite for overwhelming evidence" do
    model = TestModels.fixed()
    comps = for i <- 1..1000, do: %{TestModels.name_comparison() | field: i}
    parameters = Map.new(comps, &{&1.field, model.parameters.family_name})
    all_exact = %{normalized: Map.new(comps, &{&1.field, "SAME"})}
    all_else = %{normalized: Map.new(comps, &{&1.field, "OTHER"})}
    wide = %{model | comparisons: comps, parameters: parameters}
    assert Scorer.score(all_exact, all_exact, wide).probability == 1.0
    assert Scorer.score(all_exact, all_else, wide).probability == 0.0
  end

  test "null and else semantics are controlled by the runner" do
    comparison = %Comparison{
      field: :family_name,
      levels: [
        %Level{name: :null, null_level?: true, match?: fn _, _ -> false end},
        %Level{name: :exact, match?: &Comparators.exact?/2},
        %Level{name: :else, match?: fn _, _ -> false end}
      ]
    }

    assert Comparison.run(comparison, %{normalized: %{family_name: nil}}, %{
             normalized: %{family_name: nil}
           }).name == :null

    assert Comparison.run(comparison, %{normalized: %{family_name: "A"}}, %{
             normalized: %{family_name: "B"}
           }).name == :else
  end
end
