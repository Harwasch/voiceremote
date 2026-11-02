# Wire contract v1

| Boundary | Enforced by schemas / codecs | Remaining component responsibility (unverified here) |
|---|---|---|
| Model → phone | Candidate and reachable tools have no authority fields; every object is closed | Treat confidence, risk, hashes, card state and destination as untrusted hints |
| Phone → execution | Required actor, activation, credential, scope and idempotency key; inferred source requires approval event + tap + non-grant credential | Authenticate input/event; bind it to exact retained preview/hash, actor, session and target; deduplicate before execution |
| Sensitive command | Approval event and biometric/passcode credential required | Trusted policy computes actual risk from the action; never trust model risk classification |
| Dictation → receiver | No Send/Enter/submit fields; CR, LF, NEL, line/paragraph separators rejected | Insert literal text using a text API; never synthesize Send/Enter, interpret escapes or dispatch tools |
| Phone ↔ relay | Closed frame variants: encrypted bytes or allowlisted metadata only | Noise encryption/authentication, room membership and account binding |
| QR → enrollment | Only public key, one-use token, expiry, relay room and account identity | Validate negotiated public-key/token sizes, enforce one-use and two-minute lifetime, confirm phrase on both devices; never reuse token as a session credential |
| Grant → policy | Actor, device, project, capability, risk and expiry all required | Check expiry and revocation against trusted time; no global grant or model expansion |
| All records | Required `account_id`, including nested tools | Bind all account/device/project identifiers to authenticated session; reject cross-account nested records |

These tests prove structural contracts and JSON interoperability. They do not
prove cryptography, valid approvals, at-most-once execution, actual insertion,
revocation or physical safety. Those need the later component tasks.

| Encoding rule | Decision / assumption |
|---|---|
| Version | Schema family v1, identified by `$id`; no per-message version yet. Incompatible revisions require an explicit new family/transport negotiation. |
| Dispatch | Exact `kind` discriminator, closed objects and `oneOf` unions; reject unknown variants/fields, including nested fields. |
| Wire codecs | Swift `ProtocolCodec`, Rust `decode`/`encode`, TS `decode`/`encode`. Raw serde and TS interfaces alone do not enforce all schema rules. Validate before execution. |
| Optional fields | Absent, never `null`; encoders omit missing optionals. |
| Bytes | Nonempty padded standard base64 strings, no whitespace or URL alphabet. Strings preserve wire bytes; transport decodes them. The schema checks base64 shape, not key material or canonical pad bits. |
| IDs | Opaque, nonempty strings up to 128 Unicode code points; no global identifier format imposed. |
| Time / counters | Nonnegative Unix epoch milliseconds / source-local ticks and revisions, up to `2^53−1`, preserving [JavaScript safe-integer precision](https://tc39.es/ecma262/multipage/numbers-and-dates.html#sec-number.max_safe_integer). Epoch semantics do not apply to `source_clock`. |
| Revisions | Partial and committed dictation carry segment ID + monotonic revision. Receiver reconciliation and committed-segment deduplication remain component work. |
| Text | UTF-8 JSON strings; no Unicode normalization or byte-canonical JSON. Dictation is single-line text; multiline insertion needs a separately reviewed future contract. |
| Hash | Lowercase SHA-256 hex of the exact immutable task-preview bytes retained by trusted policy. Do not hash a reserialized JSON object and assume another language emits identical bytes. The hash is a binding identifier, not an authorization credential. |
| Payloads | Typed `ToolCall` unions, no arbitrary JSON argument bag. `prepare_send` is an action preview, never a dictation feature. |
| Command linkage | Authorized commands reference a candidate, even for explicit input. `revoke` is also idempotent. Mode/capture reports describe state, not execution requests. |
| Bounds | String/array/byte limits are initial defensive contract assumptions, not measured capacity or product requirements. |

`PayloadHash` follows the product's immutable-preview requirement; hash and
capability/risk consistency checks belong to trusted policy. Schemas cannot
compare separate field values or verify signatures. Proposal snapshots may carry
UI states such as `approved`; those labels never authorize execution.
