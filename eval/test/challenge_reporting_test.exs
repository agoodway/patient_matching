defmodule PatientMatchingEval.ChallengeReportingTest do
  use ExUnit.Case
  alias PatientMatching.{Model, Presets}
  alias PatientMatchingEval.Challenges

  test "information review does not count as finding the true pair" do
    model = %Model{config: Presets.patient_mpi()}

    case_data = %{
      "id" => "blank-same",
      "category" => "missing_identity",
      "variant" => "sparse",
      "same_person" => true,
      "expect" => "match_or_review",
      "left" => %{"id" => "left", "given_name" => "Maria", "dob" => "1980-06-10"},
      "right" => %{"id" => "right", "source" => "county"}
    }

    different = %{case_data | "id" => "blank-different", "same_person" => false}
    result = Challenges.evaluate([case_data, different], model)
    [same, different] = result.cases
    refute same["pass"]
    assert same["handling_pass"]
    assert same["outcome"] == "unblocked"
    assert same["information_status"] == "insufficient_identity"

    assert same["record_review"] == [
             %{id: "right", side: :right, reason: :insufficient_identity}
           ]

    assert different["pass"]
    assert result.groups["missing_identity/sparse"].found_with_review == 0
    assert result.groups["missing_identity/sparse"].information_review_cases == 2
    assert result.groups["missing_identity/sparse"].informationless_true_pairs == 1
    assert result.groups["missing_identity/sparse"].pair_expectation_failures == 1
    assert result.groups["missing_identity/sparse"].handling_failures == 0
  end

  test "a missed pair with usable identity is still a handling failure" do
    model = %Model{config: Presets.patient_mpi()}

    result =
      Challenges.evaluate(
        [
          %{
            "id" => "usable-missed",
            "category" => "missing_identity",
            "variant" => "sparse",
            "same_person" => true,
            "expect" => "match_or_review",
            "left" => %{"id" => "left", "given_name" => "Maria", "family_name" => "Garcia"},
            "right" => %{"id" => "right", "given_name" => "Robert", "family_name" => "Smith"}
          }
        ],
        model
      )

    [missed] = result.cases
    refute missed["pass"]
    refute missed["handling_pass"]
    assert missed["record_review"] == []
    assert result.groups["missing_identity/sparse"].handling_failures == 1
  end
end
