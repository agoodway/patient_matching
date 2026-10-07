defmodule PatientMatching.TrainingIntegrationTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Blocking, Presets, Synthetic, TestModels, Trainer}

  test "preset trains without labels and retrieves planted patients at required quality" do
    labeled = Synthetic.patients()
    records = Synthetic.unlabeled(labeled)
    config = Presets.patient_mpi()
    assert config.link_type == :link_only
    assert config.training_blocking == [[:dob_year]]
    model = PatientMatching.train(records, config)
    # Use link on two disjoint files so no cluster implementation is needed at this stage.
    {left, right} = Enum.split(records, 200)
    result = PatientMatching.link(left, right, model)
    found = MapSet.new(result.matches ++ result.review, &{&1.left_id, &1.right_id})
    planted = Synthetic.planted_pairs(labeled)
    recall = MapSet.size(MapSet.intersection(found, planted)) / MapSet.size(planted)
    match_edges = MapSet.new(result.matches, &{&1.left_id, &1.right_id})

    precision =
      MapSet.size(MapSet.intersection(match_edges, planted)) / max(MapSet.size(match_edges), 1)

    assert recall >= 0.90, "recall was #{recall}"
    assert precision >= 0.95, "precision was #{precision}"
    assert model.trained.lambda_source == :deterministic
    assert model.lambda >= 1.0e-6 and model.lambda <= 0.5
  end

  test "preset blocks fewer than 50,000 pairs on 1,000 random people and retains planted block-sharing pairs" do
    records = Synthetic.patients(1000, 0.0) |> Synthetic.unlabeled()
    config = Presets.patient_mpi()
    assert length(Blocking.pairs(records, config.blocking, :dedupe_only)) < 50_000
    labeled = Synthetic.patients()

    pairs =
      labeled
      |> Synthetic.unlabeled()
      |> Blocking.pairs(config.blocking, :dedupe_only)
      |> MapSet.new()

    assert MapSet.subset?(Synthetic.planted_pairs(labeled), pairs)
  end

  test "lambda counts deterministic unions once and divides by prediction pair budget and recall" do
    records = [
      %{id: 1, given_name: "Amy", family_name: "Smith", dob: "2000-01-01", ssn: "123456789"},
      %{id: 2, given_name: "Amy", family_name: "Smith", dob: "2000-01-01", ssn: "123456789"},
      %{id: 3, given_name: "Ben", family_name: "Jones", dob: "2000-01-01"}
    ]

    config = Presets.patient_mpi(blocking: [[fn _ -> :all end]], lambda_recall: 0.8)
    assert_in_delta Trainer.estimate_lambda(records, config), 1 / 3 / 0.8, 1.0e-12
    assert Trainer.estimate_lambda(records, %{config | lambda_recall: 0.1}) == 0.5
    assert Trainer.estimate_lambda([%{id: 1}, %{id: 2}], config) == 1.0e-6
  end

  test "train clamps fixed lambda, records its source and accepts m_init" do
    config = Presets.patient_mpi(u_sample_size: 500)
    records = Synthetic.patients(30, 0.2) |> Synthetic.unlabeled()

    model =
      PatientMatching.train(records, config,
        lambda: 2.0,
        m_init: %{sex: %{exact: 0.8, else: 0.2}}
      )

    assert model.lambda == 0.5
    assert model.trained.lambda_source == :fixed
    assert model.config == config
    assert model.comparisons == config.comparisons
    assert PatientMatching.train(records, config, lambda: 0.0).lambda == 1.0e-6
    assert_raise ArgumentError, fn -> PatientMatching.train(records, config, lambda: "bad") end
  end

  test "training rejects empty, singleton, duplicates and absent prediction/training candidates with counts" do
    config = Presets.patient_mpi()

    for records <- [[], [%{id: 1}], [%{id: 1}, %{id: 1}], [%{id: 1}, %{id: 2}]] do
      assert_raise ArgumentError, fn -> PatientMatching.train(records, config) end
    end

    records = [%{id: 1, family_name: "Smith"}, %{id: 2, family_name: "Smith"}]
    bad = %{TestModels.fixed().config | training_blocking: [[:dob_year]]}
    assert_raise ArgumentError, ~r/0.*2/, fn -> PatientMatching.train(records, bad) end
    config = Presets.patient_mpi(blocking: [[:ssn]], training_blocking: [[fn _ -> :all end]])
    assert_raise ArgumentError, ~r/0.*2/, fn -> PatientMatching.train(records, config) end
  end

  test "public explain handles raw maps and custom comparisons without a preset" do
    model = TestModels.fixed()

    assert_in_delta PatientMatching.explain(
                      %{id: 1, family_name: "Smith"},
                      %{id: 2, family_name: "Smith"},
                      model
                    ).probability,
                    8 / 17,
                    1.0e-12

    assert PatientMatching.config(comparisons: model.comparisons).comparisons == model.comparisons
  end
end
