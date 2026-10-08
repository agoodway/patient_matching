defmodule PatientMatching.PolicyRegressionTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias PatientMatching.{Blocking, Normalize, Presets, Synthetic, TestModels, Trainer}

  test "training and MRN blocking use the configured normalization policy" do
    comparison = %{TestModels.name_comparison(true) | field: :mrn}

    config =
      PatientMatching.config(
        comparisons: [comparison],
        blocking: [[:mrn]],
        training_blocking: [[:family_name]],
        strip_mrn_leading_zeros: false
      )

    records = [
      %{id: 1, mrn: "007", family_name: "Smith"},
      %{id: 2, mrn: "7", family_name: "Smith"}
    ]

    model = PatientMatching.train(records, config, lambda: 0.1)
    assert model.term_frequencies.mrn == %{"007" => 0.5, "7" => 0.5}
    assert Trainer.pattern_counts(records, [{1, 2}], config) == %{{:else} => 1}

    assert Blocking.pairs(records, config.blocking, :dedupe_only, strip_mrn_leading_zeros: false) ==
             []

    assert Blocking.pairs(records, config.blocking, :dedupe_only) == [{1, 2}]
    assert Normalize.mrn("007", false) == "007"
    assert Normalize.mrn("HA000123", false) == "HA000123"
    assert Normalize.mrn(7, false) == "7"
  end

  test "oversized blocks report counts for every rule through dedupe and link" do
    records =
      for i <- 1..6,
          do: %{id: i, family_name: if(i <= 3, do: "Smith", else: "Jones"), given_name: "Ann"}

    rules = [[:family_name], [:given_name], [:phone]]
    model = TestModels.fixed()
    model = %{model | config: %{model.config | blocking: rules, max_block_size: 2}}

    log =
      capture_log(fn ->
        blocked = Blocking.candidates(records, rules, :dedupe_only, max_block_size: 2)
        assert blocked.dropped_blocks == 3
        assert blocked.dropped_blocks_by_rule == %{0 => 2, 1 => 1, 2 => 0}

        assert PatientMatching.dedupe(records, model).dropped_blocks_by_rule == %{
                 0 => 2,
                 1 => 1,
                 2 => 0
               }

        assert PatientMatching.link(Enum.take(records, 1), Enum.drop(records, 1), model).dropped_blocks_by_rule ==
                 %{0 => 2, 1 => 1, 2 => 0}
      end)

    assert log =~ "rule=0"
    assert log =~ "rule=1"
    refute log =~ "SMITH"
  end

  test "preserving MRN zeros prevents identifier overrides across public operations" do
    config = Presets.patient_mpi(strip_mrn_leading_zeros: false, u_sample_size: 1000, guards: [])
    records = Synthetic.patients(30, 0.2) |> Synthetic.unlabeled()
    model = PatientMatching.train(records, config)
    left = %{id: 1, source: "clinic", mrn: "HA000123"}
    right = %{id: 2, source: "clinic", mrn: "HA123"}
    assert PatientMatching.explain(left, right, model).reason == :scored
    assert PatientMatching.link([left], [right], model).matches == []
    assert PatientMatching.dedupe([left, right], model).clusters == []
    assert PatientMatching.link([left], [%{right | mrn: "HA000123"}], model).matches != []

    enabled = %{model | config: %{model.config | strip_mrn_leading_zeros: true}}
    assert PatientMatching.explain(left, right, enabled).reason == :mrn

    assert PatientMatching.dedupe([left, right], enabled).clusters == [
             %{root_id: 1, member_ids: [1, 2]}
           ]

    dumped = PatientMatching.dump(model)
    loaded = PatientMatching.load(dumped, config)
    assert PatientMatching.explain(left, right, loaded).reason == :scored
    assert_raise ArgumentError, fn -> PatientMatching.load(dumped, enabled.config) end
    assert_raise ArgumentError, fn -> PatientMatching.config(strip_mrn_leading_zeros: "false") end
  end

  test "common names and exact DOB without corroboration go to review and cannot chain" do
    model = TestModels.fixed()
    config = Presets.patient_mpi(common_name_frequency: 0.001)

    model = %{
      model
      | config: %{config | comparisons: model.comparisons, blocking: [[:family_name]]},
        term_frequencies: %{
          given_name: %{"MARIA" => 0.05, "ZEBULON" => 0.0001},
          family_name: %{"GARCIA" => 0.05}
        }
    }

    model = put_in(model.parameters.family_name.exact, %{m: 0.999, u: 0.000001})

    left = %{
      id: 1,
      given_name: "Maria",
      family_name: "Garcia",
      dob: "1985-04-12",
      sex: "F",
      zip: "77081",
      phone: "8325550148"
    }

    right = %{left | id: 2, zip: "77506", phone: "7135550159"}
    result = PatientMatching.link([left], [right], model)
    assert result.matches == []
    assert [%{guards: [:common_name_uncorroborated]}] = result.review
    assert PatientMatching.explain(left, right, model).guards == [:common_name_uncorroborated]

    bridge = %{left | id: 3, phone: right.phone}
    deduped = PatientMatching.dedupe([left, right, bridge], model)
    assert length(deduped.clusters) == 1
    assert length(hd(deduped.clusters).member_ids) == 2
    assert deduped.rejected_edges != []

    assert PatientMatching.link([left], [%{right | phone: left.phone}], model).matches != []
    rare_left = %{left | given_name: "Zebulon"}

    assert PatientMatching.link([rare_left], [%{right | given_name: "Zebulon"}], model).matches !=
             []

    mrn_left = Map.merge(left, %{source: "clinic", mrn: "123"})
    mrn_right = Map.merge(right, %{source: "clinic", mrn: "123"})
    assert [%{reason: :mrn}] = PatientMatching.link([mrn_left], [mrn_right], model).matches

    disabled = %{model | config: %{model.config | common_name_frequency: nil}}
    assert PatientMatching.link([left], [right], disabled).matches != []
    assert_raise ArgumentError, fn -> PatientMatching.config(common_name_frequency: 0) end
  end

  test "common-name policy remains active without TF scoring and survives serialization" do
    preset = Presets.patient_mpi(u_sample_size: 1000)

    comparisons =
      Enum.map(preset.comparisons, fn comparison ->
        %{comparison | levels: Enum.map(comparison.levels, &%{&1 | tf?: false})}
      end)

    config = %{preset | comparisons: comparisons}
    left = %{id: :a, given_name: "Maria", family_name: "Garcia", dob: "1985-04-12", zip: "77081"}
    right = %{left | id: :b, zip: "77506"}
    records = [left, right | Synthetic.patients(30) |> Synthetic.unlabeled()]
    model = PatientMatching.train(records, config)
    assert :common_name_uncorroborated in PatientMatching.explain(left, right, model).guards
    dumped = PatientMatching.dump(model)
    loaded = PatientMatching.load(dumped, config)
    assert :common_name_uncorroborated in PatientMatching.explain(left, right, loaded).guards

    assert_raise ArgumentError, fn ->
      PatientMatching.load(dumped, %{config | common_name_frequency: nil})
    end
  end

  test "model loading preserves legacy zero stripping and rejects a missing policy in new dumps" do
    model = TestModels.fixed(tf: true)
    data = PatientMatching.dump(model) |> Jason.decode!()
    legacy = data |> Map.put("version", 2) |> Map.delete("policies") |> Jason.encode!()
    assert PatientMatching.load(legacy, model.config).config.strip_mrn_leading_zeros
    preserving = Presets.patient_mpi(strip_mrn_leading_zeros: false)

    assert_raise ArgumentError, fn ->
      PatientMatching.load(legacy, %{
        model.config
        | strip_mrn_leading_zeros: preserving.strip_mrn_leading_zeros
      })
    end

    assert_raise ArgumentError, fn ->
      PatientMatching.load(Jason.encode!(Map.delete(data, "policies")), model.config)
    end
  end
end
