# Recorder contract and scoring

Purpose: iOS worker handoff for an offline scorer. Inputs: SYS tool schema and
P0/brain design. Verification: synthetic tests; phone recorder **unverified**.

The normative file is [run.schema.json](schemas/run.schema.json); start from the
[labelled synthetic example](fixtures/synthetic-run.json). UTF-8 JSON only: no
NaN, Infinity, duplicate keys, audio payloads or credentials. No network is used.
The scorer requires a repository checkout to resolve SYS contracts locally.

| Field | Producer meaning |
|---|---|
| `schema_version` | Exactly `1`; breaking changes require a new version |
| `synthetic` | `true` only for invented fixtures; never label measurements synthetic |
| `device` | Named phone model/OS and measurement conditions; no personal device name |
| `capture_source` | `iphone_mic`, `airpods`, or `synthetic` (fixtures only) |
| `session_id` | Nonpersonal identifier for one controlled recording cohort |
| `vocabulary` | Private owner's term list or public seed; unique after normalization |
| `stt_cases` | Unique `id`, `category`, `expected_text`, `recording_id`; same recording per engine |
| `brain_cases` | Unique `id`, `prompt`, deterministic registry `context`, ordered `expected_calls` |
| `engines` | Unique `id`, `kind` (`stt`/`brain`), model/runtime `version`, complete `results`; optional `battery` |
| STT result | `case_id`, `text`; optional `first_text_ms`, `final_after_eos_ms`, `clipped_first_word` |
| Brain result | `case_id`, ordered `calls` array; optional `latency_ms` |
| `battery` | `duration_seconds` > 0, `drain_percentage_points` ≥ 0; one controlled interval per engine |

An empty array for either case kind allows STT-only or brain-only exports. Every
engine needs exactly one result for every case of its kind. Failed recognition is
`text: ""`; failed brain output is `calls: []`. Omit unavailable measurements;
never substitute zero. A true measured zero is allowed. Calls can be invalid model
proposals: they count as incorrect. Expected calls must validate against SYS.
No authorization fields belong in expected calls; the scorer grants no authority.

Time origins are monotonic on the phone: speech start→first text and end of
speech→final committed text; brain request start→complete proposal. Missing final
or partial samples do not remove the case from accuracy scoring. Record engine
version in `version`, plus device/OS and conditions in `device`; use separate runs
for different phone/source/recording cohorts. This contract cannot prove the
recording ID or measurement provenance: owner review is required.

## Scoring

| Metric | Definition |
|---|---|
| Normalization | Unicode NFKC, casefold, Unicode letters/numbers; punctuation separates tokens except internal apostrophes; no number-word conversion |
| WER | Sum Levenshtein edits / sum reference words, including insertions; can exceed 100% |
| Alignment ties | Prefer diagonal (match/substitution), then deletion, then insertion during backtracking |
| Term accuracy | Correct expected term occurrences / total occurrences. Repeated and overlapping terms count individually. Every token must match on a contiguous aligned span; extra mentions affect WER, not the term denominator |
| Clipped first word | Sum supplied booleans / supplied annotation count; unknown if omitted; audio/human annotation required |
| First word deleted | Reference first token has no aligned hypothesis token; a text-only proxy, not acoustic clipping |
| Timing | Arithmetic mean and nearest-rank p95 in ms, available samples only; sample count always shown |
| Battery / 10 min | Drain in percentage points × 600 / measured seconds; no baseline subtraction or energy attribution |
| Brain accuracy | Schema-valid exact ordered sequence and arguments; object key order ignored. No aliases or semantic equivalence |
| STT gate | Strictly lower WER than configured Apple ID AND strictly fewer term errors AND relative reduction ≥ configured target; missing Apple/term occurrences is INCOMPLETE; zero Apple term errors cannot be beaten |
| STT winner | Among PASS engines, lowest WER, then fewer term errors, then ID; NONE if no candidate passes |
| Brain leader | Highest exact accuracy, then lowest mean latency with all cases measured, then ID; no shipping gate specified |

The default reduction is `0.25`, proposed **TBC** per [REQ-14], not a measured
number or owner-approved target. Config accepts `0..1`; zero still requires strict
term improvement. The kit does not certify shipping: full owner recordings,
both microphones, a named phone and human review remain unverified.
