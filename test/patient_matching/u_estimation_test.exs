defmodule PatientMatching.UEstimationTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Config, TestModels, Trainer}

  test "u uses all available unblocked distinct pairs and excludes null denominators" do
    config = Config.new(comparisons: [TestModels.name_comparison(true)], u_sample_size: 100)

    records = [
      %{id: 1, family_name: "Smith"},
      %{id: 2, family_name: "Smith"},
      %{id: 3, family_name: "Other"},
      %{id: 4}
    ]

    u = Trainer.estimate_u(records, config)
    assert_in_delta u.family_name.exact, 1 / 3, 1.0e-6
    assert_in_delta u.family_name.else, 2 / 3, 1.0e-6
    assert u.family_name.jw_0_85 >= 1.0e-6
    assert_in_delta Enum.sum(Map.values(u.family_name)), 1.0, 1.0e-12
    refute Map.has_key?(u.family_name, :null)

    assert Trainer.term_frequencies(records, config).family_name == %{
             "SMITH" => 0.5,
             "OTHER" => 0.25
           }
  end

  test "sampling is seeded, unique, ignores blocking, and does not alter caller RNG" do
    records = for i <- 1..100, do: %{id: i, family_name: "Name#{i}"}

    config =
      Config.new(
        comparisons: [TestModels.name_comparison()],
        u_sample_size: 50,
        seed: 47,
        blocking: [[:ssn]]
      )

    :rand.seed(:exsss, {11, 22, 33})
    before = :rand.export_seed()
    pairs = Trainer.sample_pairs(records, config)
    assert :rand.export_seed() == before
    assert pairs == Trainer.sample_pairs(records, config)
    assert length(pairs) == 50
    assert length(Enum.uniq(pairs)) == 50
    assert Enum.all?(pairs, fn {a, b} -> a < b end)
    refute pairs == Trainer.sample_pairs(records, %{config | seed: 48})
    small = Trainer.sample_pairs(Enum.take(records, 3), config)
    assert Enum.sort(small) == [{1, 2}, {1, 3}, {2, 3}]
  end

  test "all-null u remains a finite normalized distribution" do
    config = Config.new(comparisons: [TestModels.name_comparison()], u_sample_size: 10)
    u = Trainer.estimate_u([%{id: 1}, %{id: 2}], config)
    assert_in_delta Enum.sum(Map.values(u.family_name)), 1.0, 1.0e-12
    assert Enum.all?(Map.values(u.family_name), &(&1 >= 1.0e-6))
  end
end
