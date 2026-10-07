defmodule PatientMatching.Normalize do
  @moduledoc false
  @fields [:source, :mrn, :ssn, :given_name, :family_name, :dob, :sex, :zip, :phone, :street]

  @doc "Adds a normalized copy of patient fields, retaining the original map values."
  def record(record) when is_map(record) do
    normalized = Map.new(@fields, &{&1, value(&1, Map.get(record, &1))})
    # Custom comparisons may use additional fields.
    extra = Map.drop(record, [:id, :normalized | @fields])

    Map.put(
      record,
      :normalized,
      Map.merge(Map.new(extra, fn {k, v} -> {k, string(v)} end), normalized)
    )
  end

  @doc "Normalizes a field according to its patient-field rules, treating invalid values as nil."
  def value(:dob, value), do: date(value)
  def value(:phone, value), do: digits(value, 7, :at_least)
  def value(:ssn, value), do: digits(value, 9, :exact)

  def value(:zip, value) do
    case digits(value, 5, :at_least) do
      nil -> nil
      digits -> String.slice(digits, 0, 5)
    end
  end

  def value(:sex, value) do
    case string(value) do
      "MALE" -> "M"
      "FEMALE" -> "F"
      other -> other
    end
  end

  def value(_, value), do: string(value)

  @doc "Trims, uppercases, removes punctuation and collapses whitespace; empty text becomes nil."
  def string(value) when is_binary(value) do
    case value
         |> String.trim()
         |> String.upcase()
         |> String.replace(~r/[^\p{L}\p{N}\s]/u, "")
         |> String.replace(~r/\s+/u, " ")
         |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  def string(_), do: nil

  @doc "Parses Date structs, year/month/day maps, ISO dates or MM/DD/YYYY strings; invalid dates become nil."
  def date(%{year: y, month: m, day: d}) when is_integer(y) and is_integer(m) and is_integer(d) do
    case Date.new(y, m, d) do
      {:ok, _date} -> %{year: y, month: m, day: d}
      _ -> nil
    end
  end

  def date(value) when is_binary(value) do
    value = String.trim(value)

    case Date.from_iso8601(value) do
      {:ok, date} ->
        date(date)

      _ ->
        case Regex.run(~r/^(\d{2})\/(\d{2})\/(\d{4})$/, value) do
          [_, m, d, y] ->
            date(%{
              year: String.to_integer(y),
              month: String.to_integer(m),
              day: String.to_integer(d)
            })

          _ ->
            nil
        end
    end
  end

  def date(_), do: nil

  defp digits(value, n, mode) when is_binary(value) do
    text = String.replace(value, ~r/[^0-9]/, "")

    if (mode == :exact and byte_size(text) == n) or (mode == :at_least and byte_size(text) >= n),
      do: text
  end

  defp digits(_, _, _), do: nil
end
