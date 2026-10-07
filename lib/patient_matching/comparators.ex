defmodule PatientMatching.Comparators do
  @moduledoc false
  alias PatientMatching.Normalize

  @doc "Returns true for equal non-nil values."
  def exact?(a, b), do: a != nil and b != nil and a == b

  @doc "Jaro–Winkler with prefix cap 4 and scaling 0.1; prefix boost applies when Jaro > 0.7."
  def jaro_winkler(a, b) when is_binary(a) and is_binary(b) do
    left = String.graphemes(a)
    right = String.graphemes(b)
    n = length(left)
    m = length(right)
    window = max(div(max(n, m), 2) - 1, 0)

    {matched_left, used} =
      left
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, &match_character(&1, &2, right, window))

    matches = length(matched_left)

    if matches == 0 do
      0.0
    else
      matched_right =
        right
        |> Enum.with_index()
        |> Enum.filter(fn {_, j} -> MapSet.member?(used, j) end)
        |> Enum.map(&elem(&1, 0))

      transpositions =
        Enum.zip(Enum.reverse(matched_left), matched_right)
        |> Enum.count(fn {x, y} -> x != y end)
        |> Kernel./(2)

      jaro = (matches / n + matches / m + (matches - transpositions) / matches) / 3

      prefix =
        Enum.zip(left, right)
        |> Enum.take(4)
        |> Enum.take_while(fn {x, y} -> x == y end)
        |> length()

      if jaro > 0.7, do: jaro + prefix * 0.1 * (1 - jaro), else: jaro
    end
  end

  def jaro_winkler(_, _), do: 0.0

  @doc "Computes classic four-character American Soundex; inputs without letters return nil."
  def soundex(value) when is_binary(value) do
    case value |> String.upcase() |> String.replace(~r/[^A-Z]/, "") |> String.graphemes() do
      [] ->
        nil

      [first | rest] ->
        {codes, _} = Enum.reduce(rest, {[], sound_code(first)}, &soundex_digit/2)

        first <>
          (codes
           |> Enum.reverse()
           |> Enum.join()
           |> String.pad_trailing(3, "0")
           |> String.slice(0, 3))
    end
  end

  def soundex(_), do: nil

  @doc "Tests parsed date distance against an inclusive nonnegative day limit."
  def within_days?(a, b, n) when is_integer(n) and n >= 0 do
    with %{year: y1, month: m1, day: d1} <- Normalize.date(a),
         %{year: y2, month: m2, day: d2} <- Normalize.date(b) do
      abs(Date.diff(Date.new!(y1, m1, d1), Date.new!(y2, m2, d2))) <= n
    else
      _ -> false
    end
  end

  @doc "Tests whether two valid dates have the same year and month."
  def same_year_month?(a, b) do
    with %{year: y, month: m} <- Normalize.date(a),
         %{year: ^y, month: ^m} <- Normalize.date(b),
         do: true,
         else: (_ -> false)
  end

  @doc "Compares the first three characters of normalized five-digit ZIP codes."
  def zip3_match?(a, b), do: suffix_or_prefix(a, b, 5, 3, :prefix)
  @doc "Compares the last seven characters of normalized phone numbers."
  def phone_last7?(a, b), do: suffix_or_prefix(a, b, 7, 7, :suffix)

  @doc "Compares the last four digits, requiring both SSNs to contain exactly nine digits."
  def ssn_last4?(a, b) when is_binary(a) and is_binary(b) do
    Regex.match?(~r/^[0-9]{9}$/, a) and Regex.match?(~r/^[0-9]{9}$/, b) and
      suffix_or_prefix(a, b, 9, 4, :suffix)
  end

  def ssn_last4?(_, _), do: false

  @doc "One given name is a known nickname of the other (BOB / ROBERT, PACO / FRANCISCO)."
  def nickname?(a, b), do: PatientMatching.Nicknames.nickname?(a, b)

  @doc "The shorter name (at least `min` letters) starts the longer one: JOSE / JOSELUIS."
  def prefix?(a, b, min \\ 3)

  def prefix?(a, b, min) when is_binary(a) and is_binary(b) do
    {short, long} = if byte_size(a) <= byte_size(b), do: {a, b}, else: {b, a}
    short != long and byte_size(short) >= min and String.starts_with?(long, short)
  end

  def prefix?(_, _, _), do: false

  @doc """
  The shorter family name (at least four letters) begins or ends the longer:
  compound, hyphenated and particle surnames (GARCIA / GARCIALOPEZ, CRUZ /
  DELACRUZ, JONES / SMITHJONES).
  """
  def compound?(a, b) when is_binary(a) and is_binary(b) do
    {short, long} = if byte_size(a) <= byte_size(b), do: {a, b}, else: {b, a}

    short != long and byte_size(short) >= 4 and
      (String.starts_with?(long, short) or String.ends_with?(long, short))
  end

  def compound?(_, _), do: false

  @doc """
  The shorter given name (at least three letters) begins or ends the longer:
  middle names entered in the given field (JOSE / JOSELUIS, LAN / THILAN).
  """
  def name_part?(a, b) when is_binary(a) and is_binary(b) do
    {short, long} = if byte_size(a) <= byte_size(b), do: {a, b}, else: {b, a}

    short != long and byte_size(short) >= 3 and
      (String.starts_with?(long, short) or String.ends_with?(long, short))
  end

  def name_part?(_, _), do: false

  @doc "One name is a single letter that starts the other."
  def initial?(<<c::utf8>>, <<c::utf8, _::binary>>), do: true
  def initial?(<<c::utf8, _::binary>>, <<c::utf8>>), do: true
  def initial?(_, _), do: false

  @doc "Two {given, family} tuples with the names entered in each other's fields."
  def swapped_names?({g1, f1}, {g2, f2}) when is_binary(g1) and is_binary(f1),
    do: g1 != f1 and g1 == f2 and f1 == g2

  def swapped_names?(_, _), do: false

  @doc "Same year with month and day exchanged (DD/MM entered as MM/DD)."
  def month_day_swapped?(%{year: y, month: m1, day: d1}, %{year: y, month: m2, day: d2}),
    do: m1 != d1 and m1 == d2 and d1 == m2

  def month_day_swapped?(_, _), do: false

  @doc "Dates whose YYYYMMDD digits differ by one substitution or one adjacent transposition."
  def dob_one_edit?(%{} = a, %{} = b) when a != b, do: one_edit?(ymd(a), ymd(b))
  def dob_one_edit?(_, _), do: false

  @doc "Dates whose YYYYMMDD digits differ by exactly one adjacent transposition."
  def dob_transposed?(%{} = a, %{} = b) when a != b, do: transposed?(ymd(a), ymd(b))
  def dob_transposed?(_, _), do: false

  defp transposed?(a, b) do
    case differences(a, b) do
      [i, j] when j == i + 1 ->
        :binary.at(a, i) == :binary.at(b, j) and :binary.at(a, j) == :binary.at(b, i)

      _ ->
        false
    end
  end

  defp differences(a, b) do
    for {x, y, i} <- Enum.zip([:binary.bin_to_list(a), :binary.bin_to_list(b), 0..byte_size(a)]),
        x != y,
        do: i
  end

  @doc "Equal-length strings differing by one substitution or one adjacent transposition."
  def one_edit?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: length(differences(a, b)) == 1 or transposed?(a, b)

  def one_edit?(_, _), do: false

  @doc "SSN tuples `{ssn, last4_only}`: full SSNs are equal."
  def ssn_exact?({a, _}, {b, _}), do: exact?(a, b)

  @doc "SSN tuples: full SSNs differ by one digit or one adjacent transposition."
  def ssn_one_edit?({a, _}, {b, _}), do: one_edit?(a, b)

  @doc "SSN tuples: last four digits agree, from a full SSN or a last-four-only value."
  def ssn_tuple_last4?(a, b), do: exact?(last4(a), last4(b))

  defp last4({ssn, _}) when is_binary(ssn), do: String.slice(ssn, -4, 4)
  defp last4({nil, partial}), do: partial

  @doc "Contact tuples `{zip, phone, street}`: phone and ZIP both agree."
  def phone_and_zip?({z1, p1, _}, {z2, p2, _}), do: exact?(p1, p2) and exact?(z1, z2)
  @doc "Contact tuples: phone agrees."
  def same_phone?({_, p1, _}, {_, p2, _}), do: exact?(p1, p2)
  @doc "Contact tuples: street and ZIP both agree."
  def street_and_zip?({z1, _, s1}, {z2, _, s2}), do: exact?(s1, s2) and exact?(z1, z2)
  @doc "Contact tuples: ZIP agrees."
  def same_zip?({z1, _, _}, {z2, _, _}), do: exact?(z1, z2)

  @doc "Contact tuples: same ZIP3 or same last seven phone digits."
  def contact_near?({z1, p1, _}, {z2, p2, _}), do: zip3_match?(z1, z2) or phone_last7?(p1, p2)

  defp ymd(%{year: y, month: m, day: d}),
    do:
      Integer.to_string(y) <>
        String.pad_leading(Integer.to_string(m), 2, "0") <>
        String.pad_leading(Integer.to_string(d), 2, "0")

  defp match_character({char, i}, {matches, used}, right, window) do
    j =
      right
      |> Enum.with_index()
      |> Enum.find_value(fn {other, j} ->
        if abs(i - j) <= window and char == other and not MapSet.member?(used, j), do: j
      end)

    if j == nil, do: {matches, used}, else: {[char | matches], MapSet.put(used, j)}
  end

  defp soundex_digit(letter, {codes, previous}) do
    code = sound_code(letter)

    cond do
      letter in ["H", "W"] -> {codes, previous}
      code == "0" -> {codes, code}
      code == previous -> {codes, code}
      true -> {[code | codes], code}
    end
  end

  defp suffix_or_prefix(a, b, minimum, length, position) when is_binary(a) and is_binary(b) do
    start = if position == :prefix, do: 0, else: -length

    byte_size(a) >= minimum and byte_size(b) >= minimum and
      String.slice(a, start, length) == String.slice(b, start, length)
  end

  defp suffix_or_prefix(_, _, _, _, _), do: false

  defp sound_code(letter) do
    cond do
      letter in ~w(B F P V) -> "1"
      letter in ~w(C G J K Q S X Z) -> "2"
      letter in ~w(D T) -> "3"
      letter == "L" -> "4"
      letter in ~w(M N) -> "5"
      letter == "R" -> "6"
      true -> "0"
    end
  end
end
