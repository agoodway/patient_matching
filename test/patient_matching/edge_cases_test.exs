defmodule PatientMatching.EdgeCasesTest do
  use ExUnit.Case, async: true

  alias PatientMatching.{
    Comparators,
    Comparison,
    Config,
    Level,
    Normalize,
    Presets,
    TestModels,
    Trainer
  }

  test "punctuation at text boundaries leaves no surrounding whitespace or false non-null strings" do
    normalized =
      Normalize.record(%{id: 1, given_name: "---   Amy ---", family_name: "! !"}).normalized

    assert normalized.given_name == "AMY"
    assert normalized.family_name == nil
  end

  test "date validation includes manually constructed invalid Date structs" do
    invalid = %Date{year: 2023, month: 2, day: 29}
    assert Normalize.date(invalid) == nil
    refute Comparators.within_days?(invalid, ~D[2023-03-01], 1)
  end

  test "SSN suffix requires exactly nine digits on both sides" do
    refute Comparators.ssn_last4?("1234567890", "9876547890")
    refute Comparators.ssn_last4?("abcdefghi", "zyxwvfghi")
    assert Comparators.ssn_last4?("123456789", "987656789")
  end

  test "malformed comparison structs are rejected by config construction" do
    for comparison <- [
          %Comparison{
            field: nil,
            levels: [%Level{name: :null, null_level?: true}, %Level{name: :else}]
          },
          %Comparison{
            field: 10,
            levels: [%Level{name: :null, null_level?: true}, %Level{name: :else}]
          },
          %Comparison{
            field: :x,
            levels: [
              %Level{name: :null, null_level?: true},
              %Level{name: nil, match?: fn _, _ -> true end},
              %Level{name: :else}
            ]
          },
          %Comparison{
            field: :x,
            levels: [%Level{name: :null, null_level?: true}, %Level{name: :else, tf?: nil}]
          }
        ] do
      assert_raise ArgumentError, fn -> Config.new(comparisons: [comparison]) end
    end
  end

  test "DOB levels: distant dates are else, typos and swaps have their own levels, same month is year-month" do
    dob = Enum.find(Presets.patient_mpi().comparisons, &(&1.field == :dob))
    left = Normalize.record(%{id: 1, dob: "2000-02-10"})
    assert Comparison.run(dob, left, Normalize.record(%{id: 2, dob: "2002-03-11"})).name == :else

    assert Comparison.run(dob, left, Normalize.record(%{id: 2, dob: "2001-02-10"})).name ==
             :one_digit

    assert Comparison.run(dob, left, Normalize.record(%{id: 2, dob: "2000-10-02"})).name ==
             :month_day_swapped

    assert Comparison.run(dob, left, Normalize.record(%{id: 3, dob: "2000-02-27"})).name ==
             :same_year_month
  end

  test "unseen exact TF values count as seen once in training; common values reduce evidence" do
    model = TestModels.fixed(tf: true)

    unseen =
      PatientMatching.explain(
        %{id: 1, family_name: "UNSEEN"},
        %{id: 2, family_name: "UNSEEN"},
        model
      )

    assert_in_delta hd(unseen.tf_adjustments).adjustment,
                    :math.log(0.1 / 0.001) / :math.log(2),
                    1.0e-9

    model = put_in(model.term_frequencies.family_name["SMITH"], 0.5)

    common =
      PatientMatching.explain(
        %{id: 1, family_name: "SMITH"},
        %{id: 2, family_name: "SMITH"},
        model
      )

    assert hd(common.tf_adjustments).adjustment < 0
  end

  test "all-null scoring is prior-only even with TF and sampler handles zero/one record" do
    score = PatientMatching.explain(%{id: 1}, %{id: 2}, TestModels.fixed(tf: true))
    assert_in_delta score.probability, 0.1, 1.0e-12
    assert score.tf_adjustments == []
    assert Trainer.sample_pairs([], Presets.patient_mpi()) == []
    assert Trainer.sample_pairs([%{id: 1}], Presets.patient_mpi()) == []
  end
end
