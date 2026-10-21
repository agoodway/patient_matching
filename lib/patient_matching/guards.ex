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
      an SSN are not compared: people move from one to the other. Children
      with the same full name, DOB and phone or street/ZIP are exempt because
      a guarantor's SSN can appear on their records.
    * `:dob_conflict` (30) - birth years more than one apart, unless an
      adjacent-digit transposition (1969 / 1996) or a one-digit typo within
      a decade (1987 / 1983) explains it.
    * `:generation_suffix` (10) - different suffixes (JR / SR, II / III).
    * `:twin` (10) - children with birth dates at most one day apart and the same family name, but
      given names that are not variants of each other.
    * `:sibling` (10) - the same family name with unrelated given names and
      incompatible birth dates, and no shared full SSN. Siblings share
      surname, phone and address; `:dob_conflict` misses those born less
      than two years apart.
    * `:sex_and_given_name` (10) - recorded sexes and given names both differ.
    * `:birth_order` (30) - newborn labels with different birth orders
      (`BABY BOY A` / `BABY BOY B`).
    * `:newborn_dob` (10) - one record has a newborn label instead of a
      given name and the birth dates are neither equal nor one typo apart.
      Birth hospitals record a newborn's date exactly; a sibling's differs.

  Too little to auto-match on (penalty 0, review only):

    * `:household_lookalike` - similar but different, nonvariant given names,
      the same surname, birth dates more than one day apart and a shared phone
      or street/ZIP.
    * `:household_name_conflict` - unrelated household names and a one-edit
      birth date difference greater than one day, unless a full SSN agrees.
    * `:adult_name_ambiguity` - adults with the same DOB and family name but
      unrelated given names. An unfamiliar alias remains possible. A shared
      full SSN clears this guard. A one-edit name typo also clears it when
      both an SSN fragment and phone agree; household contact alone cannot
      disambiguate two real names separated by an edit.
    * `:newborn_identity` - either record uses a newborn label without an
      agreeing MRN from the same source. Household contact cannot identify
      which baby a record belongs to.
    * `:shared_ssn_conflict` - a full SSN agrees, but unrelated given names
      and incompatible birth dates suggest a borrowed identifier.
    * `:name_dob_ambiguity` - exact full names with incompatible birth dates
      and no corroborating identifier or contact.
    * `:missing_dob` - a DOB is missing on either side and full SSNs do not
      agree. Father and son share name and address; only DOB separates them.
    * `:jan1_uncorroborated` - both birth dates are January 1, often an
      assigned date for people born abroad without a birth record, and no
      SSN (full or last four), phone, ZIP or street agrees.

  The `PatientMatching.Presets.patient_mpi/1` preset uses `default/0`. Pass
  `guards: []` to disable them, or a modified list. The preset additionally
  enables a model-frequency policy (`common_name_frequency`) for exact common
  names and DOB without corroboration. Set it to nil to disable that policy.
  """
  alias PatientMatching.{Comparators, Normalize}

  @doc "The default guards, in the order their reasons are reported."
  def default do
    [
      {:ssn_conflict, &ssn_conflict?/2, 10.0},
      {:dob_conflict, &dob_conflict?/2, 30.0},
      {:generation_suffix, &generation_suffix?/2, 10.0},
      {:twin, &child_twin?/2, 10.0},
      {:sibling, &sibling?/2, 10.0},
      {:household_lookalike, &household_lookalike?/2, 0.0},
      {:household_name_conflict, &household_name_conflict?/2, 0.0},
      {:adult_name_ambiguity, &adult_name_ambiguity?/2, 0.0},
      {:newborn_identity, &newborn_identity?/2, 0.0},
      {:shared_ssn_conflict, &shared_ssn_conflict?/2, 0.0},
      {:name_dob_ambiguity, &name_dob_ambiguity?/2, 0.0},
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

  @doc "Configured guards plus the model-frequency policy for uncorroborated common names."
  def fired_for_model(model, a, b) do
    fired = fired(model.config.guards, a, b)

    if common_name_uncorroborated?(model, a, b),
      do: fired ++ [{:common_name_uncorroborated, 0.0}],
      else: fired
  end

  defp common_name_uncorroborated?(model, a, b) do
    minimum = model.config.common_name_frequency

    same_mrn? =
      Comparators.exact?(a[:source], b[:source]) and Comparators.exact?(a[:mrn], b[:mrn])

    minimum != nil and not same_mrn? and Comparators.exact?(a[:dob], b[:dob]) and
      uncorroborated?(a, b) and
      Enum.all?([:given_name, :family_name], fn field ->
        Comparators.exact?(a[field], b[field]) and
          model.term_frequencies |> Map.get(field, %{}) |> Map.get(a[field], 0.0) >= minimum
      end)
  end

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

  @doc "Conflicting full SSNs/ITINs, except corroborated child records that may use a guarantor's SSN."
  def ssn_conflict?(a, b) do
    s1 = a[:ssn]
    s2 = b[:ssn]

    s1 != nil and s2 != nil and s1 != s2 and itin?(s1) == itin?(s2) and
      not Comparators.one_edit?(s1, s2) and not child_guarantor?(a, b)
  end

  defp child_guarantor?(a, b) do
    a[:dob] != nil and a[:dob] == b[:dob] and not adult?(a[:dob]) and
      Comparators.exact?(a[:given_name], b[:given_name]) and
      Comparators.exact?(a[:family_name], b[:family_name]) and
      (Comparators.exact?(a[:phone], b[:phone]) or
         (Comparators.exact?(a[:street], b[:street]) and Comparators.exact?(a[:zip], b[:zip])))
  end

  defp given_typo?(a, b) when is_binary(a) and is_binary(b) do
    {short, long} = if byte_size(a) <= byte_size(b), do: {a, b}, else: {b, a}

    byte_size(short) >= 2 and
      (Comparators.one_edit?(short, long) or single_deletion?(short, long))
  end

  defp given_typo?(_, _), do: false

  defp single_deletion?(short, long) do
    byte_size(long) == byte_size(short) + 1 and
      Enum.any?(0..(byte_size(long) - 1), fn i ->
        binary_part(long, 0, i) <> binary_part(long, i + 1, byte_size(long) - i - 1) == short
      end)
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

  @doc "Children with differing given names and birth dates at most one day apart may be twins."
  def child_twin?(a, b) do
    Comparators.within_days?(a[:dob], b[:dob], 1) and same_family?(a, b) and
      different_given?(a[:given_name], b[:given_name]) and not adult?(a[:dob])
  end

  @doc "Similar, nonvariant given names with distinct dates and shared household contact require review."
  def household_lookalike?(a, b) do
    same_family?(a, b) and similar_nonvariant_given?(a[:given_name], b[:given_name]) and
      a[:dob] != nil and b[:dob] != nil and
      not Comparators.within_days?(a[:dob], b[:dob], 1) and
      (Comparators.exact?(a[:phone], b[:phone]) or
         (Comparators.exact?(a[:street], b[:street]) and Comparators.exact?(a[:zip], b[:zip])))
  end

  @doc "Unrelated household names and a one-edit DOB difference require review unless a full SSN agrees."
  def household_name_conflict?(a, b) do
    same_family?(a, b) and different_given?(a[:given_name], b[:given_name]) and
      Comparators.dob_one_edit?(a[:dob], b[:dob]) and
      not Comparators.within_days?(a[:dob], b[:dob], 1) and
      not Comparators.exact?(a[:ssn], b[:ssn]) and
      (Comparators.exact?(a[:phone], b[:phone]) or
         (Comparators.exact?(a[:street], b[:street]) and Comparators.exact?(a[:zip], b[:zip])))
  end

  defp similar_nonvariant_given?(a, b) when is_binary(a) and is_binary(b) do
    a != b and not Comparators.nickname?(a, b) and not Comparators.name_part?(a, b) and
      not Comparators.initial?(a, b) and Comparators.jaro_winkler(a, b) >= 0.85
  end

  defp similar_nonvariant_given?(_, _), do: false

  @doc "Same family name, unrelated given names and incompatible birth dates, without a shared full SSN."
  def sibling?(a, b) do
    same_family?(a, b) and different_given?(a[:given_name], b[:given_name]) and
      incompatible_dob?(a, b) and not Comparators.exact?(a[:ssn], b[:ssn])
  end

  @doc "Adult name differences with the same surname and DOB require review; aliases remain possible."
  def adult_name_ambiguity?(a, b),
    do: twin?(a, b) and adult?(a[:dob]) and not corroborated_name_typo?(a, b)

  defp corroborated_name_typo?(a, b) do
    given_typo?(a[:given_name], b[:given_name]) and
      Comparators.exact?(last4(a), last4(b)) and Comparators.exact?(a[:phone], b[:phone])
  end

  @doc "An unnamed newborn needs a baby-specific source/MRN before auto-merging; household contact is insufficient."
  def newborn_identity?(a, b),
    do: (a[:newborn] == true or b[:newborn] == true) and not same_mrn?(a, b)

  @doc "A shared full SSN with unrelated names and incompatible DOBs can be borrowed."
  def shared_ssn_conflict?(a, b) do
    Comparators.exact?(a[:ssn], b[:ssn]) and different_given?(a[:given_name], b[:given_name]) and
      incompatible_dob?(a, b)
  end

  @doc "Exact names with incompatible dates need corroboration beyond names and DOB."
  def name_dob_ambiguity?(a, b) do
    Comparators.exact?(a[:given_name], b[:given_name]) and
      Comparators.exact?(a[:family_name], b[:family_name]) and
      incompatible_dob?(a, b) and uncorroborated?(a, b) and not same_mrn?(a, b)
  end

  defp incompatible_dob?(a, b) do
    a[:dob] != nil and b[:dob] != nil and a[:dob] != b[:dob] and
      not Comparators.dob_one_edit?(a[:dob], b[:dob]) and
      not Comparators.month_day_swapped?(a[:dob], b[:dob]) and
      not Comparators.within_days?(a[:dob], b[:dob], 1)
  end

  defp same_mrn?(a, b),
    do: Comparators.exact?(a[:source], b[:source]) and Comparators.exact?(a[:mrn], b[:mrn])

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

  defp adult?(nil), do: false

  defp adult?(%{year: y, month: m, day: d}) do
    today = Normalize.today()
    Date.diff(today, Date.new!(y, m, d)) >= 18 * 365
  end
end
