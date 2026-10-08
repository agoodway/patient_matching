defmodule PatientMatching.Normalize do
  @moduledoc false
  alias PatientMatching.{Placeholders, Street}

  @fields [:source, :mrn, :ssn, :given_name, :family_name, :dob, :sex, :zip, :phone, :street]
  @suffixes %{
    "JR" => "JR",
    "SR" => "SR",
    "II" => "II",
    "2ND" => "II",
    "III" => "III",
    "3RD" => "III",
    "IV" => "IV",
    "4TH" => "IV"
  }
  @unknown_sex ~w(U UNK UNKNOWN N NA A)
  @min_year 1880
  # Letters that canonical decomposition leaves intact.
  @folds [
    {"ß", "SS"},
    {"ẞ", "SS"},
    {"Ø", "O"},
    {"ø", "O"},
    {"Æ", "AE"},
    {"æ", "AE"},
    {"Œ", "OE"},
    {"œ", "OE"},
    {"Ł", "L"},
    {"ł", "L"},
    {"Đ", "D"},
    {"đ", "D"},
    {"Þ", "TH"},
    {"þ", "TH"},
    {"ı", "I"}
  ]

  @doc """
  Adds a normalized copy of patient fields, retaining the original map values.
  Placeholder values (see `PatientMatching.Placeholders`) become nil.
  """
  def record(record, placeholders \\ :default, strip_mrn_leading_zeros \\ true)

  def record(record, placeholders, strip_mrn_leading_zeros) when is_map(record) do
    lists = if is_map(placeholders), do: placeholders, else: Placeholders.default()
    {given, given_suffix} = name(Map.get(record, :given_name), :given)
    {family, family_suffix} = name(Map.get(record, :family_name))
    {ssn, ssn_partial} = ssn(Map.get(record, :ssn))

    alias? = Placeholders.alias?(given, family, lists)

    normalized =
      %{
        source: string(Map.get(record, :source)),
        mrn: mrn(Map.get(record, :mrn), strip_mrn_leading_zeros),
        ssn: ssn,
        ssn_partial: ssn_partial,
        given_name: if(alias?, do: nil, else: given),
        family_name: if(alias?, do: nil, else: family),
        suffix: family_suffix || given_suffix,
        birth_order: record |> Map.get(:given_name) |> letters() |> Placeholders.birth_order(),
        newborn: record |> Map.get(:given_name) |> letters() |> Placeholders.newborn?(),
        dob: date(Map.get(record, :dob)),
        sex: value(:sex, Map.get(record, :sex)),
        zip: value(:zip, Map.get(record, :zip)),
        phone: value(:phone, Map.get(record, :phone)),
        street: street(Map.get(record, :street))
      }
      |> Map.new(fn {field, value} ->
        {field, if(Placeholders.placeholder?(field, value, lists), do: nil, else: value)}
      end)

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
  def value(:mrn, value), do: mrn(value)
  def value(:ssn, value), do: value |> ssn() |> elem(0)

  def value(:given_name, value), do: value |> name(:given) |> elem(0)
  def value(:family_name, value), do: value |> name() |> elem(0)

  def value(:phone, value) do
    with text when is_binary(text) <- text(value),
         [number | _] <- String.split(text, ~r/(x|ext|extension|#)/i, parts: 2) do
      case String.replace(number, ~r/[^0-9]/, "") do
        <<"1", rest::binary-10>> -> rest
        digits when byte_size(digits) >= 7 -> digits
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  def value(:zip, value) do
    case digits(value) do
      digits when byte_size(digits) in [4, 8] -> String.slice("0" <> digits, 0, 5)
      digits when byte_size(digits) >= 5 -> String.slice(digits, 0, 5)
      _ -> nil
    end
  end

  def value(:sex, value) do
    case string(value) do
      sex when sex in ["M", "MALE"] -> "M"
      sex when sex in ["F", "FEMALE"] -> "F"
      sex when sex in @unknown_sex -> nil
      nil -> nil
      other -> if Regex.match?(~r/^[0-9]+$/, other), do: nil, else: other
    end
  end

  def value(:street, value), do: street(value)
  def value(_, value), do: string(value)

  @doc """
  Street line in USPS Publication 28 standard form: suffixes and directionals
  abbreviated by position (`123 NORTH MAIN STREET` = `123 N MAIN ST`, while
  `RIDGE AVE` keeps its name), one `UNIT` marker after the street for every
  unit designator (`APT 4`, `#4` and `4TH FLOOR` are `UNIT 4`), and `PO BOX`,
  `RR` and `HC` box lines. The address is not validated.
  """
  defdelegate street(value), to: Street, as: :normalize

  @doc ~S|Splits a normalized street at its unit marker: `{"12 OAK ST", "4"}`; the unit is nil when absent.|
  defdelegate street_unit(street), to: Street, as: :unit

  @doc "Folds accents, uppercases, drops apostrophes, turns other punctuation into spaces and collapses whitespace; empty text becomes nil."
  def string(value) do
    case text(value) do
      nil ->
        nil

      text ->
        case text
             |> fold()
             |> String.upcase()
             |> String.replace(~r/['’`]/u, "")
             |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
             |> String.trim() do
          "" -> nil
          text -> text
        end
    end
  end

  @doc "Removes diacritics: JOSÉ, JOSÉ (decomposed) and JOSE are equal."
  def fold(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{M}/u, "")
    |> then(fn text -> Enum.reduce(@folds, text, fn {a, b}, t -> String.replace(t, a, b) end) end)
  end

  @doc """
  Splits a name into its letters (spaces, hyphens and particles removed, so
  `DE LA CRUZ` equals `DELACRUZ` and `SMITH-JONES` equals `SMITHJONES`) and a
  generational suffix taken from the last token. For given names, single
  letters after the first token are middle initials and are dropped
  (`JEREMY S` equals `JEREMY`).
  """
  def name(value, kind \\ :family) do
    case string(value) do
      nil ->
        {nil, nil}

      text ->
        {tokens, suffix} = text |> String.split(" ") |> split_suffix()
        tokens = if kind == :given, do: drop_initials(tokens), else: tokens

        case tokens |> Enum.join() |> String.replace(~r/\P{L}/u, "") do
          "" -> {nil, suffix}
          name -> {name, suffix}
        end
    end
  end

  defp split_suffix(tokens) when length(tokens) > 1 do
    case Map.fetch(@suffixes, List.last(tokens)) do
      {:ok, suffix} -> {Enum.drop(tokens, -1), suffix}
      :error -> {tokens, nil}
    end
  end

  defp split_suffix(tokens), do: {tokens, nil}

  defp drop_initials([first | rest]), do: [first | Enum.reject(rest, &(String.length(&1) == 1))]
  defp drop_initials([]), do: []

  defp ssn(value) do
    case digits(value) do
      <<_::binary-9>> = ssn -> {ssn, nil}
      <<_::binary-4>> = last4 -> {nil, last4}
      _ -> {nil, nil}
    end
  end

  @doc "Alphanumeric MRN; strips leading zeros after letter prefixes by default, or preserves them when false."
  def mrn(value, strip_leading_zeros \\ true) do
    case string(value) do
      nil ->
        nil

      text ->
        compact = String.replace(text, " ", "")

        normalized =
          if strip_leading_zeros,
            do: Regex.replace(~r/^(\p{L}*)0+(?=[0-9A-Z])/u, compact, "\\1"),
            else: compact

        case normalized do
          "" -> nil
          mrn -> mrn
        end
    end
  end

  @doc """
  Parses dates, returning `%{year:, month:, day:}` or nil. Accepts Date-like
  structs and maps, ISO dates and datetimes, `YYYY/MM/DD`, `YYYYMMDD`,
  `MMDDYYYY`, and month-first `M/D/YYYY` with `/`, `-` or `.` separators.
  A first number over 12 is read as the day (`25/12/1980`). Dates before
  1880 or after today are nil.
  """
  def date(%{year: y, month: m, day: d}) when is_integer(y) and is_integer(m) and is_integer(d) do
    with {:ok, date} <- Date.new(y, m, d),
         true <- y >= @min_year and Date.compare(date, today()) != :gt do
      %{year: y, month: m, day: d}
    else
      _ -> nil
    end
  end

  def date(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      match = Regex.run(~r/^(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})(?:[T ].*)?$/, value) ->
        [_, y, m, d] = match
        ymd(y, m, d)

      match = Regex.run(~r/^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4})$/, value) ->
        [_, a, b, y] = match
        if int(a) > 12 and int(b) <= 12, do: ymd(y, b, a), else: ymd(y, a, b)

      match = Regex.run(~r/^(\d{4})(\d{2})(\d{2})$/, value) ->
        [_, y, m, d] = match
        ymd(y, m, d) || mdy_compact(value)

      true ->
        nil
    end
  end

  def date(_), do: nil

  defp mdy_compact(<<m::binary-2, d::binary-2, y::binary-4>>), do: ymd(y, m, d)

  defp ymd(y, m, d), do: date(%{year: int(y), month: int(m), day: int(d)})

  defp int(text), do: String.to_integer(text)

  defp digits(value) do
    case text(value) do
      nil -> nil
      text -> String.replace(text, ~r/[^0-9]/, "")
    end
  end

  defp letters(value) do
    case string(value) do
      nil -> nil
      text -> String.replace(text, " ", "")
    end
  end

  @doc "Today's date; dates after it are invalid."
  def today, do: Date.utc_today()

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_), do: nil
end
