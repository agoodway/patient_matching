defmodule PatientMatching.Explain do
  @moduledoc false
  alias PatientMatching.{Normalize, Scorer}

  @doc "Normalizes raw maps and returns their score with comparison evidence even for MRN overrides."
  def explain(left, right, model),
    do: Scorer.score(Normalize.record(left), Normalize.record(right), model, explain: true)
end
