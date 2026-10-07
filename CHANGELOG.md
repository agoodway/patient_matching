# Changelog

## Unreleased

Driven by the new evaluation suite (`eval/`, dev only). On its synthetic
Houston-area population (9,015 records, 6 sources), enterprise dedupe went
from 57.6% to 99.7% auto-match precision at 96.4% recall, blocking recall from
87.5% to 99.8%, wrongly merged clusters from 525 to 8, and golden scenarios
from 54/83 to 82/83. A second population generated with another seed gives
99.4% precision and 96.3% recall.

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
  - MRN leading zeros are ignored.
- **Preset.**
  - New comparisons and levels: `contact` (ZIP, phone and street together)
    replaces `zip` and `phone`; `name_order` is new; and the name, DOB and SSN
    comparisons gain variant levels.
  - Two new prediction blocking rules (`[:dob]` and
    `[:given_soundex, :family_soundex]`), and training blocking
    `[[:dob_year], [:family_soundex, :given_name3]]`.
  - Guards are on.
- **Results.** Pairs carry `:guards`. `dedupe/3` also returns `rejected_edges`.
  A same-source MRN agreement is overridden by a guard (reason `:mrn_conflict`).
- **Model dumps** are version 2 (adding `trained.tf_records` and
  `trained.lambda_train`); version 1 dumps no longer load.

### Added

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
