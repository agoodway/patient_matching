defmodule PatientMatching.NormalizeComparatorsTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Comparators, Normalize}

  test "normalizes a copy, handles invalid fields and preserves unusual sex values" do
    raw = %{
      id: {:file, 1},
      given_name: "  Anne--Marie   O'Neil! ",
      dob: "02/29/2024",
      phone: "+1 (212) 867-5309",
      ssn: "212-45-6789",
      zip: "02139-1234",
      sex: "female"
    }

    result = Normalize.record(raw)
    assert result.given_name == raw.given_name
    refute Map.has_key?(raw, :normalized)
    assert result.normalized.given_name == "ANNEMARIEONEIL"
    assert result.normalized.dob == %{year: 2024, month: 2, day: 29}
    assert result.normalized.phone == "2128675309"
    assert result.normalized.ssn == "212456789"
    assert result.normalized.zip == "02139"
    assert result.normalized.sex == "F"

    invalid =
      Normalize.record(%{
        id: 2,
        given_name: " !!! ",
        dob: "2023-02-29",
        phone: "123",
        ssn: "SSN-SECRET",
        zip: "12",
        sex: "other"
      }).normalized

    assert invalid.given_name == nil
    assert invalid.dob == nil
    assert invalid.phone == nil
    assert invalid.ssn == nil
    assert invalid.zip == nil
    assert invalid.sex == "OTHER"

    assert Normalize.record(%{id: 3, dob: ~D[2000-01-02]}).normalized.dob == %{
             year: 2000,
             month: 1,
             day: 2
           }

    assert Normalize.record(%{id: 4, dob: "2000-01-02"}).normalized.dob == %{
             year: 2000,
             month: 1,
             day: 2
           }

    assert Normalize.record(%{id: 5, sex: "male"}).normalized.sex == "M"
  end

  test "Jaro–Winkler matches standard examples including short inputs" do
    for {a, b, expected} <- [
          {"MARTHA", "MARHTA", 0.9611111111111111},
          {"DIXON", "DICKSONX", 0.8133333333333332},
          {"JELLYFISH", "SMELLYFISH", 0.8962962962962964},
          {"A", "AB", 0.85},
          {"A", "A", 1.0},
          {"A", "B", 0.0},
          {"", "A", 0.0}
        ] do
      assert_in_delta Comparators.jaro_winkler(a, b), expected, 1.0e-12
      assert_in_delta Comparators.jaro_winkler(b, a), expected, 1.0e-12
    end

    assert Comparators.jaro_winkler(nil, "A") == 0.0
  end

  test "classic American Soundex handles separators and duplicate codes" do
    for {name, code} <- [
          {"Robert", "R163"},
          {"Rupert", "R163"},
          {"Rubin", "R150"},
          {"Ashcraft", "A261"},
          {"Tymczak", "T522"},
          {"Pfister", "P236"},
          {"Honeyman", "H555"}
        ] do
      assert Comparators.soundex(name) == code
    end

    assert Comparators.soundex("") == nil
    assert Comparators.soundex(nil) == nil
    assert Comparators.soundex("123!") == nil
  end

  test "date and suffix helpers reject nil and distinguish year changes" do
    a = %{year: 2024, month: 2, day: 29}
    b = %{year: 2024, month: 3, day: 1}
    assert Comparators.within_days?(a, b, 1)
    refute Comparators.within_days?(a, b, 0)
    assert Comparators.within_days?("2024-02-29", ~D[2024-03-01], 1)
    assert Comparators.same_year_month?(a, %{a | day: 1})
    refute Comparators.same_year_month?(a, %{a | year: 2023})
    refute Comparators.within_days?(nil, b, 1)
    refute Comparators.same_year_month?(a, nil)
    assert Comparators.zip3_match?("02139", "02140")
    assert Comparators.phone_last7?("12125551212", "5551212")
    assert Comparators.ssn_last4?("123456789", "987656789")
    refute Comparators.zip3_match?(nil, nil)
    refute Comparators.phone_last7?("123", "123")
    refute Comparators.ssn_last4?(nil, "123456789")
    refute Comparators.exact?(nil, nil)
  end
end
