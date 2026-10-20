defmodule PatientMatching.PostprocessingSerializationTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Cluster, Presets, Synthetic, TestModels}

  test "dedupe forces within-file pairing and unions match edges only" do
    model = TestModels.fixed()
    model = put_in(model.config.blocking, [[fn _ -> :all end]])

    records = [
      %{id: 3, family_name: "Smith"},
      %{id: 1, family_name: "Smith"},
      %{id: 2, family_name: "Smith"},
      %{id: 4, family_name: "Smyth"},
      %{id: 5, family_name: "Other"}
    ]

    result = PatientMatching.dedupe(records, model, match_threshold: 0.4, review_threshold: 0.01)
    assert result.clusters == [%{root_id: 1, member_ids: [1, 2, 3]}]
    assert length(result.matches) == 3
    assert length(result.review) == 3
    assert result.non_match_count == 4
    assert Enum.all?(result.matches ++ result.review, &(&1.left_id < &1.right_id))

    assert Cluster.clusters([
             %{left_id: :a, right_id: :b},
             %{left_id: :c, right_id: :d},
             %{left_id: :b, right_id: :c}
           ]) == [%{root_id: :a, member_ids: [:a, :b, :c, :d]}]
  end

  test "greedy assignment keeps highest probability and never reuses either id" do
    pairs = [
      %{left_id: :a, right_id: :b, probability: 0.96},
      %{left_id: :a, right_id: :c, probability: 0.99},
      %{left_id: :d, right_id: :e, probability: 0.97},
      %{left_id: :c, right_id: :f, probability: 0.95}
    ]

    assert PatientMatching.assign(pairs) == [Enum.at(pairs, 1), Enum.at(pairs, 2)]
    assert PatientMatching.assign([]) == []
  end

  test "trained model dump/load reattaches functions and preserves pair probability" do
    config = Presets.patient_mpi(u_sample_size: 1000)
    records = Synthetic.patients(30, 0.2) |> Synthetic.unlabeled()
    model = PatientMatching.train(records, config)
    json = PatientMatching.dump(model)
    assert is_binary(json)
    data = Jason.decode!(json)
    assert data["version"] == 3
    assert is_list(data["comparisons"])
    loaded = PatientMatching.load(json, config)
    assert loaded.comparisons == model.comparisons
    assert loaded.parameters == model.parameters
    assert loaded.term_frequencies == model.term_frequencies
    assert loaded.trained == model.trained
    assert loaded.config == config
    before = PatientMatching.explain(hd(records), Enum.at(records, 30), model)
    after_load = PatientMatching.explain(hd(records), Enum.at(records, 30), loaded)
    assert_in_delta before.probability, after_load.probability, 1.0e-9

    assert PatientMatching.link(Enum.take(records, 30), Enum.drop(records, 30), loaded) ==
             PatientMatching.link(Enum.take(records, 30), Enum.drop(records, 30), model)
  end

  test "load rejects incompatible comparison config and corrupted probabilities" do
    model = TestModels.fixed(tf: true)
    json = PatientMatching.dump(model)

    assert_raise ArgumentError, fn ->
      PatientMatching.load(json, %{model.config | comparisons: []})
    end

    assert_raise ArgumentError, fn -> PatientMatching.load("not json", model.config) end
    data = Jason.decode!(json)

    assert_raise ArgumentError, fn ->
      PatientMatching.load(Jason.encode!(%{data | "lambda" => 0.0}), model.config)
    end

    assert_raise ArgumentError, fn ->
      PatientMatching.load(Jason.encode!(%{data | "version" => 99}), model.config)
    end
  end

  test "full-file planted-patient dedupe meets recall and precision gates" do
    labeled = Synthetic.patients()
    records = Synthetic.unlabeled(labeled)
    model = PatientMatching.train(records, Presets.patient_mpi())
    result = PatientMatching.dedupe(records, model)
    planted = Synthetic.planted_pairs(labeled)
    recalled = MapSet.new(result.matches ++ result.review, &{&1.left_id, &1.right_id})
    matches = MapSet.new(result.matches, &{&1.left_id, &1.right_id})
    recall = MapSet.size(MapSet.intersection(recalled, planted)) / MapSet.size(planted)
    precision = MapSet.size(MapSet.intersection(matches, planted)) / max(MapSet.size(matches), 1)
    assert recall >= 0.90, "recall was #{recall}"
    assert precision >= 0.95, "precision was #{precision}"
    assert result.clusters != []
  end

  describe "m prior metadata and signature" do
    setup do
      config = Presets.patient_mpi(u_sample_size: 1000)
      records = Synthetic.patients(30, 0.2) |> Synthetic.unlabeled()
      %{config: config, records: records}
    end

    test "dump/load preserves prior metadata", %{config: config, records: records} do
      model =
        PatientMatching.train(records, config,
          m_prior: %{given_name: %{exact: 40, nickname: 6}},
          m_prior_strength: 2,
          m_prior_base_weight: 5
        )

      loaded = PatientMatching.load(PatientMatching.dump(model), config)
      assert loaded.trained == model.trained
      assert loaded.trained.m_prior == %{given_name: 46}
      assert loaded.trained.m_prior_strength === 2.0
    end

    test "0.1.0-style dumps without prior keys load with defaults", %{
      config: config,
      records: records
    } do
      data = Jason.decode!(PatientMatching.dump(PatientMatching.train(records, config)))

      old =
        update_in(
          data["trained"],
          &Map.drop(&1, ["m_prior", "m_prior_strength", "m_prior_base_weight"])
        )

      loaded = PatientMatching.load(Jason.encode!(old), config)

      assert {loaded.trained.m_prior, loaded.trained.m_prior_strength,
              loaded.trained.m_prior_base_weight} == {%{}, 1.0, 10.0}
    end

    test "load rejects bad stored prior metadata", %{config: config, records: records} do
      data = Jason.decode!(PatientMatching.dump(PatientMatching.train(records, config)))

      for bad <- [
            %{"m_prior" => %{"zzz" => 1}},
            %{"m_prior" => %{"given_name" => -1}},
            %{"m_prior_strength" => -1},
            %{"m_prior_base_weight" => 0}
          ] do
        json = Jason.encode!(update_in(data["trained"], &Map.merge(&1, bad)))

        assert_raise ArgumentError, "invalid model dump or incompatible comparison config", fn ->
          PatientMatching.load(json, config)
        end
      end
    end

    test "comparison_signature matches the dump", %{config: config, records: records} do
      model = PatientMatching.train(records, config)
      sig = Jason.decode!(PatientMatching.dump(model))["comparisons"]
      assert PatientMatching.comparison_signature(model) == sig
      assert PatientMatching.comparison_signature(config) == sig

      assert_raise ArgumentError, fn ->
        PatientMatching.load(PatientMatching.dump(model), %{
          config
          | comparisons: tl(config.comparisons)
        })
      end
    end
  end
end
