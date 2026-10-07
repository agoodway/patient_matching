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
    sex: "F", zip: "02139", phone: "2125550101", ssn: "123456789"},
  %{id: "a2", given_name: "Brian", family_name: "Sample", dob: "1980-06-12",
    sex: "M", zip: "10001", phone: "2125550102", ssn: "234567890"},
  %{id: "a3", given_name: "Carol", family_name: "Fiction", dob: "1980-09-15",
    sex: "F", zip: "60601", phone: "3125550103", ssn: "345678901"}
]
right = [
  %{id: "b1", given_name: "Alicx", family_name: "Example", dob: "1980-01-10",
    sex: "F", zip: "02139", phone: "5550101", ssn: "123456789"},
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
IDs may be any Elixir term. The caller's maps are preserved. Comparisons read a
normalized copy: uppercase text without punctuation, parsed dates, digit-only
phone/SSN, five-digit ZIP. Missing, empty, invalid values become nil; nil never
counts as agreement. MALE/FEMALE become M/F; other sex values stay uppercase.

Defaults: match probability >= 0.95; non-match <= 0.20; otherwise review.
Override either threshold in `link/4` or `dedupe/3`. Results contain matches and
review pairs, a count of scored non-matches, and `dropped_blocks`. Unblocked
pairs are unscored. Pair maps have `left_id`, `right_id`, `probability`, `weight`,
and `reason`. Same non-nil normalized source and MRN bypass blocking and score
as probability 1, weight 50, reason `:mrn`.

`explain/3` always populates winning levels, including MRN overrides. Statistical
weights sum the prior log2 odds, non-null log2(m/u), and exact-level TF terms
log2(u_exact / max(tf(value), 1e-6)). TF uses count(value) / total training rows;
rare values receive more weight. Null weights are zero. MRN overrides replace
the final probability and total weight, while retaining the statistical breakdown.

`dedupe/3` forces within-file pairs and adds clusters formed from match edges
only; singleton records are omitted. `assign/1` greedily keeps the highest
probability pairs while using neither id twice. Keep ids distinct across files
when using this shared-id assignment rule.

## Configuration and training

The preset compares family/given names (exact, JW >= 0.92, JW >= 0.85), DOB
(exact, within one day, same year/month), sex (exact), ZIP (exact, zip3), phone
(exact, last7), and SSN (exact, last4). All have a first null and last else level.
Only exact name levels apply TF.

Prediction blocking is an OR of:

- Family Soundex + DOB year.
- First three given-name characters + ZIP.
- Full phone.
- SSN last four + DOB year.

Training blocks only on DOB year, leaving name `m` unblocked on name. A nil key
skips its rule. Blocks larger than `max_block_size` (default 500) are omitted and
counted, with only hashes/counts logged. MRN matches bypass this limit.

`Presets.patient_mpi(overrides)` and `PatientMatching.config(options)` accept
comparison/rule overrides plus `link_type` (default `:link_only`), thresholds,
`lambda_recall` (0.7), `u_sample_size` (100_000), `em_max_iters` (25), `em_tol`
(1e-4), `seed` (1), and `max_block_size` (500). Key functions receive a normalized
record. Derived key atoms are `:family_soundex`, `:given_name3`, `:dob_year`, and
`:ssn_last4`; other atoms read normalized fields.

Training takes one file, using unordered within-file pairs even for a
`:link_only` config. It separately estimates:

1. A rough prior from the union of exact given/family/DOB pairs and exact SSN
   pairs, divided by prediction candidate count and estimated recall. This is
   a prior estimate, not a likelihood. `train/3` accepts `lambda: value` to fix it.
2. `u` from seeded, unblocked random pairs without replacement; if the requested
   sample exceeds the pair population, all pairs are used. Null observations
   are excluded per field. TF counts use training records only.
3. `m` from aggregated comparison patterns using EM with `u` and lambda fixed.
   Nulls are excluded from each field's denominator. Exact levels with `m <= u`
   trigger a field-wide fallback and `trained.unstable: true`.

The prior is clamped to 1e-6..0.5; estimated masses are floored at 1e-6 and
normalized while retaining that floor. Initial strong/moderate/year-month
masses are 0.9/0.7/0.5. If their sum exceeds one, normalize them with a floored
else remainder. Unknown custom levels start at 0.5. Override masses with
`m_init: %{field => %{level => mass}}`. An all-null `u` distribution starts
uniform; absent non-null EM observations preserve initial `m`.

Training raises `ArgumentError` for duplicate ids, fewer than two records,
missing comparisons, or no prediction/training candidates. Use training rules
that do not condition on the fields whose `m` you need to estimate.

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
log hygiene, and serialization. No SQL backend, nickname tables, external
matching service, supervised classifier, or Hex publishing is included.
