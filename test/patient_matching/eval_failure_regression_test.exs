defmodule PatientMatching.EvalFailureRegressionTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Guards, Normalize, Presets, Scorer, TestModels}

  defp n(record), do: Normalize.record(record).normalized

  test "identity-free records go to a separate information review queue without guessing a pair" do
    model = TestModels.fixed()
    known = %{id: :known, given_name: "Maria", family_name: "Garcia", dob: "1980-06-10"}
    blank = %{id: :blank, source: "county"}
    result = PatientMatching.link([known], [blank], model)
    assert result.record_review == [%{id: :blank, side: :right, reason: :insufficient_identity}]
    assert result.matches == []
    assert result.review == []
    assert result.non_match_count == 0
  end

  test "information review uses normalized values and preserves side when ids overlap" do
    model = TestModels.fixed()
    blank = %{id: 1, given_name: "UNKNOWN", dob: "1900-01-01", ssn: "999999999"}
    result = PatientMatching.link([blank], [%{id: 1, sex: "F"}], model)

    assert result.record_review == [
             %{id: 1, side: :left, reason: :insufficient_identity},
             %{id: 1, side: :right, reason: :insufficient_identity}
           ]

    identified = [%{id: 1, source: "county", mrn: "42"}, %{id: 2, phone: "7132345678"}]
    assert PatientMatching.link(identified, [], model).record_review == []
  end

  test "dedupe returns information review records without inventing a cluster" do
    result = PatientMatching.dedupe([%{id: :blank}], TestModels.fixed())
    assert result.record_review == [%{id: :blank, side: :single, reason: :insufficient_identity}]
    assert result.clusters == []
    assert result.matches == []
  end

  test "two unnamed newborns sharing a birthday and household cannot auto-merge" do
    a = %{
      id: 1,
      given_name: "BABY GIRL",
      family_name: "Johnson",
      dob: "2026-09-02",
      phone: "7132345678",
      zip: "77005"
    }

    b = %{a | id: 2}
    model = %{TestModels.fixed() | config: Presets.patient_mpi()}
    assert :newborn_identity in Guards.check(model.config.guards, n(a), n(b))
    assert Scorer.score(Normalize.record(a), Normalize.record(b), model).probability < 0.95

    refute :newborn_identity in Guards.check(
             model.config.guards,
             n(Map.merge(a, %{source: "hospital", mrn: "a"})),
             n(Map.merge(b, %{source: "hospital", mrn: "a"}))
           )
  end

  test "a borrowed SSN cannot overcome different names and incompatible dates in the same year" do
    a = %{id: 1, given_name: "Michael", family_name: "Smith", dob: "1981-10-15", ssn: "421561008"}
    b = %{a | id: 2, given_name: "Patricia", dob: "1981-06-17"}
    assert :shared_ssn_conflict in Guards.check(Guards.default(), n(a), n(b))

    refute :shared_ssn_conflict in Guards.check(
             Guards.default(),
             n(a),
             n(%{b | given_name: "Michael"})
           )

    refute :shared_ssn_conflict in Guards.check(
             Guards.default(),
             n(a),
             n(%{b | dob: "1981-10-16"})
           )
  end

  test "unknown adult name variants keep an ambiguity guard without a twin penalty" do
    a = %{id: 1, given_name: "Alexander", family_name: "Williams", dob: "1998-04-18"}
    b = %{a | id: 2, given_name: "Sasha"}
    fired = Guards.fired(Guards.default(), n(a), n(b))
    assert {:adult_name_ambiguity, 0.0} in fired
    refute {:twin, 10.0} in fired
    child = %{a | dob: "2023-04-18"}
    assert {:twin, 10.0} in Guards.fired(Guards.default(), n(child), n(%{b | dob: child.dob}))
  end

  test "matching names with an incompatible DOB need corroboration even when frequencies shift" do
    a = %{id: 1, given_name: "Mohammad", family_name: "Khan", dob: "1980-06-10", zip: "77072"}
    b = %{a | id: 2, dob: "1980-06-27", zip: "77494"}
    model = %{TestModels.fixed() | config: Presets.patient_mpi()}
    assert {:name_dob_ambiguity, 0.0} in Guards.fired_for_model(model, n(a), n(b))

    refute {:name_dob_ambiguity, 0.0} in Guards.fired_for_model(
             model,
             n(a),
             n(%{b | dob: "1980-06-11"})
           )

    refute {:name_dob_ambiguity, 0.0} in Guards.fired_for_model(
             model,
             n(Map.put(a, :phone, "7132345678")),
             n(Map.put(b, :phone, "7132345678"))
           )
  end

  test "a child's copied guarantor SSN does not veto the same name, birthday and contact" do
    a = %{
      id: 1,
      given_name: "Olivia",
      family_name: "Malave",
      dob: "2020-05-09",
      ssn: "810636378",
      phone: "3467021286",
      zip: "77083"
    }

    b = %{a | id: 2, ssn: "183593391"}
    refute Guards.ssn_conflict?(n(a), n(b))
    assert Guards.ssn_conflict?(n(a), n(%{b | given_name: "Julia"}))
    assert Guards.ssn_conflict?(n(a), n(%{b | family_name: "Malave Garcia"}))
    adult = %{a | dob: "1980-05-09"}
    assert Guards.ssn_conflict?(n(adult), n(%{b | dob: adult.dob}))
  end

  test "adult name edits retain review without an agreeing identifier and contact" do
    a = %{id: 1, given_name: "EBN", family_name: "Ellis", dob: "1961-07-27"}
    b = %{a | id: 2, given_name: "BEN"}
    assert Guards.adult_name_ambiguity?(n(a), n(b))
    assert Guards.adult_name_ambiguity?(n(%{a | given_name: "OE"}), n(%{b | given_name: "JOE"}))

    assert Guards.adult_name_ambiguity?(
             n(%{a | given_name: "ANNIKA"}),
             n(%{b | given_name: "ASHLEY"})
           )
  end

  test "a name typo with an agreeing SSN fragment and phone can clear adult ambiguity" do
    a = %{
      id: 1,
      given_name: "ZACHARIAH",
      family_name: "Fincher",
      dob: "2001-05-27",
      ssn: "1070",
      phone: "2815885128"
    }

    b = %{a | id: 2, given_name: "ZWCHARIAH", ssn: "628651070"}
    refute Guards.adult_name_ambiguity?(n(a), n(b))
    assert Guards.adult_name_ambiguity?(n(Map.delete(a, :ssn)), n(b))
    assert Guards.adult_name_ambiguity?(n(Map.delete(a, :phone)), n(b))
    assert Guards.adult_name_ambiguity?(n(%{a | ssn: "1071"}), n(b))
  end

  test "adult twins with a one-letter name deletion and household contact retain review" do
    a = %{id: 1, given_name: "AN", family_name: "Nguyen", dob: "1980-04-18", phone: "7132345678"}
    b = %{a | id: 2, given_name: "LAN"}
    assert Guards.adult_name_ambiguity?(n(a), n(b))
  end

  test "an impossible all-zero SSN fragment cannot clear name ambiguity or supply identity" do
    a = %{
      id: 1,
      given_name: "AN",
      family_name: "Nguyen",
      dob: "1980-04-18",
      phone: "7132345678",
      ssn: "0000"
    }

    b = %{a | id: 2, given_name: "LAN"}
    assert n(a).ssn_partial == nil
    assert Guards.adult_name_ambiguity?(n(a), n(b))
    assert Normalize.record(a, %{}).normalized.ssn_partial == nil
    result = PatientMatching.dedupe([%{id: :blank, ssn: "0000"}], TestModels.fixed())
    assert result.record_review == [%{id: :blank, side: :single, reason: :insufficient_identity}]
  end

  test "different adult twin names do not bypass review as a one-letter substitution" do
    a = %{id: 1, given_name: "ANN", family_name: "Smith", dob: "1980-04-18", phone: "7132345678"}
    b = %{a | id: 2, given_name: "ANA"}
    assert Guards.adult_name_ambiguity?(n(a), n(b))
    assert Guards.adult_name_ambiguity?(n(%{a | given_name: "LEA"}), n(%{b | given_name: "LEO"}))
  end
end
