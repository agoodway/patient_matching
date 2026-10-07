defmodule PatientMatching do
  @moduledoc """
  Fellegi–Sunter probabilistic record linkage for patient maps.

  Train without labels, score blocked candidate pairs, and inspect additive
  base-two evidence weights. Records require `:id`, unique within each file;
  ids may be any Elixir term. Optional patient fields are `:source`, `:mrn`,
  `:ssn`, `:given_name`, `:family_name`, `:dob`, `:sex`, `:zip`, `:phone`,
  and `:street`. Normalization creates a copy under `:normalized`.

  Start with `PatientMatching.Presets.patient_mpi/0`. A model freezes the
  config, estimated prior, per-level m/u, term frequencies and training status.
  The prior is a rough estimate from deterministic agreements corrected for
  recall over prediction candidates. Single-file training uses unordered
  within-file pairs even when the config defaults to `:link_only`.

  Unblocked random pairs estimate u; EM on separately blocked patterns
  estimates m while u and the prior stay fixed. Null comparisons contribute
  zero weight and are excluded from estimation. Probabilities are computed
  in log space. Inspect `model.trained.unstable`: exact levels with m <= u
  cause the whole field to revert to its initial m, without failing training.

  ## Custom comparisons

  Construct `%PatientMatching.Comparison{field: atom, levels: levels}` using
  `%PatientMatching.Level{}` structs. The first level must be the only null
  level; the last is `:else`. Between them, arity-two predicates run in order
  on normalized values, with the first true level winning. Null and else
  semantics are enforced by the runner regardless of their predicates.
  For TF exact levels, use `&PatientMatching.Comparators.exact?/2` as the
  matcher; arbitrary function captures cannot certify equality. For the EM
  instability fallback, exact-style predicates are identified by that canonical
  matcher or the reserved level names `:exact` / `:dob_exact`. Use one of those
  names for custom non-TF equality predicates; arbitrary renamed predicates
  cannot be inferred as exact-style.

      iex> alias PatientMatching.{Comparators, Comparison, Level}
      iex> comparison = %Comparison{field: :family_name, levels: [
      ...>   %Level{name: :null, null_level?: true},
      ...>   %Level{name: :exact, match?: &Comparators.exact?/2, tf?: true},
      ...>   %Level{name: :else}
      ...> ]}
      iex> config = PatientMatching.config(comparisons: [comparison],
      ...>   blocking: [[:family_name]], training_blocking: [[:dob_year]])
      iex> config.match_threshold
      0.95

  Blocking is an OR of key-lists, each key-list an AND. Key atoms read
  normalized fields; derived keys are `:family_soundex`, `:given_name3`,
  `:dob_year`, and `:ssn_last4`. Key functions receive the whole normalized
  record and return a block value or nil to skip the rule. Blocks over
  `max_block_size` (500 by default) are skipped and counted. MRN agreements
  bypass prediction blocking.

  This package performs linkage only: no SQL backend, external identity
  services, or supervised classifier. Logs contain block hashes/counts,
  never raw field values.
  """
  alias PatientMatching.{Assign, Blocking, Cluster, Config, Explain, Linker, Model, Trainer}

  @doc "Builds and validates a config from keywords. The preset supplies patient comparisons and rules."
  def config(opts \\ []), do: Config.new(opts)

  @doc """
  Trains from one unlabeled file. Options: `:lambda` (fixed prior, clamped to
  1e-6..0.5) and `:m_init` (field => level => initial mass).

  Initial agreement masses follow the brief: strong 0.9, moderate 0.7,
  year-month 0.5, else the remainder. When their sum exceeds one, masses
  are normalized with a floored else remainder. Unknown custom levels
  start at 0.5. All estimates are floored at 1e-6 and normalized, retaining
  the floor after scaling. All-null u distributions start uniform; fields
  with no non-null EM observations retain their initial m.

  TF is count(value) / total training records; nil values receive no count.
  Training raises `ArgumentError` for duplicate ids, fewer than two records,
  missing comparisons, or zero prediction/training candidates.
  """
  def train(records, config, opts \\ []), do: Trainer.train(records, config, opts)

  @doc """
  Links two files and returns `matches`, `review`, `non_match_count`, and
  `dropped_blocks`. Each returned pair has ids, probability, weight and reason.
  Only candidates are counted as non-matches; unblocked pairs are unscored.

  Options override `:match_threshold` / `:review_threshold`. Match is >= the
  match threshold, non-match is <= the review threshold, and review lies
  between. Link type defaults to `:link_only`; `link_type: :dedupe_only`
  instead scores the combined file, whose ids must then be unique.
  """
  def link(left, right, model, opts \\ []), do: Linker.link(left, right, model, opts)

  @doc """
  Scores one file, forcing dedupe pairing, and returns the linking result plus
  `clusters`. Only match edges enter union-find; singletons are omitted.
  Each cluster contains a stable smallest `root_id` and sorted `member_ids`.
  """
  def dedupe(records, model, opts \\ []) do
    result = Linker.score(Blocking.prepare(records), :dedupe_only, model, opts)
    Map.put(result, :clusters, Cluster.clusters(result.matches))
  end

  @doc """
  Scores raw maps with per-field winning levels, m/u and log2(m/u) weights,
  plus separate TF adjustments. Nulls have m/u nil and weight zero.

  Total weight adds the prior log-odds and TF terms. Same non-nil source/MRN
  yields probability 1, weight 50, reason `:mrn`; explanation levels remain
  populated to show the statistical evidence despite that override.
  """
  def explain(left, right, model), do: Explain.explain(left, right, model)

  @doc "Greedy one-to-one assignment by descending probability. Neither id is reused; this is not Hungarian assignment."
  def assign(pairs), do: Assign.assign(pairs)

  @doc "Dumps a model to a versioned Jason JSON string. Stores level names and flags, not matcher functions or blocking functions."
  def dump(model), do: Model.dump(model)

  @doc """
  Loads JSON using the original config to reattach matchers and blocking rules.
  Requires identical ordered comparison fields/level names/flags. Callers must
  supply the same predicate semantics; JSON cannot verify function equivalence.
  Invalid dumps/configs raise `ArgumentError`. No atoms are created from JSON.
  """
  def load(json, config), do: Model.load(json, config)
end
