defmodule PatientMatching.Guards do
  @moduledoc """
  Rules that stop a pair from auto-matching, whatever its score.

  Fellegi–Sunter adds field evidence as if fields were independent. Family
  members break that: siblings, a parent and child, or twins share surname,
  address, phone and sometimes an SSN, so their scores can reach the match
  threshold even though another field shows they are different people. And
  a full name with a birth date, and nothing else, is not enough to tell two
  people apart in a large population.

  A guard is `{reason, fun, penalty}`: `fun` takes two normalized records
  (`record.normalized`) and returns true when the guard fires; `penalty` is
  subtracted from the pair's log2 weight. Penalties of fired guards add up.
  When any guard fires the probability is also capped just below the match
  threshold, so the pair can go to review but never auto-matches; the pair
  lists the reasons under `:guards`. A same-source MRN agreement does not
  override a guard. In `dedupe/3`, two clusters are not joined when a guard
  fires between any of their members.

  Conflicts (different people):

    * `:ssn_conflict` (10) - full SSNs more than one typo apart. An ITIN and
      an SSN are not compared: people move from one to the other.
    * `:dob_conflict` (30) - birth years more than one apart, unless an
      adjacent-digit transposition (1969 / 1996) or a one-digit typo within
      a decade (1987 / 1983) explains it.
    * `:generation_suffix` (10) - different suffixes (JR / SR, II / III).
    * `:twin` (10) - same birth date and family name, given names that are
      not variants of each other. A shared full SSN between adults clears it.
    * `:sex_and_given_name` (10) - recorded sexes and given names both differ.
    * `:birth_order` (30) - newborn labels with different birth orders
      (`BABY BOY A` / `BABY BOY B`).
    * `:newborn_dob` (10) - one record has a newborn label instead of a
      given name and the birth dates are neither equal nor one typo apart.
      Birth hospitals record a newborn's date exactly; a sibling's differs.

  Too little to auto-match on (penalty 0, review only):

    * `:missing_dob` - a DOB is missing on either side and full SSNs do not
      agree. Father and son share name and address; only DOB separates them.
    * `:jan1_uncorroborated` - both birth dates are January 1, often an
      assigned date for people born abroad without a birth record, and no
      SSN (full or last four), phone, ZIP or street agrees.

  The `PatientMatching.Presets.patient_mpi/1` preset uses `default/0`. Pass
  `guards: []` to disable them, or a modified list.
  """
  alias PatientMatching.{Comparators, Normalize}

  @doc "The default guards, in the order their reasons are reported."
  def default do
    [
      {:ssn_conflict, &ssn_conflict?/2, 10.0},
      {:dob_conflict, &dob_conflict?/2, 30.0},
      {:generation_suffix, &generation_suffix?/2, 10.0},
      {:twin, &twin?/2, 10.0},
      {:sex_and_given_name, &sex_and_given_name?/2, 10.0},
      {:birth_order, &birth_order?/2, 30.0},
      {:newborn_dob, &newborn_dob?/2, 10.0},
      {:missing_dob, &missing_dob?/2, 0.0},
      {:jan1_uncorroborated, &jan1_uncorroborated?/2, 0.0}
    ]
  end

  @doc "Guards that fire for two normalized records, as `{reason, penalty}`."
  def fired([], _a, _b), do: []

  def fired(guards, a, b),
    do: for({reason, fun, penalty} <- guards, fun.(a, b), do: {reason, penalty})

  @doc "Reasons of the guards that fire for two normalized records."
  def check(guards, a, b), do: guards |> fired(a, b) |> Enum.map(&elem(&1, 0))

  @doc "Validates a guard list."
  def validate!(guards) do
    unless is_list(guards) and Enum.all?(guards, &valid?/1),
      do:
        raise(
          ArgumentError,
          "guards must be a list of {atom, arity-two function, nonnegative penalty}"
        )

    guards
  end

  defp valid?({reason, fun, penalty}),
    do: is_atom(reason) and is_function(fun, 2) and is_number(penalty) and penalty >= 0

  defp valid?(_), do: false

  @doc "Both full SSNs (or both ITINs) present and more than one typo apart."
  def ssn_conflict?(a, b) do
    s1 = a[:ssn]
    s2 = b[:ssn]

    s1 != nil and s2 != nil and s1 != s2 and itin?(s1) == itin?(s2) and
      not Comparators.one_edit?(s1, s2)
  end

  @doc "Birth years more than one apart and not explained by a typo."
  def dob_conflict?(a, b) do
    with %{year: y1} = d1 <- a[:dob],
         %{year: y2} = d2 <- b[:dob] do
      gap = abs(y1 - y2)

      gap > 1 and not Comparators.dob_transposed?(d1, d2) and
        not (gap < 10 and Comparators.dob_one_edit?(d1, d2))
    else
      _ -> false
    end
  end

  @doc "Both names carry a generational suffix and they differ (JR / SR, II / III)."
  def generation_suffix?(a, b),
    do: a[:suffix] != nil and b[:suffix] != nil and a[:suffix] != b[:suffix]

  @doc "Same birth date and family name, but given names that are not variants of each other."
  def twin?(a, b) do
    a[:dob] != nil and a[:dob] == b[:dob] and same_family?(a, b) and
      different_given?(a[:given_name], b[:given_name]) and
      not (Comparators.exact?(a[:ssn], b[:ssn]) and adult?(a[:dob]))
  end

  @doc "Recorded sexes differ and so do given names."
  def sex_and_given_name?(a, b) do
    a[:sex] in ["M", "F"] and b[:sex] in ["M", "F"] and a[:sex] != b[:sex] and
      different_given?(a[:given_name], b[:given_name])
  end

  @doc "Newborn labels with different birth orders."
  def birth_order?(a, b),
    do: a[:birth_order] != nil and b[:birth_order] != nil and a[:birth_order] != b[:birth_order]

  @doc "A newborn-label record against a different birth date."
  def newborn_dob?(a, b) do
    (a[:newborn] == true or b[:newborn] == true) and a[:dob] != nil and b[:dob] != nil and
      a[:dob] != b[:dob] and not Comparators.dob_one_edit?(a[:dob], b[:dob]) and
      not Comparators.month_day_swapped?(a[:dob], b[:dob]) and
      not Comparators.within_days?(a[:dob], b[:dob], 1)
  end

  @doc "A DOB is missing on either side and full SSNs do not agree."
  def missing_dob?(a, b),
    do: (a[:dob] == nil or b[:dob] == nil) and not Comparators.exact?(a[:ssn], b[:ssn])

  @doc "Both DOBs are January 1 and nothing beyond name, birth date and sex agrees."
  def jan1_uncorroborated?(a, b),
    do: jan1?(a[:dob]) and jan1?(b[:dob]) and uncorroborated?(a, b)

  @doc "Nothing beyond name, birth date and sex agrees."
  def uncorroborated?(a, b) do
    not (Comparators.exact?(a[:ssn], b[:ssn]) or
           Comparators.exact?(last4(a), last4(b)) or
           Comparators.exact?(a[:phone], b[:phone]) or
           Comparators.exact?(a[:zip], b[:zip]) or
           Comparators.exact?(a[:street], b[:street]))
  end

  @doc "Both given names present and not plausibly the same name."
  def different_given?(g1, g2) when is_binary(g1) and is_binary(g2) do
    not (g1 == g2 or Comparators.nickname?(g1, g2) or Comparators.name_part?(g1, g2) or
           Comparators.initial?(g1, g2) or Comparators.jaro_winkler(g1, g2) >= 0.85)
  end

  def different_given?(_, _), do: false

  defp same_family?(a, b) do
    f1 = a[:family_name]
    f2 = b[:family_name]
    f1 != nil and f2 != nil and (f1 == f2 or Comparators.compound?(f1, f2))
  end

  defp last4(record) do
    case record[:ssn] do
      nil -> record[:ssn_partial]
      ssn -> String.slice(ssn, -4, 4)
    end
  end

  defp jan1?(%{month: 1, day: 1}), do: true
  defp jan1?(_), do: false

  defp itin?(<<"9", _::binary>>), do: true
  defp itin?(_), do: false

  defp adult?(%{year: y, month: m, day: d}) do
    today = Normalize.today()
    Date.diff(today, Date.new!(y, m, d)) >= 18 * 365
  end
end
