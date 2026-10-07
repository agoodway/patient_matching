defmodule PatientMatching.Synthetic do
  @moduledoc false

  # Exact expected counts from a known mixture; no production training code is used.
  def patterns(m, u, lambda, sample_size \\ 10_000_000) do
    fields = m |> Map.keys() |> Enum.sort()
    choices = Enum.map(fields, fn field -> m[field] |> Map.keys() |> Enum.sort() end)

    choices
    |> cartesian()
    |> Map.new(fn levels ->
      mp = Enum.zip(fields, levels) |> Enum.reduce(1.0, fn {f, l}, p -> p * m[f][l] end)
      up = Enum.zip(fields, levels) |> Enum.reduce(1.0, fn {f, l}, p -> p * u[f][l] end)
      {List.to_tuple(levels), round(sample_size * (lambda * mp + (1 - lambda) * up))}
    end)
  end

  @given ~w(ALICE BRIAN CAROL DAVID EMILY FRANK GRACE HENRY ISABEL JACK KAREN LUCAS MARTHA NATHAN OLIVIA PETER QUINN RACHEL SAMUEL TESSA)
  @family ~w(SMITH JOHNSON WILLIAMS BROWN JONES GARCIA MILLER DAVIS RODRIGUEZ MARTINEZ HERNANDEZ LOPEZ GONZALEZ WILSON ANDERSON THOMAS TAYLOR MOORE JACKSON MARTIN LEE PEREZ THOMPSON WHITE HARRIS SANCHEZ CLARK RAMIREZ LEWIS ROBINSON WALKER YOUNG ALLEN KING WRIGHT SCOTT TORRES NGUYEN HILL FLORES GREEN ADAMS NELSON BAKER HALL RIVERA CAMPBELL MITCHELL CARTER ROBERTS)

  def patients(count \\ 200, duplicate_fraction \\ 0.15, seed \\ 19) do
    state = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})

    {people, _} =
      Enum.map_reduce(1..count, state, fn id, state ->
        {draws, state} =
          Enum.map_reduce(
            [length(@given), length(@family), 60, 12, 28, 20, 10_000_000, 999_999_999, 2, 4],
            state,
            fn n, state -> :rand.uniform_s(n, state) end
          )

        [given, family, year, month, day, zip, phone, ssn, sex, missing] = draws

        record = %{
          id: id,
          person_id: id,
          source: "synthetic-a",
          mrn: "A#{id}",
          given_name: Enum.at(@given, given - 1),
          family_name: Enum.at(@family, family - 1),
          dob: Date.new!(1940 + year, month, day),
          zip: Integer.to_string(10_000 + zip),
          phone: "212" <> (phone |> Integer.to_string() |> String.pad_leading(7, "0")),
          ssn:
            if(missing == 1,
              do: nil,
              else: ssn |> Integer.to_string() |> String.pad_leading(9, "0")
            ),
          sex: if(sex == 1, do: "M", else: "F")
        }

        {record, state}
      end)

    clones =
      people
      |> Enum.take(round(count * duplicate_fraction))
      |> Enum.with_index()
      |> Enum.map(fn {record, i} ->
        clone = %{record | id: count + i + 1, source: "synthetic-b", mrn: "B#{i}"}

        case rem(i, 4) do
          0 -> %{clone | given_name: String.slice(clone.given_name, 0..-2//1) <> "X"}
          1 -> %{clone | dob: Date.add(clone.dob, 1)}
          2 -> %{clone | zip: nil}
          3 -> %{clone | phone: String.slice(clone.phone, -7, 7)}
        end
      end)

    people ++ clones
  end

  def unlabeled(records), do: Enum.map(records, &Map.delete(&1, :person_id))

  def planted_pairs(records) do
    for a <- records,
        b <- records,
        a.id < b.id,
        a.person_id == b.person_id,
        into: MapSet.new(),
        do: {a.id, b.id}
  end

  defp cartesian([]), do: [[]]
  defp cartesian([choices | rest]), do: for(a <- choices, b <- cartesian(rest), do: [a | b])
end
