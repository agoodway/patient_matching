defmodule PatientMatching.NormalizeFormatsTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Blocking, Comparators, Normalize, Placeholders}

  defp norm(record), do: Normalize.record(Map.put(record, :id, 1)).normalized

  test "dates accept common registration formats" do
    expected = %{year: 1987, month: 5, day: 3}

    for text <-
          ~w(1987-05-03 1987-5-3 1987/05/03 05/03/1987 5/3/1987 05-03-1987 5.3.1987 19870503 05031987) do
      assert Normalize.date(text) == expected, text
    end

    assert Normalize.date("1987-05-03T00:00:00Z") == expected
    assert Normalize.date("1987-05-03 14:22") == expected
    assert Normalize.date(~D[1987-05-03]) == expected
  end

  test "a first number over 12 is read as the day; ambiguous dates are month-first" do
    assert Normalize.date("25/12/1980") == %{year: 1980, month: 12, day: 25}
    assert Normalize.date("02/03/1980") == %{year: 1980, month: 2, day: 3}
  end

  test "impossible, ancient and future dates are nil" do
    for text <- ["13/13/1980", "1879-12-31", "2999-01-01", "1980-02-30", "-1980-01-02", "May 3"] do
      assert Normalize.date(text) == nil, text
    end
  end

  test "accents fold so precomposed, decomposed and plain spellings agree" do
    plain = norm(%{family_name: "Jimenez"}).family_name
    assert norm(%{family_name: "JIMÉNEZ"}).family_name == plain
    assert norm(%{family_name: "JIMÉNEZ"}).family_name == plain
    assert norm(%{family_name: "Muñoz"}).family_name == "MUNOZ"
    assert norm(%{family_name: "Strauß"}).family_name == "STRAUSS"
    assert norm(%{family_name: "Łukasz"}).family_name == "LUKASZ"
    assert Comparators.soundex(norm(%{family_name: "Álvarez"}).family_name) == "A416"
  end

  test "names drop spaces, hyphens and particles' spacing, and lift generational suffixes" do
    assert norm(%{family_name: "De La Cruz"}).family_name == "DELACRUZ"
    assert norm(%{family_name: "Smith-Jones"}).family_name == "SMITHJONES"
    assert norm(%{family_name: "O'Brien"}).family_name == "OBRIEN"

    jr = norm(%{given_name: "John", family_name: "Smith Jr."})
    assert {jr.family_name, jr.suffix} == {"SMITH", "JR"}
    assert norm(%{given_name: "John III", family_name: "Smith"}).suffix == "III"
    assert norm(%{family_name: "Smith 2nd"}).suffix == "II"
    assert norm(%{family_name: "Jr"}).family_name == "JR"
  end

  test "sex codes: unknowns and numeric codes are missing, other values are kept" do
    assert norm(%{sex: "Male"}).sex == "M"
    assert norm(%{sex: "f"}).sex == "F"

    for code <- ["U", "unknown", "UNK", "1", 2, ""] do
      assert norm(%{sex: code}).sex == nil, inspect(code)
    end

    assert norm(%{sex: "X"}).sex == "X"
  end

  test "phones drop country code and extensions" do
    assert norm(%{phone: "+1 (713) 867-5309"}).phone == "7138675309"
    assert norm(%{phone: "17138675309"}).phone == "7138675309"
    assert norm(%{phone: "713-867-5309 x204"}).phone == "7138675309"
    assert norm(%{phone: "713-867-5309 ext. 9"}).phone == "7138675309"
    assert norm(%{phone: 7_138_675_309}).phone == "7138675309"
    assert norm(%{phone: "867-5309"}).phone == "8675309"
  end

  test "ZIPs keep five digits and restore a lost leading zero" do
    assert norm(%{zip: "77036-1234"}).zip == "77036"
    assert norm(%{zip: "770361234"}).zip == "77036"
    assert norm(%{zip: "2139"}).zip == "02139"
    assert norm(%{zip: 2139}).zip == "02139"
    assert norm(%{zip: "21391234"}).zip == "02139"
  end

  test "SSNs: nine digits, last four kept apart, integers accepted" do
    assert norm(%{ssn: "212-45-6789"}).ssn == "212456789"
    assert norm(%{ssn: 212_456_789}).ssn == "212456789"
    last4 = norm(%{ssn: "6789"})
    assert {last4.ssn, last4.ssn_partial} == {nil, "6789"}
    assert Blocking.key(%{normalized: last4}, :ssn_last4) == "6789"
    assert norm(%{ssn: "912-70-1234"}).ssn == "912701234"
  end

  test "MRNs ignore leading zeros after any prefix, and integers are accepted" do
    assert norm(%{mrn: "007"}).mrn == norm(%{mrn: 7}).mrn
    assert norm(%{mrn: "HA000123"}).mrn == "HA123"
    assert norm(%{mrn: "ha-000-123"}).mrn == "HA123"
    assert norm(%{mrn: "000"}).mrn == "0"
  end

  test "placeholder identifiers are missing" do
    for ssn <-
          ~w(000000000 999999999 123456789 111111111 000-12-3456 666-12-3456 212-00-3456 212-45-0000) do
      assert norm(%{ssn: ssn}).ssn == nil, ssn
    end

    for phone <- ~w(0000000000 9999999999 7130000000 1234567890 713-555-1212) do
      assert norm(%{phone: phone}).phone == nil, phone
    end

    assert norm(%{zip: "00000"}).zip == nil
    assert norm(%{zip: "99999"}).zip == nil
    assert norm(%{dob: "1900-01-01"}).dob == nil
    assert norm(%{dob: "1980-01-01"}).dob == %{year: 1980, month: 1, day: 1}
  end

  test "placeholder and alias names are missing; real names beside them survive" do
    for given <- ["Baby Girl", "BABYGIRL", "BG", "Boy", "Baby Boy B", "Infant Girl", "Unknown"] do
      assert norm(%{given_name: given, family_name: "Garcia"})
             |> Map.take([:given_name, :family_name]) ==
               %{given_name: nil, family_name: "GARCIA"},
             given
    end

    for {given, family} <- [
          {"John", "Doe"},
          {"Jane", "Doe"},
          {"Trauma", "Alpha"},
          {"Unknown", "Male"},
          {"Unknown", "Unknown"}
        ] do
      n = norm(%{given_name: given, family_name: family})
      assert {n.given_name, n.family_name} == {nil, nil}, "#{given} #{family}"
    end

    assert norm(%{given_name: "Mike", family_name: "Doe"}).family_name == "DOE"
    assert norm(%{family_name: "Alpha"}).family_name == "ALPHA"
  end

  test "placeholder lists are configurable and can be disabled" do
    assert Normalize.record(%{id: 1, ssn: "123456789"}, %{}).normalized.ssn == "123456789"
    custom = Map.put(Placeholders.default(), :family_name, ["NOTGIVEN"])

    assert Normalize.record(%{id: 1, family_name: "Not Given"}, custom).normalized.family_name ==
             nil

    assert_raise ArgumentError, fn -> PatientMatching.config(placeholders: [:bad]) end
  end
end
