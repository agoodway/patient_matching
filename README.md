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
- **SSN:** nine digits; a four-digit value is kept as `:ssn_partial` for
  last-four comparison and blocking.
- **MRN:** alphanumeric, leading zeros after any letter prefix ignored.
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
review pairs, a count of scored non-matches, and `dropped_blocks`. Unblocked
pairs are unscored. Pair maps have `left_id`, `right_id`, `probability`, `weight`,
`reason` and `guards`.

**Guards** (`PatientMatching.Guards`, on in the preset) stop pairs that a single
field shows to be different people from auto-matching, however well the rest
agrees: different SSNs, birth years decades apart, JR vs SR, twins, newborn
labels with different birth orders or dates, a missing DOB, and Jan-1 birthdays
with nothing else in common. A fired guard subtracts its penalty from the weight
and caps the probability just below the match threshold; the pair lists the
reasons under `:guards`. These pairs are mostly family members, whose shared
surname, address and phone would otherwise outweigh the conflict.

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
  and ZIP, ZIP, ZIP3 or last seven phone digits. Household members share all
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
omitted and counted, with only hashes/counts logged. MRN matches bypass this
limit.

`Presets.patient_mpi(overrides)` and `PatientMatching.config(options)` accept
comparison/rule overrides plus `link_type` (default `:link_only`), thresholds,
`lambda_recall` (0.7), `u_sample_size` (100_000), `em_max_iters` (25), `em_tol`
(1e-4), `seed` (1), `max_block_size` (500), `training_block_size` (200),
`placeholders` and `guards`. Key functions receive a normalized record. Derived
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
`em_iters`, `unstable` and `tf_records`.

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
and term frequencies. Matcher/blocking functions are not serialized.
`load(json, original_config)` reattaches them from the supplied config and
validates the comparison shape and probability data. Supply the same predicate
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

`eval/` holds a report-only evaluation suite on a synthetic, diverse
large-metro population (dev only, not packaged). See `eval/README.md`.
