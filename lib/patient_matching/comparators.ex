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
