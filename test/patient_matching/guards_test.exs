defmodule PatientMatching.GuardsTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Cluster, Comparators, Guards, Normalize, Presets, Scorer, TestModels}

  defp n(record), do: Normalize.record(Map.put(record, :id, 1)).normalized

  test "child twins include adjacent dates while a same-child date error remains unguarded" do
    a = %{given_name: "Alex", family_name: "Sample", dob: "2018-01-10", phone: "2025550101"}
    assert Guards.child_twin?(n(a), n(%{a | given_name: "Robin", dob: "2018-01-11"}))
    refute Guards.child_twin?(n(a), n(%{a | dob: "2018-01-11"}))
  end

  test "household lookalikes require similar nonvariant names, different dates and shared contact" do
    a = %{given_name: "Arianna", family_name: "Sample", dob: "2018-01-10", phone: "2025550101"}
    b = %{a | given_name: "Adrianna", dob: "2019-03-12"}
    assert Guards.household_lookalike?(n(a), n(b))
    refute Guards.household_lookalike?(n(a), n(%{b | phone: "2025550102"}))
    refute Guards.household_lookalike?(n(a), n(%{b | given_name: "Arianna"}))
    refute Guards.household_lookalike?(n(a), n(%{b | dob: "2018-01-11"}))

    refute Guards.household_lookalike?(
             n(%{a | given_name: "Robert"}),
             n(%{b | given_name: "Bob"})
           )
  end

  test "SSN conflict ignores typos and ITIN/SSN changes" do
    refute Guards.ssn_conflict?(n(%{ssn: "212456789"}), n(%{ssn: "212456788"}))
    refute Guards.ssn_conflict?(n(%{ssn: "212456789"}), n(%{ssn: "212457689"}))
    refute Guards.ssn_conflict?(n(%{ssn: "912784455"}), n(%{ssn: "640225871"}))
    assert Guards.ssn_conflict?(n(%{ssn: "212456789"}), n(%{ssn: "640225871"}))
    refute Guards.ssn_conflict?(n(%{ssn: "212456789"}), n(%{}))
  end

  test "DOB conflict separates generations but forgives typos" do
    assert Guards.dob_conflict?(n(%{dob: "1960-05-10"}), n(%{dob: "1990-05-10"}))
    assert Guards.dob_conflict?(n(%{dob: "1980-12-03"}), n(%{dob: "2012-05-14"}))
    refute Guards.dob_conflict?(n(%{dob: "1958-09-12"}), n(%{dob: "1985-09-12"}))
    refute Guards.dob_conflict?(n(%{dob: "1987-03-15"}), n(%{dob: "1983-03-15"}))
    refute Guards.dob_conflict?(n(%{dob: "1987-03-15"}), n(%{dob: "1988-07-01"}))
  end

  test "twins: same DOB and surname, unrelated given names, unless adults share a full SSN" do
    a = %{given_name: "Jose", family_name: "Garcia", dob: "1990-04-04"}
    assert Guards.twin?(n(a), n(%{a | given_name: "Maria"}))
    refute Guards.twin?(n(a), n(%{a | given_name: "Jose Luis"}))
    refute Guards.twin?(n(a), n(%{a | given_name: "Pepe"}))
    adult = Map.put(a, :ssn, "212456789")
    refute Guards.twin?(n(adult), n(%{adult | given_name: "Henry"}))
  end

  test "siblings: same surname, unrelated given names and incompatible DOBs, unless a full SSN agrees" do
    a = %{given_name: "Victor", family_name: "Ruelas", dob: "2018-04-08", phone: "3468854076"}
    assert Guards.sibling?(n(a), n(%{a | given_name: "Jairo", dob: "2017-12-14"}))
    refute Guards.sibling?(n(a), n(%{a | given_name: "Jairo"}))
    refute Guards.sibling?(n(a), n(%{a | given_name: "Vic", dob: "2017-12-14"}))
    refute Guards.sibling?(n(a), n(%{a | given_name: "Jairo", dob: "2018-04-09"}))
    refute Guards.sibling?(n(a), n(%{a | given_name: "Jairo", dob: "2018-08-04"}))

    refute Guards.sibling?(
             n(a),
             n(%{a | family_name: "Lopez", given_name: "Jairo", dob: "2017-12-14"})
           )

    refute Guards.sibling?(n(a), n(%{a | given_name: nil, dob: "2017-12-14"}))
    ssn = Map.put(a, :ssn, "212456789")
    refute Guards.sibling?(n(ssn), n(%{ssn | given_name: "Jairo", dob: "2017-12-14"}))
  end

  test "suffixes, birth order and missing DOB" do
    assert Guards.generation_suffix?(n(%{family_name: "Smith Jr"}), n(%{family_name: "Smith Sr"}))
    refute Guards.generation_suffix?(n(%{family_name: "Smith Jr"}), n(%{family_name: "Smith"}))
    assert Guards.birth_order?(n(%{given_name: "Baby Boy A"}), n(%{given_name: "Baby Boy B"}))
    refute Guards.birth_order?(n(%{given_name: "Baby Boy A"}), n(%{given_name: "Baby Boy"}))
    assert Guards.missing_dob?(n(%{dob: "1958-02-11"}), n(%{}))
    refute Guards.missing_dob?(n(%{ssn: "212456789"}), n(%{ssn: "212456789"}))
  end

  test "newborn labels must agree on the birth date" do
    baby = n(%{given_name: "Baby Girl", family_name: "Lent", dob: "2014-02-15"})
    assert baby.newborn

    assert Guards.newborn_dob?(
             baby,
             n(%{given_name: "Bailey", family_name: "Lent", dob: "2015-07-02"})
           )

    refute Guards.newborn_dob?(
             baby,
             n(%{given_name: "Bailey", family_name: "Lent", dob: "2014-02-16"})
           )

    refute Guards.newborn_dob?(
             n(%{given_name: "Ann", dob: "2014-02-15"}),
             n(%{given_name: "Ann", dob: "2015-07-02"})
           )
  end

  test "Jan-1 birthdays need something beyond name and DOB" do
    a = %{given_name: "Lan", family_name: "Nguyen", dob: "1962-01-01", zip: "77072"}
    assert Guards.jan1_uncorroborated?(n(a), n(%{a | zip: "77036"}))
    refute Guards.jan1_uncorroborated?(n(a), n(a))

    refute Guards.jan1_uncorroborated?(
             n(%{a | dob: "1962-03-01"}),
             n(%{a | dob: "1962-03-01", zip: "77036"})
           )
  end

  test "a fired guard subtracts its penalty and caps probability below the match threshold" do
    model = TestModels.fixed()
    guard = {:always, fn _, _ -> true end, 3.0}
    guarded = put_in(model.config.guards, [guard])
    a = Normalize.record(%{id: 1, family_name: "Rare"})
    b = Normalize.record(%{id: 2, family_name: "Rare"})
    plain = Scorer.score(a, b, model)
    scored = Scorer.score(a, b, guarded)
    assert scored.guards == [:always]
    assert_in_delta scored.weight, plain.weight - 3.0, 1.0e-9
    assert scored.probability < model.config.match_threshold
    assert Scorer.score(a, b, guarded, match_threshold: 0.5).probability < 0.5
  end

  test "an MRN agreement does not override a guard" do
    model = put_in(TestModels.fixed().config.guards, [{:always, fn _, _ -> true end, 0.0}])
    a = Normalize.record(%{id: 1, source: "c", mrn: "7", family_name: "Alpha"})
    b = Normalize.record(%{id: 2, source: "c", mrn: "007", family_name: "Alpha"})
    scored = Scorer.score(a, b, model)
    assert scored.reason == :mrn_conflict
    assert scored.probability < 0.95
  end

  test "guarded clustering refuses joins that put conflicting records together" do
    pairs = [
      %{left_id: :b1, right_id: :b2, probability: 0.99},
      %{left_id: :b2, right_id: :b3, probability: 0.98}
    ]

    conflict? = fn x, y -> MapSet.new([x, y]) == MapSet.new([:b1, :b3]) end
    {clusters, rejected} = Cluster.guarded(pairs, conflict?)
    assert clusters == [%{root_id: :b1, member_ids: [:b1, :b2]}]
    assert rejected == [Enum.at(pairs, 1)]
  end

  test "dedupe with the preset keeps a father and son apart through a missing-DOB record" do
    config = Presets.patient_mpi(u_sample_size: 1000)

    base = %{
      given_name: "Calvin",
      family_name: "Smith",
      sex: "M",
      zip: "77051",
      phone: "7138675309"
    }

    records = [
      Map.merge(base, %{id: "b1", dob: "1958-02-11"}),
      Map.merge(base, %{id: "b2"}),
      Map.merge(base, %{id: "b3", dob: "1984-02-29"})
    ]

    model =
      PatientMatching.train(
        (records ++ PatientMatching.Synthetic.patients(60))
        |> PatientMatching.Synthetic.unlabeled(),
        config
      )

    result = PatientMatching.dedupe(records, model)
    assert result.clusters == []
  end

  test "comparators for name parts, nicknames, swaps and DOB typos" do
    assert Comparators.name_part?("THILAN", "LAN")
    assert Comparators.name_part?("JOSELUIS", "JOSE")
    refute Comparators.name_part?("AL", "ALAN")
    assert Comparators.compound?("GARCIALOPEZ", "GARCIA")
    assert Comparators.compound?("DELACRUZ", "CRUZ")
    assert Comparators.nickname?("BOB", "ROBERT")
    assert Comparators.nickname?("BOB", "ROB")
    assert Comparators.swapped_names?({"MINH", "NGUYEN"}, {"NGUYEN", "MINH"})
    refute Comparators.swapped_names?({"LEE", "LEE"}, {"LEE", "LEE"})

    assert Comparators.month_day_swapped?(%{year: 1980, month: 3, day: 7}, %{
             year: 1980,
             month: 7,
             day: 3
           })

    assert Comparators.dob_one_edit?(%{year: 1980, month: 3, day: 7}, %{
             year: 1980,
             month: 3,
             day: 8
           })

    refute Comparators.dob_one_edit?(%{year: 1980, month: 3, day: 7}, %{
             year: 1980,
             month: 3,
             day: 7
           })

    assert Comparators.ssn_tuple_last4?({"212456789", nil}, {nil, "6789"})

    assert Comparators.phone_and_zip?(
             {"77036", "7138675309", nil},
             {"77036", "7138675309", "1 MAIN"}
           )
  end
end
