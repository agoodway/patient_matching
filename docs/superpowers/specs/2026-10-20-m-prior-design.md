# Counts-based m prior for PatientMatching training

## Intent

`PatientMatching.train/3` estimates m by unsupervised EM, with one session per
`config.training_blocking` rule. `combine_sessions/3` averages each field's m
over the sessions that estimated it. The only supervision hook today is
`:m_init`, a starting mass, and EM overwrites it for every field some session
estimates. Under `Presets.patient_mpi/0` that means every comparison, so
`m_init` survives only for fields with no non-null observations, or for
fields that revert because an exact-style level ends with m <= u.

A consumer (GoodCases intake) records reviewer-confirmed matches as
comparison-level vectors. For each pair it stores the level that `explain/3`
assigns to each comparison. It wants those counts to inform m in proportion to
how many there are:

- a few labels should barely move m;
- many labels should dominate;
- no labels should leave training exactly as it is today.

The design is a Dirichlet-style prior over each field's m. The labelled counts
are added to EM's expected match counts in the M-step.

Freezing m at supplied values was considered and rejected. A frozen m ignores
how many labels back it, and the prior covers the strong case anyway through a
large strength.

## Goals

- Reviewer counts pull m toward their proportions, weighted by how many there are.
- No prior (or a zero prior) gives bit-identical output.
- Model dumps keep a record of the prior that was used, and older dumps still load.
- Consumers get a stable comparison signature to key stored counts on.

## Non-goals / out of scope

Freezing m, per-field strength maps, priors on u or lambda, and any change to
scoring, linking, guards, blocking or presets.

## Anti-goals (failure even if it "works")

- **The prior leaks into fields a session's blocking rule conditions on.** It
  must be added only to the fields the current session is estimating.
- **The prior touches `lambda_train`.** Prior counts must never enter
  `matched` or `total`. If they did, EM would assume a larger share of true
  matches among the training pairs.
- **Identity values appear in error messages or examples.** Use synthetic,
  value-free data only.

## API

Three new options on `PatientMatching.train/3`:

- `:m_prior`: `%{field_atom => %{level_atom => count}}`. Each count is a
  nonnegative number (integer or float) of labelled true-match pairs observed
  at that level. An omitted field or level contributes 0. Default `%{}`.
- `:m_prior_strength`: a nonnegative number that multiplies every prior count.
  Default `1.0`.
- `:m_prior_base_weight` (k): a number > 0. It is the pseudo-count given to
  the base m (built-in defaults merged with `m_init`) when blending the base
  with the prior for the starting m. Default `10.0`.

Validation raises `ArgumentError` with a fixed message that contains no values:

- each field key must be the `field` of a configured comparison. Unlike
  `m_init`, an unknown field is an error, not ignored;
- each level key must be a non-null level of that comparison, the same rule as
  `validate_initial_m!/2`;
- every count must be a number >= 0;
- the strength must be a number >= 0;
- the base weight must be a number > 0;
- `m_prior` must be a map, and each field's value must be a map.

A field is *active* when its count total times the strength is greater than 0.
An inactive field (counts summing to 0, or `m_prior_strength: 0`) behaves
exactly as if no prior had been given, including its starting m. With
`m_prior: %{}` or strength 0, parameters must be bit-identical to today's for
the same inputs and seed. The simplest way to guarantee that is to drop
inactive fields up front, so the zero-prior code path does no prior
arithmetic at all.

## Trainer changes (`lib/patient_matching/trainer.ex`)

1. **Starting m (`initial_m`): a blended start.** `initial_m/2` computes
   `base` exactly as today: the built-in defaults merged with `m_init`, then
   `distribution/1`. For an active field:

   ```
   N[f]       = strength * sum(prior[f])
   initial[f] = distribution((k * base[f][l] + strength * prior[f][l]) / (k + N[f]))
   ```

   This is computed over all of the field's non-null levels, and a missing
   level counts 0. Every level keeps at least `k / (k + N)` of its base share.
   So a few labels never floor a level the reviewers didn't see, and a very
   large strength makes `initial` equal to the prior proportions.
   *For an inactive field, return `base` unchanged rather than running it
   through `distribution/1` again. Running it again could change the last
   bit, and the bit-identical guarantee depends on that bit.*

   The blended start replaces the original rule that the start is the
   prior's proportions with `m_init` winning. It was changed because starting
   from raw proportions floors every unlabelled level, and EM's 25-round
   limit may not recover from that.

2. **M-step (`em/6`).** After the expected counts are accumulated and before
   `distribution/1`, add `strength * prior[field][level]` to
   `counts[field][level]`. Do this only for fields that are estimated in this
   session (the `fields` passed to `estimate_m/4`) **and** have non-null
   observations in it. A field with no observations keeps its masses
   (`initial`), as it does today. The existing "sum == 0 keeps masses" branch
   therefore tests the sum of expected counts *before* the prior is added.
   Pass the prior and strength to `em/6` through new `estimate_m/4` options
   (`:m_prior`, `:m_prior_strength`, with the same defaults). `estimate_m/4` is
   a public `@doc` function and tests call it directly. It does not need the
   base weight, because the blended start arrives through
   `model.parameters`.
   - Prior counts never enter `matched` or `total`.
   - The convergence check (`em_tol`) is unchanged.
   - `estimate_m/4` runs the same prior and strength validation as `train/3`
     (one shared `validate_m_prior!/2`), so unchecked level names never reach
     `em/6`. Validation is cheap, so running it twice on the `train/3` path is
     fine.

3. **Instability check.** Unchanged. An exact-style level with m <= u still
   reverts the field to `initial`, now the blended value, and sets
   `unstable: true`. With few labels that is about the defaults. With many it
   is about the reviewers' proportions.

**Lambda.** The prior is never added to lambda's numerator or denominator,
so it cannot inflate the share of matches directly. The converged
`lambda_train` can still change, because the prior moves m and m feeds the
E-step. Docs must say that lambda moves only through m. They must not say
lambda is unaffected.

4. **Combining sessions.** `combine_sessions/3` is unchanged. Each session
   already includes the prior, so a field estimated by k sessions gets the
   full prior weight in each of them, not 1/k of it. A field that no session
   estimates keeps `initial`.

5. **Training metadata.** `model.trained` gains:
   - `m_prior: %{field => total_count}`: the raw total before strength, only
     for fields whose raw total is nonzero;
   - `m_prior_strength: float`;
   - `m_prior_base_weight: float`.

   With no prior these are `%{}`, `1.0` and `10.0` (or the supplied values). *With strength 0 and nonzero
   counts, `m_prior` still records the raw totals and the strength records
   `0.0`. The `trained` map then differs from a run without a prior, but the
   parameters do not.*

## Model dump/load (`lib/patient_matching/model.ex`)

- `dump/1`: write `trained.m_prior` (string field keys, number values),
  `trained.m_prior_strength` and `trained.m_prior_base_weight`. Jason
  already turns atom keys into strings.
- `load_training/1`: read all three. Check field keys against configured
  comparison names using the existing string comparisons, never
  `String.to_atom`. Check that values are numbers >= 0, the strength is a
  number >= 0, and the base weight is a number > 0. Atom
  keys are produced by looking up the matching configured comparison.
  `load_training` therefore needs the comparisons passed in. When the keys are
  absent, as in dumps from 0.1.0, default to `%{}`, `1.0` and `10.0`. Do not change
  the dump `version` (stays 3) or the comparison signature.

## Small public additions

- `PatientMatching.comparison_signature(config_or_model)`: returns the same
  list `Model.dump/1` writes under `"comparisons"` (field, fields, and ordered
  levels with `name`, `tf` and `null`, with string keys and values). It
  accepts a `%Config{}` or a `%Model{}`. `dump/1` and `load/2` use it, so
  there is a single definition. Move the existing private `Model.signature/1`
  into a public function and delegate to it.
- `explain/3` docs: state the guarantee consumers rely on. `levels` has
  exactly one entry per configured comparison, in configuration order,
  including null levels, even when an MRN override applies. This already holds
  because `explain/3` always scores with `explain: true`. Add a test that pins
  it, including an MRN-override pair.

## Docs and versioning

- `train/3` docstring: explain all three options, the blended start, the
  M-step semantics (pseudo-counts added to expected match counts within each
  session that estimates and observes the field), that lambda moves only
  through m, the reversion target (the blended start), and the new `trained`
  keys.
- README: a short "Supervised m prior" section under "Configuration and
  training", with a synthetic, value-free example:

  ```elixir
  PatientMatching.train(records, config,
    m_prior: %{given_name: %{exact: 40, nickname: 6, jw_0_92: 3, else: 1}},
    m_prior_strength: 1.0
  )
  ```

  Check the level names against the preset's `given_name` comparison and use
  real ones.
- Bump `mix.exs` version to 0.2.0. *In the CHANGELOG, the existing
  "Unreleased" section becomes "0.2.0", with the m-prior entry added. The
  matcher changes already listed there change behaviour too, so under the new
  rule they need a minor bump anyway.*
- State in the CHANGELOG and README: any change to a matcher's behaviour, even
  one that keeps the same level name, bumps the minor version. Consumers key
  stored level counts on (comparison signature, library version).
  GoodCases hashes the signature and stores `Application.spec(:patient_matching,
  :vsn)`, and it tracks this package's master branch. That makes the rule a
  release-process requirement, not just a CHANGELOG note. Add it to the
  README's Development section as a checklist item for anyone merging a
  matcher change. *Enforcing it automatically (CI) is out of scope for this
  change.*

## Tests

All tests use synthetic records only.

- `m_prior: %{}` and `m_prior_strength: 0` (with a nonzero prior) each give
  parameters identical to training without the options, with the same seed.
- A field with no non-null observations, given a prior total of 1, stays
  within a small tolerance of the defaults, and no level is at the floor
  unless its default is.
- A field with no non-null observations, given a prior total of 1e9, equals
  the prior proportions.
- A large strength (e.g. `1.0e9`) pins an estimated field to its prior
  proportions, within the floor and normalization.
- A small prior (a total of 1 against thousands of expected matches) changes m
  by less than `1.0e-3`. The test calls `estimate_m/4` directly, once with and
  once without the prior, and first asserts that each call converged (its own
  `trained.em_iters < config.em_max_iters`). After `train/3`, `em_iters` is a
  sum over sessions, so convergence can't be checked from it. Otherwise an
  unconverged fixture, not the prior, could decide the result.
- A prior on a field excluded from a session (blocked by that session's rule)
  does not change that field in that session. Assert this through
  `estimate_m/4` with explicit `:fields`.
- Lambda: call `estimate_m/4` directly, not `train/3`, with the same model and
  a config built with `em_max_iters: 1` (a Config field, not an `estimate_m/4`
  option), with and without `:m_prior`. The `lambda_train` values
  (`matched / total`) must be identical. Going through `train/3` would change
  the starting m, because of the blended start, and lambda would legitimately
  differ.
- A field forced unstable reverts to the blended `initial`: near the defaults
  with 1 label and near the prior with 10,000. `trained.unstable` is true.
- Validation: an unknown field, an unknown level, a null level, a negative
  count, a non-number count, a negative strength and a base weight <= 0 each
  raise `ArgumentError`, and no message contains the offending value. An
  invalid `:m_prior` passed directly to `estimate_m/4` also raises.
- A dump/load round trip preserves `trained.m_prior`, `m_prior_strength` and
  `m_prior_base_weight`. A 0.1.0-style dump without them loads with the
  defaults.
- `comparison_signature/1` equals the `"comparisons"` key in `dump/1` output
  for both a config and a model. `load/2` still rejects a mismatched config.
- `explain/3` returns one level per comparison in order, including nulls and
  under an MRN override.

## Left to the builder

Internal function shapes, where prior validation lives (a
`validate_m_prior!/2` next to `validate_initial_m!/2` is natural), test
fixtures, and the exact error message wording, as long as it contains no
values.
