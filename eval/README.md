# Eval suite

The dev-only harness separates explicit dataset generation, dataset quality
assessment, and matcher evaluation. All records are synthetic. The configured
metro assumptions approximate Houston / Harris County; demographic agreement
with those assumptions does not establish real-world representativeness.
Adjudicated real-world validation remains deferred.

```sh
mix eval.run                         # quick evaluation of the committed population
mix eval.validate --population eval/data/population
mix eval.gen --people 4000 --seed 2026 --out eval/data/population --force
mix eval.gen --benchmark --out eval/data/benchmark
mix eval.validate --datasets eval/data/benchmark
mix eval.benchmark --datasets eval/data/benchmark
mix eval.test                        # dev-only harness regression tests
mix check                            # library checks and test suite
```

Generation is a maintenance action. Validation and evaluation only read stored
datasets; neither invokes generation or changes dataset bytes. Missing inputs
produce an error with a generation command. Any existing generation destination
requires `--force` to replace it; unrelated directories cannot be replaced.
Generated rows are validated before writing.

Existing evaluation options remain available: `--run NAME` (repeatable),
`--golden-only`, `--no-golden`, `--population DIR`, `--json PATH`,
`--save-baseline`, and opt-in `--check`. Benchmark evaluation supports run/golden
selection and `--json`; all its matcher quality and golden failures are
reporting-only. Default reports are under ignored `eval/results/`, separate
from dataset files. Report paths resolving into input datasets are rejected.

Baseline reports record the three population JSONL hashes. Deltas appear only
when those hashes match exactly. Older baselines without hashes are labeled
`unverified`; another population is labeled `different_dataset`. Changing the
dataset requires reviewing new results and explicitly saving a new baseline:
`mix eval.run --save-baseline`. Baseline refresh does not adjust acceptance
budgets or matcher policies.

## Stored benchmark bundle

`mix eval.gen --benchmark` generates fixed, independent populations:

| role | people | seed |
|---|---:|---:|
| primary | 50,000 | 2026 |
| holdout_2027 | 10,000 | 2027 |
| holdout_2028 | 10,000 | 2028 |
| challenges | 1,600 pairs | 2029 |

`index.json` identifies relative dataset paths, roles, seeds, population targets,
output hashes and manifest hashes. Benchmark populations have exact counts;
relationships to people omitted at the final household boundary are cleared.
Ordinary population generation preserves complete households and can slightly
exceed its requested target. `--benchmark` cannot be combined with `--people`
or `--seed`. The generated benchmark bundle is Git-ignored; the small default
population stays committed.

Every population trains each selected suite entry on its own input. Reports
retain population results individually and give minimum/maximum metrics per
run, without pooling populations. Challenge pairs stay separate and use the
enterprise model trained on the committed default population; reports include
both challenge and training dataset hashes.

Eight challenge families cover borrowed SSNs, placeholder DOBs, missing
names/DOB, reused MRNs, common-name/DOB collisions, twins, newborns and
independent aliases. Each family has 100 same-person and 100 different-person
pairs, half sparse and half corroborated. IDs remain globally unique even when
MRNs are intentionally shared. Quotas, required fields and family evidence are
validated. Pair outcomes, same/different-person denominators and per-variant
results are reported separately from ordinary population metrics.

Some sparse `missing_identity` cases have no useful identifying field left.
The matcher flags these records in `record_review` for information gathering.
Challenge reports show `information_review_cases` and
`informationless_true_pairs`, alongside the unchanged pair outcomes and
`pair_expectation_failures`. Information review does not locate a pair and
does not count toward `found_with_review` or pair recall. The separate
`handling_pass` / `handling_failures` measure accepts a correct information
flag with no suggested matching pair as successful handling. Usable-identity
misses and wrong auto-matches remain handling failures. A successful refusal
to guess still leaves the original same-person pair expectation unmet;
reports retain that failure explicitly.

The plan supplied for implementation omitted the referenced ten alias mappings.
The fallback table in `curated/evaluation_aliases.csv` is independent of the
matcher's nickname table: ALEXANDER→SASHA, ALEXANDRA→SASHA,
ELIZABETH→LIBBY, MARGARET→DAISY, SARAH→SALLY, HENRY→HANK,
JAMES→JEM, JOHN→IAN, FRANCISCO→KIKO, IGNACIO→NACIO. These pairs are
tagged `evaluation_only_alias`; the matcher table remains unchanged.

## Dataset quality

`mix eval.validate` checks duplicate IDs, record/truth set equality, required
metadata, dangling references, canonical truth attributes and snapshot ages,
self-relations, reciprocal spouse/twin links, equal twin DOBs, snapshots before
birth, and parent roles in this synthetic model. Absent parents remain `nil`;
a male-only parent occupies the father role. Newborns without a modeled mother
use the child's surname. People without records and intentionally shared
identifiers are valid.

Coverage reports include missingness by source, records per person (including
zero), source overlap, relationships, identifier collisions, tag frequencies,
demographic distributions and differences from configured group shares. Counts
of distinct people and true pairs accompany condition support. Fewer than 100
true pairs is `low-support`; absent conditions are explicitly `zero-support`.
Sparse ordinary slices warn; structural errors, hash mismatches and missing
challenge quotas fail. Manifests include generator version, reference date,
parameters, static input hashes and output hashes. Structurally valid legacy
population manifests are accepted with a provenance warning.

## Regenerated default results

The generator-v2 default has 4,000 people and 8,809 records. Before the matcher
fixes it reported 99.678% auto-match precision, 96.053% recall, 99.287% recall
including review, 27 false matches and six overlay clusters. After the fixes,
on those same stored records, enterprise dedupe reports 99.728% precision,
97.054% recall, 99.390% recall including review, 23 false matches and four
overlay clusters. All 83 golden scenarios and the unchanged `--check` budgets
pass; the nine previously failing acceptance checks are cleared. The baseline
stores dataset hashes. These comparisons use identical inputs; the historical
pre-generator-v2 population is a different dataset.

The fixes cover newborn ambiguity, borrowed identifiers, adult name ambiguity,
name typos corroborated by an SSN fragment and phone, child records with a
guarantor's SSN, and matching full names with incompatible birth dates. Thresholds, acceptance
budgets, golden expectations and the matcher's nickname table are unchanged.
Ordinary quality reports and benchmark runs remain reporting-only; remaining
wrong matches and misses stay visible.

## Extended benchmark results

Generator-v2 bundle, evaluated independently after the matcher fixes:

| population | records | enterprise precision | auto recall | recall + review | false matches |
|---|---:|---:|---:|---:|---:|
| primary | 110,866 | 98.775% | 96.910% | 99.121% | 1,312 |
| holdout_2027 | 22,316 | 99.232% | 96.975% | 99.263% | 167 |
| holdout_2028 | 22,290 | 99.465% | 97.141% | 99.226% | 116 |

All seven suite entries were evaluated on each population. Golden scenarios pass
83/83 on all three, including the previously failing seed-2027
`common-name-khan` overlay case. Enterprise false matches fell from
1,347/182/123 to 1,312/167/116 on identical datasets. Wrong matches remain,
especially at the larger scale; these synthetic measurements are not a claim
of real-world readiness.

The separate challenge report improves from 164 to 17 pair expectation
failures out of 1,600 cases. All 17 remaining same-person failures lack any
usable identity on one side. Along with their 17 different-person counterparts,
these 34 cases are flagged for information gathering; none produces a proposed
matching pair. They remain in the denominators and still have zero pair recall.
All 1,600 cases have successful handling, with zero `handling_failures`; the
17 pair expectation failures remain visible separately.
Thresholds, budgets, golden expectations and stored datasets are unchanged.
See `eval/results/fixes-benchmark-final.json` for individual population metrics,
minimum/maximum summaries, challenge outcomes, information-review details and
dataset/training hashes. Generated reports are intentionally ignored by Git.

## What it measures

`suite.json` defines inclusive `min` / `max` acceptance limits under each run's
`acceptance` map, plus suite-wide golden limits. `--check` checks the selected
runs and requires golden results; `--golden-only --check` checks just golden
limits. Unknown run names and missing metrics fail. The JSON report is written
before acceptance failure, and a failed check cannot save a new baseline.

The optional acceptance budgets in `suite.json` were set against the previous
committed population. They require all 83 golden cases to pass and bound false
matches, precision/recall and cluster quality. These budgets are synthetic
regression limits, not universal accuracy targets. `--check` enforces them;
normal evaluation reports results even when a budget or golden case fails.
Largest cluster size is diagnostic because one true person may have many records.
Every prediction rule's dropped-block count is reported, including zero counts.

`eval/suite.json` defines the runs. Each run trains its own model with
`Presets.patient_mpi()` on its own input, as a caller would:

| run | kind | models |
|---|---|---|
| `enterprise_mpi` | dedupe | all six sources in one master patient index |
| `enterprise_mpi_oracle_lambda` | dedupe | same, prior fixed to the true random-pair match rate (diagnostic) |
| `county_hospital_duplicates` | dedupe | duplicate registrations inside one safety-net hospital |
| `hospital_a_x_county_hospital` | link | HIE between a private system and the county system |
| `county_hospital_x_fqhc` | link | safety-net referrals to community clinics |
| `reference_lab_x_hospital_a` | link | outside lab results onto hospital charts |
| `pharmacy_x_payer` | link | dispensing vs. claims |

Each run reports:

- **Blocking recall:** how many true pairs ever became candidates.
- **Auto-match decisions:** precision, recall and F1 at the model's thresholds, plus review load and recall including review.
- **Missed true pairs by stage:** unblocked, scored non-match, or sent to review.
- **False matches by relationship:** twins, Jr/Sr, spouses, parent/child, siblings, borrowed or guarantor SSN, placeholder values, Jan-1 birthdays, or unrelated lookalikes.
- **Recall by data-quality tag:** each record carries the corruptions applied to it.
- **Slices:** recall and false-match rate by ethnicity, origin, foreign-born status and age band.
- **Guards:** for each guard, how many scored pairs it fired on, split into
  different people and the same person.
- **Threshold sweep, field weights, and examples.** For dedupe runs, also clusters: overlays, chaining, rejected joins and B³. For link runs, also one-to-one `assign/1` quality.

The golden scenarios in `eval/scenarios/*.json` are about 80 hand-written cases,
one file per category. Each case states why it exists, its risk, and the
expected outcome. `overlay` risk means a wrong merge of two patients;
`duplicate` risk means a split chart. They are scored with the
`enterprise_mpi` model, so term frequencies and m/u reflect the metro.
Expectations are `match`, `match_or_review`, `review`, `not_match` (review is
acceptable) and `non_match`. Cluster cases list the groups that should end up
together.

## The synthetic population

`mix eval.gen` builds people in households, then gives each person MRNs in the
sources they would plausibly use, with each MRN snapshotted at its last update.

**People and households**
- Ethnic mix is the Harris County 2020 census mix. Each group has a rough age
  pyramid and a sub-origin mix: Mexican and Central American, Vietnamese,
  Chinese, Indian, Pakistani, Filipino, Korean, Nigerian, Middle Eastern, and
  others. Each sub-origin has its own foreign-born rate.
- Households have spouses (with intermarriage), children, elders, twins and
  Jr/Sr namesakes.
- ZIPs are about 120 real Houston-area ZIPs, weighted by population and
  approximate ethnic composition, so common names cluster geographically the
  way they do in reality.

**Names**
- US-born given names come from SSA birth-cohort frequencies, reweighted by
  ethnicity using Tzioumis first-name shares. Foreign-born given names come
  from curated per-origin lists.
- Surnames come from Census 2010 ethnicity shares, or from curated per-origin
  lists (about 38% of Vietnamese are NGUYEN). Middle names include Vietnamese
  VAN/THI, Hispanic compound given names, and adopted English names.
- Life events change identity over time: married and hyphenated surnames,
  Spanish paternal + maternal compound surnames for children, moves, and
  phone churn.

**Identifiers**
- Most people have SSNs. Some have ITINs, borrowed SSNs, or no SSN at all.
- Some foreign-born people have a Jan-1 placeholder birthday.
- Children are registered with a parent's phone and sometimes the
  guarantor's SSN.

**Source profiles** (`curated/sources.json`) set each source's:
- Reach by insurance status and duplicate-registration rate.
- Formats for DOB, phone, sex, SSN and ZIP.
- Capture rates.
- Error rates: typos, nicknames, transliterations, accents, particle spacing,
  compound-surname truncation, name swaps, fixed-width truncation, DOB typos
  and swaps, placeholders, newborn `BABY GIRL` names, and ER trauma aliases.

Every deviation is written as a tag on the record's truth row.

Files in `eval/data/population` (committed, regenerated deterministically):

| file | contents |
|---|---|
| `records.jsonl` | what the matcher sees (library field names only) |
| `truth.jsonl` | per record: `person_id`, household, group, origin, age at snapshot, tags |
| `people.jsonl` | per person: identity history and relationships (spouse, mother, father, twin, junior_of, ssn_lender) |
| `manifest.json` | version, reference date, parameters, input/output hashes, counts, tags |

The committed default is 4,000 people and 8,809 records. Larger populations
can be generated explicitly with `mix eval.gen --people 50000 --out DIR`. Pass
`--population DIR` to `mix eval.run` to evaluate one, for example a second
population generated with a different `--seed` as a holdout.

## Data provenance

`eval/data/reference/` holds public tables trimmed by `mix eval.refdata`:

- `surnames.csv`: U.S. Census Bureau, 2010 surnames with race/Hispanic-origin
  percentages, names with at least 300 bearers (94% of people). Public domain.
  Suppressed `(S)` cells are spread evenly over the unexplained share.
- `given_names.csv`: SSA national baby names 1925–2010, aggregated to
  five-year cohorts, with at least 50 births per cohort. Public domain. It is
  fetched from the `wesm/pydata-book` mirror because ssa.gov rejects scripted
  downloads. Births after 2010 reuse the 2010 cohort.
- `first_name_ethnicity.csv`: Tzioumis, K. (2018), *Demographic aspects of
  first names*, Harvard Dataverse, doi:10.7910/DVN/TYJKEZ. CC0.

`eval/data/curated/` is hand-curated and approximate:

- `metro.json`: ZIP shares, age shapes, origin mixes, rates.
- `sources.json`
- Origin given-name and surname lists.
- Nicknames, spelling variants and accents.

The Census API now requires a key, so ZIP-level composition was not pulled
from ACS.

The library's nickname table (`PatientMatching.Nicknames`) was built from
`curated/nicknames.csv`, the same list the generator draws nicknames from, so
nickname results here are optimistic.

## Extending

- **Golden case:** add an object to the relevant `eval/scenarios/*.json` file,
  or a new file with its own `category`.
- **New corruption or life event:** add it in
  `eval/lib/patient_matching_eval/records.ex` or `population.ex` and give it a tag.
  It appears in the tag table automatically.
- **New run:** add it to `suite.json`. A run can set
  `"train": {"lambda": ...}` to a number or `"oracle"`.

Ground truth exists only in this directory. The matcher never sees `truth.jsonl` or `people.jsonl`.
