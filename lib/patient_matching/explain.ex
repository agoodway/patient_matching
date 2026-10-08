defmodule PatientMatching.Explain do
  @moduledoc false
  alias PatientMatching.{Normalize, Scorer}

  @doc "Normalizes raw maps and returns their score with comparison evidence even for MRN overrides."
  def explain(left, right, model),
    do:
      Scorer.score(
        Normalize.record(left, model.config.placeholders, model.config.strip_mrn_leading_zeros),
        Normalize.record(right, model.config.placeholders, model.config.strip_mrn_leading_zeros),
        model,
        explain: true
      )
end
