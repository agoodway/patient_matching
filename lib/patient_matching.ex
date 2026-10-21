defmodule PatientMatching do
  @moduledoc """
  Fellegi–Sunter probabilistic record linkage for patient maps.

  Train without labels, score blocked candidate pairs, and inspect additive
  base-two evidence weights. Records require `:id`, unique within each file;
  ids may be any Elixir term. Optional patient fields are `:source`, `:mrn`,
  `:ssn`, `:given_name`, `:family_name`, `:dob`, `:sex`, `:zip`, `:phone`,
  and `:street`. Normalization creates a copy under `:normalized`: accents
  folded, common date/phone/ZIP/SSN formats parsed, and placeholder values
  (`JOHN DOE`, `BABY GIRL`, `999-99-9999`, see `PatientMatching.Placeholders`)
  set to nil.

  Start with `PatientMatching.Presets.patient_mpi/0`. A model freezes the
  config, estimated prior, per-level m/u, term frequencies and training status.
  The prior is the probability that two random records are the same patient:
  deterministic agreements over all n(n-1)/2 pairs, corrected for recall.
  Single-file training uses unordered within-file pairs even when the config
  defaults to `:link_only`.

  Unblocked random pairs estimate u. EM runs once per training blocking rule,
  estimating m for the comparisons that rule does not block on together with
  the prior inside its blocks, while u and the prediction prior stay fixed.
  Null comparisons contribute zero weight and are excluded from estimation.
  Probabilities are computed in log space. Inspect `model.trained.unstable`:
  exact levels with m <= u cause the whole field to revert to its initial m,
  without failing training.

  Guards (`PatientMatching.Guards`) keep pairs with a hard conflict, such as
  birth years decades apart or different SSNs, from auto-matching however
  well their other fields agree.

  ## Custom comparisons

  Construct `%PatientMatching.Comparison{field: atom, levels: levels}` using
  `%PatientMatching.Level{}` structs. To compare several normalized fields
  together, add `fields: [atom]`; matchers then receive tuples, and the null
  level applies when all of them are nil. `field` names the comparison. The first level must be the only null
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
  normalized fields; derived keys are `:family_soundex`, `:given_soundex`,
  `:given_name3`, `:dob_year`, and `:ssn_last4`. Key functions receive the whole normalized
  record and return a block value or nil to skip the rule. Blocks over
  `max_block_size` (500 by default) are skipped and counted. MRN agreements
  bypass prediction blocking.

  This package performs linkage only: no SQL backend, external identity
  services, or supervised classifier. Logs contain block hashes/counts,
  never raw field values.
  """
  alias PatientMatching.{
    Assign,
    Blocking,
    Cluster,
    Config,
    Explain,
    Guards,
    Linker,
    Model,
    Trainer
  }

  @doc "Builds and validates a config from keywords. The preset supplies patient comparisons and rules."
  def config(opts \\ []), do: Config.new(opts)

  @doc """
  Trains from one unlabeled file. Options: `:lambda` (fixed prior, clamped to
  1e-9..0.5) and `:m_init` (field => level => initial mass). Supervised m
  prior options `:m_prior`, `:m_prior_strength` and `:m_prior_base_weight`
  are described under "m prior" below. `m_estimation: :prior` requires
  `:lambda`, skips EM and uses the blended initial m without requiring
  training candidates; u and term frequencies are estimated normally.
  The default `m_estimation: :em` runs training sessions.

  Initial agreement masses follow the brief: strong 0.9, moderate 0.7,
  year-month 0.5, else the remainder. When their sum exceeds one, masses
  are normalized with a floored else remainder. Unknown custom levels
  start at 0.5. All estimates are floored at 1e-6 and normalized, retaining
  the floor after scaling. All-null u distributions start uniform; fields
  with no non-null EM observations retain their initial m.

  TF is count(value) / total training records; nil values receive no count.
  Training raises `ArgumentError` for duplicate ids, fewer than two records,
  missing comparisons, or (in EM mode) zero training candidates.

  ## m prior

  Reviewer label counts can steer m through three options:

    * `:m_prior` (default `%{}`) - comparison name => non-null level =>
      nonnegative count, e.g. `%{given_name: %{exact: 40, nickname: 6}}`.
      Missing levels count 0.
    * `:m_prior_strength` (default `1.0`) - nonnegative multiplier on the
      counts. A field is active when its total count times strength is above 0.
    * `:m_prior_base_weight` (default `10.0`) - positive weight `k` of the
      default start against the counts.

  An active field starts EM from a blend of its base m (the defaults merged
  with `:m_init`) and the counts, normalized with the usual floor:

      (k * base[level] + strength * count[level]) / (k + strength * total)

  In each EM session that estimates the field and observes it (non-null
  levels), every M-step adds `strength * count` pseudo-counts to the field's
  expected match counts. The prior never enters lambda's update, so lambda
  moves only through m. A field that becomes unstable reverts to its blended
  start. With no active prior, the parameters are bit-identical to training
  without these options. Invalid options raise `ArgumentError` before
  training starts.

  `model.trained` records `:m_prior` (field => raw total count before
  strength, only for nonzero totals), `:m_prior_strength` and
  `:m_prior_base_weight`, both floats.
  """
  # Prior-only mode requires fixed lambda and preserves the blended m start.
  def train(records, config, opts \\ []), do: Trainer.train(records, config, opts)

  @doc "Returns a model with a fixed match prior, clamped to 1e-9..0.5 like train/3's :lambda."
  def put_lambda(%PatientMatching.Model{} = model, lambda) do
    %{
      model
      | lambda: PatientMatching.Trainer.clamp_lambda(lambda),
        trained: Map.put(model.trained, :lambda_source, :fixed)
    }
  end

  @doc """
  Links two files and returns `matches`, `review`, `record_review`, `non_match_count`, and
  `dropped_blocks`, and `dropped_blocks_by_rule` (zero-based rule index => count).
  Each returned pair has ids, probability, weight, reason
  and the guards that fired (see `PatientMatching.Guards`).
  Only candidates are counted as non-matches; unblocked pairs are unscored.

  `record_review` flags records with no normalized name, DOB, SSN (full or
  partial), contact, or source/MRN identifier. Entries contain `id`, `side`
  (`:left`, `:right`, or `:single` for dedupe), and
  `reason: :insufficient_identity`. These records need more information;
  they are not proposed pairs and do not count as matches or pair reviews.

  Options override `:match_threshold` / `:review_threshold`. Match is >= the
  match threshold, non-match is <= the review threshold, and review lies
  between. Link type defaults to `:link_only`; `link_type: :dedupe_only`
  instead scores the combined file, whose ids must then be unique.
  """
  def link(left, right, model, opts \\ []), do: Linker.link(left, right, model, opts)

  @doc """
  Scores one file, forcing dedupe pairing, and returns the linking result plus
  `clusters` and `rejected_edges`. Only match edges enter union-find,
  strongest first; with guards configured, an edge that would put two records
  a guard separates into one cluster is rejected. Singletons are omitted.
  Each cluster contains a stable smallest `root_id` and sorted `member_ids`.
  """
  def dedupe(records, model, opts \\ []) do
    records =
      Blocking.prepare(records, model.config.placeholders, model.config.strip_mrn_leading_zeros)

    result = Linker.score(records, :dedupe_only, model, opts)

    case {model.config.guards, model.config.common_name_frequency} do
      {[], nil} ->
        result
        |> Map.put(:clusters, Cluster.clusters(result.matches))
        |> Map.put(:rejected_edges, [])

      _ ->
        index = Map.new(records, &{&1.id, &1.normalized})

        {clusters, rejected} =
          Cluster.guarded(
            result.matches,
            &(Guards.fired_for_model(model, index[&1], index[&2]) != [])
          )

        result |> Map.put(:clusters, clusters) |> Map.put(:rejected_edges, rejected)
    end
  end

  @doc """
  Scores raw maps with per-field winning levels, m/u and log2(m/u) weights,
  plus separate TF adjustments. Nulls have m/u nil and weight zero.

  Total weight adds the prior log-odds, TF terms and guard penalties. Same
  non-nil source/MRN yields probability 1, weight 50, reason `:mrn`, unless a
  guard fires (reason `:mrn_conflict`); explanation levels remain populated to
  show the statistical evidence despite that override.

  `levels` always has exactly one entry per configured comparison, in
  configuration order, including null levels (`m: nil`), even when an MRN
  override applies.
  """
  def explain(left, right, model), do: Explain.explain(left, right, model)

  @doc """
  Returns the comparison signature (field, fields and ordered levels with
  `name`, `tf` and `null`, all string keys and values) that `dump/1` writes
  under `"comparisons"` and `load/2` checks. Accepts a config or a model.
  """
  def comparison_signature(%Config{} = config), do: Model.comparison_signature(config)
  def comparison_signature(%Model{} = model), do: Model.comparison_signature(model)

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
