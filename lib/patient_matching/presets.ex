defmodule PatientMatching.Presets do
  @moduledoc """
  Patient comparison levels and blocking rules for probabilistic record linkage.

  `patient_mpi/1` accepts any `PatientMatching.Config` field as an override.
  Name exact levels use term frequencies. Training blocks on birth year only;
  prediction uses four alternative rules and defaults to linking two files.
  """
  alias PatientMatching.{Comparators, Comparison, Config, Level}

  @doc "Returns the patient MPI preset; thresholds default to match 0.95 / review 0.20."
  def patient_mpi(overrides \\ []) do
    comparisons = [
      name(:family_name),
      name(:given_name),
      comparison(:dob, [
        exact(true),
        level(:within_1_day, &Comparators.within_days?(&1, &2, 1)),
        level(:same_year_month, &Comparators.same_year_month?/2)
      ]),
      comparison(:sex, [exact()]),
      comparison(:zip, [exact(), level(:zip3, &Comparators.zip3_match?/2)]),
      comparison(:phone, [exact(), level(:last7, &Comparators.phone_last7?/2)]),
      comparison(:ssn, [exact(), level(:last4, &Comparators.ssn_last4?/2)])
    ]

    defaults = [
      comparisons: comparisons,
      blocking: [
        [:family_soundex, :dob_year],
        [:given_name3, :zip],
        [:phone],
        [:ssn_last4, :dob_year]
      ],
      training_blocking: [[:dob_year]]
    ]

    Config.new(Keyword.merge(defaults, overrides))
  end

  defp name(field),
    do:
      comparison(field, [
        exact(true),
        level(:jw_0_92, &(Comparators.jaro_winkler(&1, &2) >= 0.92)),
        level(:jw_0_85, &(Comparators.jaro_winkler(&1, &2) >= 0.85))
      ])

  defp comparison(field, agreements),
    do: %Comparison{
      field: field,
      levels: [%Level{name: :null, null_level?: true} | agreements] ++ [%Level{name: :else}]
    }

  defp exact(tf \\ false), do: %Level{name: :exact, match?: &Comparators.exact?/2, tf?: tf}
  defp level(name, matcher), do: %Level{name: name, match?: matcher}
end
