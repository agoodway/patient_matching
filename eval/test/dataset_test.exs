defmodule PatientMatchingEval.DatasetTest do
  use ExUnit.Case
  alias PatientMatchingEval.{Population, Records, Reference, Rng}

  test "synthetic parents have appropriate roles, including male-only households" do
    Rng.seed(2026)
    population = Population.build(Reference.load(), 4000)
    children = Enum.filter(population.people, &(&1.mother || &1.father))
    assert Enum.any?(children, &(&1.mother == nil && &1.father != nil))

    for child <- children do
      if child.mother, do: assert(population.by_id[child.mother].sex == "F")
      if child.father, do: assert(population.by_id[child.father].sex == "M")
      if child.mother == nil, do: assert(child.birth_surname_of_mother == nil)
    end
  end

  test "father-only children inherit surname, origin, phone and guarantor; newborns use child surname" do
    Rng.seed(2026)
    ref = Reference.load()
    population = Population.build(ref, 4000)

    child =
      Enum.find(
        population.people,
        &(&1.mother == nil && &1.father != nil && Population.age(&1.dob, Population.today()) < 2)
      )

    father = population.by_id[child.father]
    assert child.origin == father.origin

    assert Population.legal_surname(child) ==
             Population.legal_surname(father) |> String.split([" ", "-"]) |> hd()

    father = %{father | cells: [{father.dob, "7132346789"}], ssn: {:ssn, "421567891"}}
    child = %{child | insured: true, cells: [{child.dob, nil}]}
    source = hd(ref.sources)

    errors =
      source["errors"]
      |> Map.merge(%{
        "unknown_patient" => 0.0,
        "newborn_placeholder" => 1.0,
        "stale_contact_years" => 0,
        "phone_work" => 0.0,
        "phone_placeholder" => 0.0,
        "phone_typo" => 0.0,
        "ssn_guarantor_minor" => 1.0,
        "ssn_typo" => 0.0
      })

    source =
      source
      |> Map.put("errors", errors)
      |> Map.put("capture", %{
        "phone" => 1.0,
        "ssn" => 1.0,
        "sex" => 1.0,
        "zip" => 1.0,
        "street" => 1.0
      })
      |> Map.put("reach", %{"insured" => 1.0, "uninsured" => 1.0})

    {records, truth} =
      Records.build(%{ref | sources: [source]}, %{
        people: [child],
        by_id: %{child.pid => child, father.pid => father}
      })

    assert records != []

    for {record, t} <- Enum.zip(records, truth) do
      assert "phone_of_parent" in t["tags"]
      assert "ssn_guarantor" in t["tags"]
      assert String.replace(record["phone"], ~r/\D/, "") == "7132346789"
      assert String.replace(record["ssn"], ~r/\D/, "") == "421567891"

      if "newborn_placeholder" in t["tags"],
        do: assert(record["family_name"] == Population.legal_surname(child))
    end

    assert Enum.any?(truth, &("newborn_placeholder" in &1["tags"]))
  end

  test "benchmark populations can request exact counts without dangling household links" do
    Rng.seed(2027)
    population = Population.build(Reference.load(), 10000, exact: true)
    assert length(population.people) == 10000

    for p <- population.people, role <- [:mother, :father, :spouse, :twin, :junior_of], p[role] do
      assert Map.has_key?(population.by_id, p[role])
    end
  end

  test "twins have exactly the same date of birth" do
    Rng.seed(2027)
    population = Population.build(Reference.load(), 10000)

    for p <- population.people, p.twin do
      assert population.by_id[p.twin].dob == p.dob
    end
  end
end
