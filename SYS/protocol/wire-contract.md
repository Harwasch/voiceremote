# Wire contract v1

| Boundary | Enforced by schemas / codecs | Remaining component responsibility (unverified here) |
|---|---|---|
| Model → phone | Candidate and reachable tools have no authority fields; every object is closed | Treat confidence, risk, hashes, card state and destination as untrusted hints |
| Phone → execution | Required actor, activation, credential, scope and idempotency key; inferred source requires approval event + tap + non-grant credential | Authenticate input/event; bind it to exact retained preview/hash, actor, session and target; deduplicate before execution |
| Sensitive command | Approval event and biometric/passcode credential required | Trusted policy computes actual risk from the action; never trust model risk classification |
| Dictation → receiver | No Send/Enter/submit fields; all U+0000–001F, U+007F–009F, U+2028 and U+2029 rejected, including escape/control sequences | Insert literal text using a text API; never synthesize Send/Enter, interpret escapes or dispatch tools |
| Phone ↔ relay | Closed frame variants: encrypted bytes or allowlisted metadata only | Noise encryption/authentication, room membership and account binding |
| QR → enrollment | Only public key, 32-byte base64 one-use token, positive safe-integer expiry, relay room and account identity | Apply the required issuance/expiry checks below, validate negotiated public-key size, confirm phrase on both devices; never reuse token as a session credential |
| Grant → policy | Actor, device, project, capability, risk and expiry all required | Check expiry and revocation against trusted time; no global grant or model expansion |
| All records | Required `account_id`, including nested tools | Bind all account/device/project identifiers to authenticated session; reject cross-account nested records |

These tests prove structural contracts and JSON interoperability. They do not
prove cryptography, valid approvals, at-most-once execution, actual insertion,
revocation or physical safety. Those need the later component tasks.

| Encoding rule | Decision / assumption |
|---|---|
| Version | Schema family v1, identified by `$id`; no per-message version yet. Incompatible revisions require an explicit new family/transport negotiation. |
| Dispatch | Exact `kind` discriminator, closed objects and `oneOf` unions; reject unknown variants/fields, including nested fields. |
| Wire codecs | Swift `ProtocolCodec`, Rust `decode`/`encode`, TS `decode`/`encode`. Raw JSONDecoder, serde, JSON.parse and TS interfaces alone do not enforce the wire profile. Validate before execution. |
| JSON grammar | Reject duplicate decoded keys at every object level, even identical values or escaped key spellings. Reject lone surrogates, invalid UTF-8, BOM before a record, trailing commas/data and non-JSON whitespace. Recursive parsing is limited to 64 levels. |
| Numeric tokens | Integer fields require literal JSON integers (`-?(0\|[1-9][0-9]*)`) within their safe bounds; fractions/exponents cannot round into integers. Real-valued fields accept finite binary64 numbers, but reject overflow and nonzero underflow to zero. `-0` is an integer; `1.0` and `1e0` are not integer tokens. |
| Optional fields | Absent, never `null`; encoders omit missing optionals. |
| Bytes | Nonempty padded standard base64 strings, no whitespace or URL alphabet. Strings preserve wire bytes; transport decodes them. The schema checks base64 shape, not key material or canonical pad bits. |
| IDs | Opaque, nonempty strings up to 128 Unicode code points; no global identifier format imposed. |
| Time / counters | Nonnegative Unix epoch milliseconds / source-local ticks and revisions, up to `2^53−1`, preserving [JavaScript safe-integer precision](https://tc39.es/ecma262/multipage/numbers-and-dates.html#sec-number.max_safe_integer). Epoch semantics do not apply to `source_clock`. |
| Revisions | Partial and committed dictation carry segment ID + monotonic revision. Receiver reconciliation and committed-segment deduplication remain component work. |
| Text | UTF-8 JSON strings containing Unicode scalar values; no Unicode normalization or byte-canonical JSON. Dictation additionally excludes every C0/C1 control and line/paragraph separators; multiline insertion needs a separately reviewed future contract. |
| Hash | Lowercase SHA-256 hex of the exact immutable task-preview bytes retained by trusted policy. Do not hash a reserialized JSON object and assume another language emits identical bytes. The hash is a binding identifier, not an authorization credential. |
| Payloads | Typed `ToolCall` unions, no arbitrary JSON argument bag. `prepare_send` is an action preview, never a dictation feature. |
| Command linkage | Authorized commands reference a candidate, even for explicit input. `revoke` is also idempotent. Mode/capture reports describe state, not execution requests. |
| Bounds | String/array/byte limits are initial defensive contract assumptions, not measured capacity or product requirements. |

`PayloadHash` follows the product's immutable-preview requirement; hash and
capability/risk consistency checks belong to trusted policy. Schemas cannot
compare separate field values or verify signatures. Proposal snapshots may carry
UI states such as `approved`; those labels never authorize execution.

Model-facing records also exclude `source_tier`, `approval_event_id`,
`policy_version`, actual `risk_class`/`payload_hash`, execution state/outcome, and
speaker/consent evidence (Product §4.1–4.4, §7–8; REQ-28–33, REQ-36, REQ-58).
These are trusted input, policy or execution facts. The corresponding `proposed_*`
fields and candidate UI state remain untrusted hints.

Pairing runtime checks are **required** by REQ-22/REQ-25 and remain **unverified**
until enrollment is implemented: generate 32 cryptographically random token bytes;
at issuance set `expires_at = issued_at + 120000` ms and retain an issuer-side
monotonic deadline. At redemption require trusted time and
`0 < expires_at - now <= 120000` ms, an unelapsed issuer deadline and an unused
token bound to this enrollment/device/account. Reject stale, far-future, replayed
tokens and unavailable trusted time. Consume the token once; never promote it to
a lasting credential. Schema validation cannot compare timestamps to the clock,
prove randomness, or prove one-use. The token size is a defensive contract choice.
