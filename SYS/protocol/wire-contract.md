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
| Revisions | Partial and committed dictation carry segment ID + monotonic revision. Durable receiver claims deduplicate committed segments across sessions; `dictation_query` reads the result without carrying text. |
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

## Dictation, target and capture exchange

```mermaid
sequenceDiagram
    Phone->>Desktop: target_prepare(request_id, target)
    Desktop->>Tray: Present destination; wait for display readiness
    Tray-->>Desktop: Ready (or deadline / unavailable)
    Desktop-->>Phone: target_ready(request_id, ready)
    Phone->>Phone: Pin/show destination before capture starts
    Phone->>Desktop: dictation_text(segment_id, preparation_id)
    Desktop->>Desktop: Durable claim → literal insertion → durable outcome
    Desktop-->>Phone: dictation_outcome(inserted / unavailable / unconfirmed)
    Phone->>Desktop: dictation_query(segment_id), after lost ACK / resume
    Desktop-->>Phone: Durable result; query never inserts
```

| Exchange | Runtime contract |
|---|---|
| Preparation | Production desktop requires `preparation_id` matching a successful prepare on this Noise session. A GUI acknowledges only after tray/overlay presentation calls succeed. Stalled/absent presentation refuses readiness; no insertion. CLI writes a content-free selection announcement. Physical display timing remains **unverified**. |
| Outcome | `inserted` follows successful injector return and durable success. `unavailable` certifies no input started. Any partial insertion, unknown native error or crashed reservation is `unconfirmed`. A query with no insertion claim durably records `never_claimed` before returning `unavailable`; this negative marker never occupies the atomic insertion claim. A concurrent/later claim takes precedence, so the same segment ID can insert at most once. `task_status` is for tasks; new dictation outcomes have separate identity. |
| Retry | No automatic text retry or carrier replay. Reconnection starts fresh XX, then queries unconfirmed segment identities. Held/failed text requires a Send tap. A tap on unconfirmed text queries first and sends only if the receiver positively certifies unavailability. |
| Local keyboard | Enqueue and receipt-before-call deduplication do not prove insertion. A separate shared receipt is persisted after the keyboard insertion call succeeds. Missing/throwing/crashed calls stay unconfirmed and are never drained twice. |
| Focus | `activity_age_ms` is elapsed milliseconds from native input/idle clocks at sampling, **not** report age or peer wall time. Phone adds local monotonic elapsed time since receipt; eligible focused devices need activity within 60 seconds. Rank by estimated input time; deterministic device ID tie-break. Unknown/missing age is inactive. Heartbeats preserve growing age and cannot refresh old activity. Active-window/editability is checked locally without field/window contents. |
| Capture request | `capture_control` identifies the phone, desired selection, unique request ID, increasing per-connection `request_sequence`, TTL (1–2000 ms) and absolute `expires_at`. Desktop expires its pending request from send. Phone requires a newer sequence, a future deadline no farther than TTL, and processing within TTL of monotonic receipt. Clock disagreement fails closed; delayed frames cannot extend the sender deadline. Phone rejects wrong account/target, duplicate IDs and exhausted bounded ledgers. Old-session ciphertext is never resumed. |
| Capture result | `capture_control_result` distinguishes applied, unavailable, expired and cancelled. Remote control is stop-only: OFF stops capture in either mode; HOLD/continuous always return `unavailable` without starting or preparing the microphone. Starting requires the phone’s local controls. Refusals report actual selection and resolve the requester even when it differs from the requested selection. Desired `capture_state` and actual `listening` are reported separately; sending a request never changes displayed mic state. Phone state is echoed on focus heartbeats so an otherwise idle healthy connection does not expire. |
| Compatibility | New variants fail closed on older peers. Missing activity age cannot select Auto; missing preparation cannot insert on the production receiver. Upgrade both peers; no fallback to unacknowledged insertion. |
| Carrier | At connection/resume, try all discovered same-room private LAN candidates with pinned authenticated handshakes; close failed probes before the next candidate or signed relay fallback. Discovery ending/cancelling its browser is distinct from cancellation of the connection task. Both desktop listeners remain available while paired. The same production `PhoneConnection` serializes writes and correlates readiness/outcomes in app and socket e2e. |
| Pairing entry | No short-code lookup exists. The tray displays QR plus the complete copyable invitation, bounded by the existing one-use, two-minute contract. Optional relay provisioning secret is transient input used only for signed room creation; never saved in settings/snapshots/logs. |

Trace: REQ-16–18, REQ-22–27; owner wording question Q-12. Local synthetic
contract tests do not prove native field insertion, physical UI timing or phone
background behavior.

## Paired agent inventory and dispatch

| Message | Responsibility |
|---|---|
| `agent_inventory_request` / `agent_inventory` | Paired controlling phone only; account/device/request/actor correlation. Inventory carries owner project, canonical workspace, provider, exact session, permission profile and intersected enrollment capabilities. Metadata is never a grant. |
| `agent_dispatch` | Retains the approved command, exact inventory session, base64 immutable preview bytes and original expiry. Node hashes retained bytes, checks preview bindings and compares the exact owner session before starting a CLI. Existing receipts are read before freshness checks. |
| `agent_task_query` | Paired read-only receipt lookup; unknown IDs never spawn or resend. Status remains account/command correlated; authenticated connection and pinned Router identity supply the source. |

Phone permission choice and desktop `--allow-agents`/owner allowlist enrollment
are explicit and independent of model output. The phone re-verifies the sealed
Policy permit before routing. Protocol interoperability is covered by shared
vectors and the synthetic agent relay E2E; device/provider/Windows runtime
acceptance remains **unverified**.
