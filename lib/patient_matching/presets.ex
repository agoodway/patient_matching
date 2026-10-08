defmodule PatientMatching.Presets do
  @moduledoc """
  Patient comparison levels and blocking rules for probabilistic record linkage.

  `patient_mpi/1` accepts any `PatientMatching.Config` field as an override.
  Name and DOB exact levels use term frequencies. Training runs one EM session
  blocked on birth year (estimating everything but DOB) and one blocked on
  name (estimating DOB and the rest); prediction uses alternative rules and
  defaults to linking two files.
  """
  alias PatientMatching.{Comparators, Comparison, Config, Guards, Level}

  @doc """
  Returns the patient MPI preset; thresholds default to match 0.95 / review 0.20.

  Comparisons: family and given name (with nickname, compound-surname,
  prefix and initial levels), swapped given/family order, DOB (with
  month/day swaps and one-digit typos), sex, a joint contact comparison over
  ZIP, phone and street (household members share all three, so they are
  scored together rather than as independent evidence), and SSN (full or
  last four). Guards from `PatientMatching.Guards.default/0` stop family
  members with contradicting identifiers from auto-matching. Exact full name
  and DOB without corroboration also require review when both names occur in
  at least 0.4% of training rows (`common_name_frequency: 0.004`; nil disables).
  """
  def patient_mpi(overrides \\ []) do
    comparisons = [
      comparison(:family_name, [
        exact(true),
        level(:jw_0_92, &(Comparators.jaro_winkler(&1, &2) >= 0.92)),
        level(:compound, &Comparators.compound?/2),
        level(:jw_0_85, &(Comparators.jaro_winkler(&1, &2) >= 0.85))
      ]),
      comparison(:given_name, [
        exact(true),
        level(:nickname, &Comparators.nickname?/2),
        level(:jw_0_92, &(Comparators.jaro_winkler(&1, &2) >= 0.92)),
        level(:part, &Comparators.name_part?/2),
        level(:initial, &Comparators.initial?/2),
        level(:jw_0_85, &(Comparators.jaro_winkler(&1, &2) >= 0.85))
      ]),
      comparison(:name_order, [:given_name, :family_name], [
        level(:swapped, &Comparators.swapped_names?/2)
      ]),
      comparison(:dob, [
        exact(true),
        level(:month_day_swapped, &Comparators.month_day_swapped?/2),
        level(:within_1_day, &Comparators.within_days?(&1, &2, 1)),
        level(:one_digit, &Comparators.dob_one_edit?/2),
        level(:same_year_month, &Comparators.same_year_month?/2)
      ]),
      comparison(:sex, [exact()]),
      comparison(:contact, [:zip, :phone, :street], [
        level(:phone_and_zip, &Comparators.phone_and_zip?/2),
        level(:phone, &Comparators.same_phone?/2),
        level(:street_and_zip, &Comparators.street_and_zip?/2),
        level(:building_and_zip, &Comparators.building_and_zip?/2),
        level(:zip, &Comparators.same_zip?/2),
        level(:near, &Comparators.contact_near?/2)
      ]),
      comparison(:ssn, [:ssn, :ssn_partial], [
        level(:exact, &Comparators.ssn_exact?/2),
        level(:one_digit, &Comparators.ssn_one_edit?/2),
        level(:last4, &Comparators.ssn_tuple_last4?/2)
      ])
    ]

    defaults = [
      comparisons: comparisons,
      blocking: [
        [:family_soundex, :dob_year],
        [:given_name3, :zip],
        [:phone],
        [:ssn_last4, :dob_year],
        [:dob],
        [:given_soundex, :family_soundex]
      ],
      training_blocking: [[:dob_year], [:family_soundex, :given_name3]],
      guards: Guards.default(),
      common_name_frequency: 0.004
    ]

    Config.new(Keyword.merge(defaults, overrides))
  end

  defp comparison(field, fields \\ nil, agreements),
    do: %Comparison{
      field: field,
      fields: fields,
      levels: [%Level{name: :null, null_level?: true} | agreements] ++ [%Level{name: :else}]
    }

  defp exact(tf \\ false), do: %Level{name: :exact, match?: &Comparators.exact?/2, tf?: tf}
  defp level(name, matcher), do: %Level{name: name, match?: matcher}
end
