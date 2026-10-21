# PatientMatching

An Elixir library for explainable Fellegi–Sunter probabilistic patient record
linkage. Train on unlabeled maps, link two files or deduplicate one, and inspect
per-field weights. Uses comparison levels, unblocked random-sample `u`, fixed-`u`
EM for `m`, term-frequency adjustments, and indexed blocking.

Requires Elixir 1.17 or later. Runtime dependency: Jason. StreamData is test-only.

## Example

All values below are synthetic. Run this block with `mix run` in this project,
or paste it into `iex -S mix`.

```elixir
left = [
  %{id: "a1", given_name: "Alice", family_name: "Example", dob: "1980-01-10",
    sex: "F", zip: "02139", phone: "2125550101", ssn: "212456789"},
  %{id: "a2", given_name: "Brian", family_name: "Sample", dob: "1980-06-12",
    sex: "M", zip: "10001", phone: "2125550102", ssn: "234567890"},
  %{id: "a3", given_name: "Carol", family_name: "Fiction", dob: "1980-09-15",
    sex: "F", zip: "60601", phone: "3125550103", ssn: "345678901"}
]
right = [
  %{id: "b1", given_name: "Alicx", family_name: "Example", dob: "1980-01-10",
    sex: "F", zip: "02139", phone: "5550101", ssn: "212456789"},
  %{id: "b2", given_name: "Brian", family_name: "Sample", dob: "1980-06-13",
    sex: "M", zip: nil, phone: "2125550102", ssn: "234567890"}
]

config = PatientMatching.Presets.patient_mpi()
model = PatientMatching.train(left ++ right, config)
%{matches: matches, review: review, non_match_count: count, dropped_blocks: dropped} =
  PatientMatching.link(left, right, model)
explanation = PatientMatching.explain(hd(left), hd(right), model)
assigned = PatientMatching.assign(matches)
deduplicated = PatientMatching.dedupe(left ++ right, model)
loaded = PatientMatching.load(PatientMatching.dump(model), config)

IO.inspect(%{
  matches: matches, review: review, non_match_count: count, dropped_blocks: dropped,
  probability: explanation.probability, levels: explanation.levels,
  assigned: assigned, clusters: deduplicated.clusters,
  round_trip_probability: PatientMatching.explain(hd(left), hd(right), loaded).probability
})
```

The tiny example demonstrates the API; estimate parameters on a representative
file for actual use. `model.trained` reports prior source, EM iteration count,
and whether any unstable field reverted to its initial `m`.

## Records and decisions

Maps require `:id`, unique within each file. Optional fields: `:source`, `:mrn`,
`:ssn`, `:given_name`, `:family_name`, `:dob`, `:sex`, `:zip`, `:phone`, `:street`.
IDs may be any Elixir term. The caller's maps are preserved; comparisons read a
normalized copy under `:normalized`:

- **Names:** accents folded (JIMÉNEZ = JIMENEZ), uppercase letters only, so
  spaces, hyphens and apostrophes do not matter (`DE LA CRUZ` = `DELACRUZ`).
  A trailing JR/SR/II/III/IV moves to `:suffix`; single-letter middle initials
  after a given name are dropped.
- **DOB:** Date-like maps and structs, ISO dates and datetimes, `YYYY/MM/DD`,
  `YYYYMMDD`, `MMDDYYYY`, and month-first `M/D/YYYY` with `/`, `-` or `.`.
  A first number over 12 is read as the day. Dates before 1880 or in the
  future are nil.
- **Phone:** digits, without a leading US `1` or an extension.
- **ZIP:** first five digits; a 4- or 8-digit value gets back its lost leading zero.
- **Street:** USPS Publication 28 standard form by word position. The suffix
  and the directionals around the name are abbreviated (`123 NORTH MAIN
  STREET` = `123 N MAIN ST`); words inside the name are kept (`RIDGE AVENUE`
  is `RIDGE AVE`, and `EAST ST` stays apart from `E ST`). Every unit
  designator becomes one `UNIT` marker after the street (`APT 4` = `#4` =
  `SUITE 4` = `4TH FLOOR`, and `APT 1B 626 E KILBOURN AVE` moves its unit to
  the end). Box lines read `PO BOX`, `RR` or `HC`. Tested against the
  labeled usaddress addresses in `test/fixtures/usaddress`; addresses are not
  validated.
- **SSN:** nine digits; a four-digit value is kept as `:ssn_partial` for
  last-four comparison and blocking.
- **MRN:** alphanumeric, leading zeros after any letter prefix ignored by default.
  Set `strip_mrn_leading_zeros: false` to preserve zeros (`HA000123` differs from `HA123`).
- **Sex:** M/F (MALE/FEMALE accepted); unknown and numeric codes are nil.
- Integers are accepted for MRN, ZIP, phone and SSN.

Placeholder values become nil, so they neither agree nor block: names such as
`JOHN DOE`, `UNKNOWN`, `BABY GIRL`, `TRAUMA ALPHA`; DOB `1900-01-01`;
structurally invalid or sentinel SSNs (`000-00-0000`, `123-45-6789`,
`999-99-9999`); phones like `000-0000`, `555-1212` or repeated digits; ZIP
`00000`. The lists are in `PatientMatching.Placeholders` and can be replaced
with the `:placeholders` option. Missing, empty and invalid values are nil, and
nil never counts as agreement.

Defaults: match probability >= 0.95; non-match <= 0.20; otherwise review.
Override either threshold in `link/4` or `dedupe/3`. Results contain matches and
review pairs, a count of scored non-matches, `dropped_blocks`, and
`dropped_blocks_by_rule`. The latter maps zero-based prediction rule indices to
counts, including zero counts; its sum equals `dropped_blocks`. Unblocked
pairs are unscored. Pair maps have `left_id`, `right_id`, `probability`, `weight`,
`reason` and `guards`.

**Guards** (`PatientMatching.Guards`, on in the preset) stop pairs that a single
field shows to be different people from auto-matching, however well the rest
agrees: different SSNs, birth years decades apart, JR vs SR, twins, siblings
(same surname, unrelated given names and birth dates), newborn
labels with different birth orders or dates, a missing DOB, and Jan-1 birthdays
with nothing else in common. A fired guard subtracts its penalty from the weight
and caps the probability just below the match threshold; the pair lists the
reasons under `:guards`. These pairs are mostly family members, whose shared
surname, address and phone would otherwise outweigh the conflict.

Two unnamed newborn records need an agreeing source/MRN before auto-matching.
Adults with unfamiliar given-name differences and the same surname/DOB go to
review without the stronger child-twin penalty. Uncertain one-edit name typos
need both an agreeing SSN fragment and phone to clear that ambiguity.
A shared SSN cannot override unrelated names and incompatible birthdays. Exact
full names with incompatible birthdays need corroboration. Child records with
an exact name/DOB and agreeing phone or street/ZIP may carry a guarantor's SSN.

`link/4` and `dedupe/3` also return `record_review`: records with no usable name,
DOB, SSN, contact or source/MRN are flagged with `reason: :insufficient_identity`.
Each entry contains the record's `id` and `side` (`:left`, `:right`, or `:single`).
This queue asks for more information; it contains no proposed matching pairs
and does not contribute to pair recall.

The preset also sends exact full-name + DOB agreements to review when both names
occur in at least 0.4% of training rows and no SSN (full or last four), phone,
ZIP or street agrees. This model-frequency policy reports
`:common_name_uncorroborated` and also prevents cluster chaining. Same-source
MRN agreement clears this policy, but other conflict guards still apply.
Set `common_name_frequency` to another fraction in `(0, 1]`, or `nil` to disable
it. Unseen names are not classified as common. Custom configs default to `nil`.
The policy collects both name frequencies even when TF scoring is disabled.

Same non-nil normalized source and MRN bypass blocking and score probability 1,
weight 50, reason `:mrn`, unless a guard fires: the pair is then scored
statistically with reason `:mrn_conflict`, which catches MRN overlays.

`explain/3` always populates winning levels, including MRN overrides. Statistical
weights sum the prior log2 odds, non-null log2(m/u), exact-level TF terms
log2(u_exact / tf(value)), and guard penalties. TF uses count(value) / total
training rows; a value unseen in training counts as seen once. Null weights are
zero.

`dedupe/3` forces within-file pairs and adds clusters formed from match edges,
strongest first; two clusters are not joined if a guard fires between any of
their members (`rejected_edges`). Singleton records are omitted. `assign/1`
greedily keeps the highest probability pairs while using neither id twice. Keep
ids distinct across files when using this shared-id assignment rule.

## Configuration and training

The preset (`PatientMatching.Presets.patient_mpi/1`) compares:

- family name: exact (TF), JW >= 0.92, compound/hyphenated/particle surname, JW >= 0.85
- given name: exact (TF), nickname, JW >= 0.92, name part (THI LAN / LAN), initial, JW >= 0.85
- name order: given and family swapped
- DOB: exact (TF), month/day swapped, within one day, one-digit typo, same year/month
- sex: exact
- contact, over ZIP, phone and street together: phone and ZIP, phone, street
  and ZIP, building and ZIP (same street, unit on only one side), ZIP, ZIP3 or
  last seven phone digits. Household members share all
  three, so they are scored jointly rather than as independent evidence.
- SSN, over full and last-four-only values: exact, one typo, last four

All have a first null and last else level. A `%Comparison{}` may read several
normalized fields with `fields: [...]`; its matchers then receive tuples.

Prediction blocking is an OR of:

- Family Soundex + DOB year.
- First three given-name characters + ZIP.
- Full phone.
- SSN last four + DOB year.
- Full DOB.
- Given-name Soundex + family Soundex.

A nil key skips its rule. Blocks larger than `max_block_size` (default 500) are
omitted and counted by rule, with only rule indices, hashes and counts logged. MRN matches bypass this
limit.

`Presets.patient_mpi(overrides)` and `PatientMatching.config(options)` accept
comparison/rule overrides plus `link_type` (default `:link_only`), thresholds,
`lambda_recall` (0.7), `u_sample_size` (100_000), `em_max_iters` (25), `em_tol`
(1e-4), `seed` (1), `max_block_size` (500), `training_block_size` (200),
`placeholders`, `guards`, `strip_mrn_leading_zeros` (true), and
`common_name_frequency` (0.004 in the preset, nil in custom configs).
To disable every guard and the frequency policy, set `guards: []` and
`common_name_frequency: nil`. Key functions receive a normalized record. Derived
key atoms are `:family_soundex`, `:given_soundex`, `:given_name3`, `:dob_year`,
and `:ssn_last4`; other atoms (including `:dob`) read normalized fields.

Training takes one file, using unordered within-file pairs even for a
`:link_only` config. It estimates:

1. The prior: the probability that two random records are the same patient,
   from the union of exact given/family/DOB pairs and exact SSN pairs over all
   n(n-1)/2 pairs, divided by `lambda_recall`. This matches `u`, which is also
   estimated from random pairs. `train/3` accepts `lambda: value` to fix it.
2. `u` from seeded, unblocked random pairs without replacement, leaving out
   pairs that agree deterministically; if the requested sample exceeds the
   pair population, all pairs are used. Null observations are excluded per
   field. TF counts use training records only.
3. `m` by EM, one session per `training_blocking` rule. Each session estimates
   its own prior within its blocks and the `m` of every comparison whose fields
   its rule does not block on; each field's `m` is averaged over the sessions
   that estimated it. The preset trains on DOB year and on family Soundex +
   given-name prefix. Blocks larger than `training_block_size` are sampled.
   Nulls are excluded from each field's denominator. Exact levels with
   `m <= u` trigger a field-wide fallback and `trained.unstable: true`.

The prior is clamped to 1e-9..0.5; estimated masses are floored at 1e-6 and
normalized while retaining that floor. Initial strong/moderate/year-month
masses are 0.9/0.7/0.5, and rarer variant levels (nickname, typo, swap) start
at 0.05. If their sum exceeds one, normalize them with a floored else
remainder. Unknown custom levels start at 0.5. Override masses with
`m_init: %{field => %{level => mass}}`. An all-null `u` distribution starts
uniform; absent non-null EM observations preserve initial `m`.
`model.trained` reports `lambda_source`, the per-session `lambda_train`,
`em_iters`, `unstable` and `tf_records`, plus `m_prior`, `m_prior_strength`
and `m_prior_base_weight` (see below).

### Supervised m prior

Reviewer label counts can steer m instead of leaving it to EM alone:

```elixir
PatientMatching.train(records, config,
  m_prior: %{given_name: %{exact: 40, nickname: 6, jw_0_92: 3, else: 1}},
  m_prior_strength: 1.0
)
```

`:m_prior` maps field => non-null level => count (missing levels count 0).
`:m_prior_strength` (>= 0, default 1.0) scales the counts;
`:m_prior_base_weight` (`k` > 0, default 10.0) weights the default start.

- **Blended start.** An active field (total count times strength above 0)
  starts at `distribution((k*base + strength*prior) / (k + strength*total))`,
  where `base` is the defaults merged with `m_init`.
- **M-step.** Each M-step adds `strength * prior` pseudo-counts to the
  expected match counts, only in sessions that estimate the field and observe it.
- **Lambda** moves only through m; the prior never enters its update.
- **Unstable fields** revert to the blended start, not the defaults.
- **`trained` keys.** `m_prior` (raw totals before strength, nonzero fields
  only), `m_prior_strength` and `m_prior_base_weight`. Dumps include them;
  older dumps load with `%{}`, 1.0 and 10.0.

`PatientMatching.comparison_signature/1` (config or model) returns the
ordered comparison signature. `explain/3` returns one level per comparison,
in config order, including nulls, even under an MRN override.

Any change to a matcher's behaviour, even one that keeps the same level name,
bumps the minor version. Consumers key stored level counts on (comparison
signature, library version).

Training raises `ArgumentError` for duplicate ids, fewer than two records,
missing comparisons, or no training candidates.

## Custom comparisons

No preset is required:

```elixir
alias PatientMatching.{Comparison, Comparators, Level}
comparison = %Comparison{field: :family_name, levels: [
  %Level{name: :null, null_level?: true},
  %Level{name: :exact, match?: &Comparators.exact?/2, tf?: true},
  %Level{name: :else}
]}
config = PatientMatching.config(
  comparisons: [comparison], blocking: [[:family_name]],
  training_blocking: [[:dob_year]]
)
```

Ordered predicates receive normalized values; first true wins. Null and else
semantics are enforced by the runner. A TF level must use the exact equality
capture above; arbitrary predicate functions cannot certify equality. The EM
instability fallback identifies exact-style levels by this capture or the
reserved `:exact` / `:dob_exact` names. Use these names for custom non-TF equality
predicates; arbitrary renamed predicates cannot be inferred as exact-style.

## Saving models

`dump/1` returns versioned Jason JSON containing parameters, level names/flags,
and term frequencies. Version 3 also records MRN normalization and the
common-name frequency policy. Matcher/blocking functions are not serialized.
`load(json, original_config)` reattaches them from the supplied config and
validates the comparison shape, probability data, and both policy settings.
Version 2 dumps still load with zero stripping enabled; the supplied common-name
policy is applied. Version 1 dumps do not load. Supply the same predicate
semantics; level names alone cannot verify function equivalence.

## Development

```sh
mix deps.get
mix check
mix precommit
```

`mix check` runs compilation with warnings as errors, unused dependency cleanup,
format validation, strict Credo (including ExDNA duplication checks and ExSlop),
Doctor documentation coverage, Sobelow security analysis, Dialyzer, and the test
suite. `mix precommit` runs the same checks. Both select the test environment.

Merging a matcher change? Check:

- [ ] Bump the minor version in `mix.exs` and note it in `CHANGELOG.md`, even
  if level names are unchanged.

Quality tools are development/test dependencies with `runtime: false`. Their
current ExDNA/ExSlop versions require Elixir 1.18 or later for development;
the library's runtime requirement remains Elixir 1.17 or later. The initial
Dialyzer run builds a cached PLT under `priv/plts/`, excluded from version control.
Doctor enforces at least 80% documentation coverage and 100% module documentation
coverage; test/support modules are excluded. Sobelow may report that this library
has no Phoenix router; it still scans the source and fails on security findings.

The suite uses synthetic records only and covers the ten acceptance gates,
including EM recovery, planted-pair quality, blocking reduction, null isolation,
log hygiene, and serialization. No SQL backend, external matching service,
supervised classifier, or Hex publishing is included.

`eval/` holds a dev-only synthetic evaluation harness. `mix eval.gen` explicitly
creates persistent datasets; `mix eval.validate` assesses integrity/coverage;
`mix eval.run` evaluates the committed population. Generate the fixed extended
bundle with `mix eval.gen --benchmark --out eval/data/benchmark`, then evaluate
it independently with `mix eval.benchmark --datasets eval/data/benchmark`.
Validation and evaluation never regenerate datasets. See [eval/README.md](eval/README.md).

### Reference m without EM

Use `PatientMatching.train(records, config, m_estimation: :prior,
m_init: reference_m, lambda: 0.001)` on a deduplicated patient file. This mode
requires a fixed `:lambda`, skips EM and does not require training candidates.
It estimates u and term frequencies normally. With no `:m_prior`, m is exactly
the default base merged with `:m_init`; counts blend into that base using the
usual `:m_prior_strength` and `:m_prior_base_weight` options. Training metadata
and dumps record `m_estimation: :prior` (the default mode is `:em`).

`PatientMatching.put_lambda(model, 0.001)` returns a model with a new fixed
prior, clamped to 1e-9..0.5, without retraining. Dump/load preserves the new
prior and `trained.lambda_source: :fixed`; explanations use it immediately.

The child twin guard includes birth dates at most one day apart. The household
look-alike guard requires the same family name, similar but different given
names that are not variants, birth dates more than one day apart, and an
agreeing phone or street/ZIP. It caps probability below automatic matching.
A same-child pair with an unchanged given name and a one-day date error keeps
scoring normally.
