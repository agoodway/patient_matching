# Eval suite

An evaluation harness for `patient_matching` built on synthetic patients from a
realistic, diverse large US metro (modeled on Houston / Harris County, TX).
It reports quality only and never fails on a metric. Nothing here ships in the
package: `eval/lib` compiles in `:dev` only.

```sh
mix eval.run                       # all runs + golden scenarios (~4 min)
mix eval.run --run pharmacy_x_payer
mix eval.run --golden-only
mix eval.run --save-baseline       # later runs print deltas against eval/baseline.json
mix eval.gen --people 4000         # regenerate the population (deterministic per --seed)
mix eval.refdata                   # re-download the public name tables (network)
```

## What it measures

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
- **Threshold sweep, field weights, and examples.** For dedupe runs, also clusters: overlays, chaining and B³. For link runs, also one-to-one `assign/1` quality.

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
| `manifest.json` | seed, counts, tag frequencies |

The default is 4,000 people (about 9,000 records), a size that keeps
`mix eval.run` to a few minutes. Larger populations work (`--people 50000`),
but `dedupe/3` scoring time grows roughly quadratically with file size today.

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

## Extending

- **Golden case:** add an object to the relevant `eval/scenarios/*.json` file,
  or a new file with its own `category`.
- **New corruption or life event:** add it in
  `lib/patient_matching_eval/records.ex` or `population.ex` and give it a tag.
  It appears in the tag table automatically.
- **New run:** add it to `suite.json`. A run can set
  `"train": {"lambda": ...}` to a number or `"oracle"`.

Ground truth exists only in this directory. The matcher never sees `truth.jsonl` or `people.jsonl`.
