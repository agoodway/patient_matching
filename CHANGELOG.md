# Changelog

## Unreleased

The initial matching-policy improvements were measured by the evaluation suite (`eval/`, dev only). On its synthetic
Houston-area population (9,015 records, 6 sources), enterprise dedupe went
from 57.6% to 99.7% auto-match precision at 96.3% recall, blocking recall from
87.5% to 99.8%, wrongly merged clusters from 525 to 8, and golden scenarios
from 54/83 to 83/83. On a separate seed-2027 population, the new policy gives
99.8% precision and 95.8% auto-match recall (99.4% including review).

Dataset generator v2 fixes single-parent roles and twin DOB consistency. The
explicitly regenerated default has 4,000 people / 8,809 records; enterprise
precision is 99.678%, recall 96.053% (99.287% including review), with 27 false
matches, six overlay clusters and 83/83 passing golden cases. The changed dataset
has a refreshed hash-bearing baseline; the historical figures above describe
the previous population and are not baseline deltas.

Matcher fixes on the same generator-v2 default clear all nine failing acceptance
checks: enterprise precision is now 99.728%, recall 97.054% (99.390% including
review), with 23 false matches, four overlay clusters and 83/83 golden scenarios.
Newborn ambiguity, borrowed identifiers and mismatched DOBs require review;
adult aliases retain review evidence, uncertain name typos need an agreeing
SSN fragment and phone, and corroborated child records may carry a guarantor's
SSN. Thresholds, budgets,
golden expectations and nickname mappings are unchanged. Records with no usable
identity now appear in a separate `record_review` information-gathering queue;
that queue does not count as finding a matching pair.

### Breaking

- **Prior.** `lambda` is now the probability that two random records match
  (deterministic agreements over n(n-1)/2 pairs), not over prediction
  candidates. Expect values around 1e-4 rather than 0.3–0.5. The clamp is now
  1e-9..0.5. Training no longer requires prediction candidates.
- **EM** estimates its own prior within the training blocks and runs once per
  `training_blocking` rule, skipping the fields each rule blocks on.
  `estimate_m/4` takes `:fields` and `:lambda_train` options.
- **Normalization.**
  - Names fold accents and keep letters only (`DE LA CRUZ` is `DELACRUZ`).
  - Generational suffixes move to `:suffix`, and given-name middle initials
    are dropped.
  - Placeholder values become nil (see `PatientMatching.Placeholders` and the
    `:placeholders` option).
  - Unknown and numeric sex codes are nil.
  - Phone drops a leading `1` and extensions.
  - MRN leading zeros are ignored by default; `strip_mrn_leading_zeros: false`
    preserves them consistently during training, blocking and scoring.
  - Streets use USPS Publication 28 standard form by word position:
    suffix and directionals abbreviated, name words kept, one `UNIT` marker
    after the street for every unit designator, and `PO BOX`, `RR` or `HC`
    box lines. Tests run against 9,035 labeled addresses from
    datamade/usaddress (MIT, `test/fixtures/usaddress`).
- **Preset.**
  - New comparisons and levels: `contact` (ZIP, phone and street together)
    replaces `zip` and `phone`; `name_order` is new; and the name, DOB and SSN
    comparisons gain variant levels.
  - Two new prediction blocking rules (`[:dob]` and
    `[:given_soundex, :family_soundex]`), and training blocking
    `[[:dob_year], [:family_soundex, :given_name3]]`.
  - Guards are on.
  - The `contact` comparison gains `building_and_zip` (same street and ZIP,
    unit on one side only), so models saved before it must be retrained.
- **Results.** Pairs carry `:guards`. `dedupe/3` also returns `rejected_edges`.
  A same-source MRN agreement is overridden by a guard (reason `:mrn_conflict`).
- **Model dumps** are version 3, recording MRN normalization and the common-name
  frequency policy. Incompatible policies fail loading. Version 2 dumps still
  load with zero stripping enabled; version 1 dumps no longer load.

### Added

- Explicit persistent generation with overwrite protection and provenance hashes;
  `mix eval.validate` for structural/coverage assessment and `mix eval.benchmark`
  for the fixed 50k/10k/10k synthetic bundle plus 1,600 separate challenge pairs.
- Independent evaluation aliases, dataset-hash-gated baseline deltas, low/zero
  support diagnostics, and dev-only `mix eval.test` regression coverage.


- `dropped_blocks_by_rule` in blocking, link and dedupe results, with zero-based
  rule indices also included in block-drop logs and evaluation reports.
- A configurable common-name frequency policy in the preset: exact full name
  and DOB without corroboration goes to review and cannot chain clusters.
- `mix eval.run --check` enforces explicit golden and run-quality regression
  budgets. Legitimate clusters larger than five remain allowed.

- `PatientMatching.Guards`: SSN, DOB, generation suffix, twin, sex + given name,
  newborn birth order and birth date conflicts, missing DOB, and
  uncorroborated Jan-1 birthdays. Each guard subtracts a penalty and caps the
  probability below the match threshold.
- Guarded clustering in `dedupe/3`: clusters are not joined across a guard.
- `PatientMatching.Placeholders` with configurable lists.
- More date formats: unpadded and dashed month-first dates, `YYYYMMDD`,
  `MMDDYYYY`, ISO datetimes, and day-first dates when the day is over 12.
  Dates before 1880 or in the future are rejected.
- Integer MRN, ZIP, phone and SSN values are accepted; ZIPs that lost their
  leading zero are restored; last-four-only SSNs are kept as `:ssn_partial`.
- Multi-field comparisons (`%Comparison{fields: [...]}`).
- Comparators: nickname table, name part, compound surname, initial, swapped
  names, month/day swap, one-digit typo and transposition.
- DOB exact level uses term frequencies, so common dates such as Jan 1 weigh less.
- `training_block_size` option (default 200): oversized training blocks are
  sampled instead of dropped.

### Fixed

- Scoring copied the whole file into every per-pair task, making `dedupe/3`
  quadratic. 9k-record enterprise scoring dropped from 57 s to under 1 s.
- Soundex lost accented letters (`ÁLVAREZ` became L162).
- Term frequency for values unseen in training was 1e-6, giving them about
  17 bits of spurious evidence; they now count as seen once.
- Training normalized the file five times; normalization and pattern counting
  now run in parallel. 111k-record training dropped from 267 s to 19 s.
