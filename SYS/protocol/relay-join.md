# Relay room enrollment and transport v1

```mermaid
sequenceDiagram
  participant D as Desktop
  participant R as Relay room
  participant P as Phone
  D->>R: Self-signed create: fresh room ID + relay public key
  R-->>D: Created; server time + initial cleanup deadline
  D->>R: Signed invite: token hash + two-minute deadline
  D-->>P: QR: account + room + token + expiry + Noise static public key
  P->>R: Redeem token with new relay public key and own signature
  R-->>P: Bind relay membership; consume token atomically
  D->>R: Ed25519 challenge / socket upgrade
  P->>R: Ed25519 challenge / socket upgrade
  D<<->>P: Noise XX through ciphertext frames; confirm four-word phrase
```

Coordinator-decided first-pair contract, implemented in `SW/relay`. This document
defines the HTTP sidecar and transport limits; generated `RelayFrame` and
`PairingPayload` schemas are unchanged. Trace: REQ-22–26, REQ-61.
Local runtime behavior is tested; actual desktop/phone pairing and two-network
operation remain **unverified**.

## Identity and encoding

| Item | Contract |
|---|---|
| Base path | `https://<relay>/v1/accounts/{account_id}/rooms/{room_id}`; no query parameters. |
| Account | Pre-sign-up namespace, supplied by clients; not proof of a human account. Nonempty ASCII `[A-Za-z0-9_-]{1,128}`. |
| Room ID | Fresh CSPRNG 128 bits, encoded as exactly 32 lowercase hexadecimal digits. Desktop generates it. Account + room form the tenant boundary. |
| Device ID | Client-generated opaque ASCII `[A-Za-z0-9_-]{1,128}`; unique within the room. |
| Signing key | Per-device Ed25519 relay key. Public key is raw 32 bytes, canonical padded standard base64. It is **separate from the Noise static key** carried by the QR. Private keys never leave endpoints. |
| Token | Desktop generates 32 CSPRNG bytes and encodes canonical padded standard base64 as `one_use_token`. Never reuse it or log it. |
| Token hash | `token_sha256 = base64(SHA256(UTF8(one_use_token)))`: hash the exact canonical **base64 string**, not its decoded bytes. This is intentionally explicit for client interoperability. Relay retains only that hash. |
| Other hashes | `base64(SHA256(exact UTF-8 bytes))`, padded standard base64. |
| Signatures | Ed25519, 64 raw bytes, canonical padded standard base64. |
| Time | Unix epoch milliseconds as safe JSON integer tokens, without fractions/exponents. Relay clock is authoritative; deadlines and clock high-water are persisted. |
| JSON bodies | Strict, closed, flat objects: only listed fields. Reject duplicate decoded keys, malformed UTF-8, lone surrogates, nested objects, non-JSON whitespace and extra fields. Limit 4,096 bytes with a two-second read timeout. |

For the signing arrays below, use compact JSON with no whitespace, ordinary JSON
escaping and **no escaping of `/`**. All string elements are ASCII. Timestamp
elements are decimal JSON integers. Sign the exact UTF-8 bytes. For operation
proofs, sign the returned `message` string bytes after checking its context.

## Create and first join

| Step | Request / response |
|---|---|
| 1. Create | `POST /create`, body exactly `{"device_id":"...","public_key":"..."}`. `X-Relay-Signature` signs `["voiceremote-relay-create-v1", account_id, room_id, base64(SHA256(exact_body_bytes))]`. Response 201: `created`, `server_time`, `expires_at`. An existing room returns 409. |
| Optional provisioning | If Worker env `RELAY_PROVISION_SECRET` is set, `/create` additionally requires `Authorization: Bearer <secret>`. Configured empty/short secrets fail closed. If unset, creation is open and rate limited. The secret is for trusted provisioning; ordinary pairing clients need no bearer in the open configuration. |
| 2. Register invite | The desktop, now a member, obtains an `invite` operation challenge and signs it as described below. `POST /invite`, body exactly `{"token_sha256":"...","expires_at":<integer>}`. No phone ID/key is known or supplied. Relay requires `0 < expires_at - server_now <= 120000`. Response 201: `registered`, `expires_at`. |
| Deadline choice | For the initial invite use `/create`'s returned `expires_at`, avoiding reliance on the desktop clock. For reissue use a fresh signed challenge's `server_time + 120000`. Network transit shortens usable lifetime. |
| 3. QR | Use the existing generated `PairingPayload`: `account_id`, `relay_room_id`, `one_use_token`, `expires_at`, `desktop_public_key` (the **Noise** key), and `kind: "pairing"`. No phone relay key or ID is present. |
| 4. Redeem | Phone generates a new relay Ed25519 key and device ID. `POST /join`, body exactly `device_id`, `public_key`, `one_use_token`, `expires_at`, `signature`. Signature signs `["voiceremote-relay-join-v1", account_id, room_id, device_id, public_key, one_use_token, expires_at]`. |
| 5. Bind | Relay matches the pending token hash and exact expiry, verifies the new key's proof of possession, checks expiry again, then binds the supplied ID/key and consumes the token in one serialized durable operation. Response 201: `joined: true`. Concurrent redemption has one winner. Invalid signatures do not consume a valid token. |
| 6. Authenticate transport | Each device connects using its own member challenge. Relay membership only proves access to the enrollment token and signing key. Noise XX, the QR's Noise-key check and confirmation of the four-word phrase prove endpoint identity. **Relay never decides trust between people or approves product actions.** |

Reissuing an invite replaces that issuer's previous invite. A consumed hash cannot
be registered again while its original deadline remains live; the phone's signed
expiry also prevents replay against a later enrollment. Expired/replayed tokens
fail. A pending invite survives real hibernation/eviction because all deadlines
and enrollment state are stored in SQLite; no in-memory deadline is required.
Observed clock rollback fails closed until trusted server time catches up.

A room that has never acquired a second member expires at its last registered
invite deadline. Before the first invite, its cleanup deadline is creation + two
minutes. A Durable Object alarm deletes all room data/storage and closes its
sockets; access at/after the deadline also deletes it. Once a second member has
joined, the room persists independently of invite expiry. Room IDs can be reused
only after expiration cleanup, although clients always generate fresh IDs.

## Member challenges, connect and revoke

1. Prepare the exact subsequent operation body. For `connect`, body bytes are
   empty. Compute `body_sha256` from those exact bytes.
2. `POST /challenge`, body exactly `device_id`, `operation`, `body_sha256`;
   `operation` is `invite`, `connect` or `revoke`. `X-Relay-Signature` signs
   `["voiceremote-relay-challenge-v1", account_id, room_id, SHA256_BASE64(exact_challenge_body)]`.
   This proof permits challenge issuance only.
3. Response 200: `challenge`, `message`, `expires_at`, `server_time`. `message` is
   `["voiceremote-relay-auth-v1", account_id, room_id, device_id, operation, body_sha256, challenge, expires_at]`.
   Check all fields and expiry before signing it. Challenges expire after 60
   seconds; at most two per device and 16 per room are pending.
4. Submit the operation using `X-Relay-Challenge: <challenge>` and
   `X-Relay-Signature: <signature_over_message>`. Every challenge is consumed once,
   including failed operation signatures. Body/property order and whitespace
   changes invalidate the proof.

| Operation | Contract |
|---|---|
| Connect | `GET /connect`, empty body, `Upgrade: websocket` and proof headers. 101 response includes `X-Relay-Dropped-Frames` as a decimal count. Native clients need upgrade header support. One socket per device; a new connection closes the previous one. |
| Revoke | `POST /revoke`, body exactly `{"device_id":"target"}` and member proof. **Any current member may remove any member, including itself.** Relay cannot interpret product authority; phone policy remains authoritative at endpoints, and desktop also implements local revoke. |
| Revocation effect | Persist removal, key/wake-registration deletion, challenge/invite invalidation and removal of queued frames both sent by and addressed to the device before replying 200. Close every socket of that device, including silent sockets. Every subsequent frame reloads membership and checks enrollment generation. Delivered/in-flight bytes cannot be recalled. |

## Frames and offline delivery

| Item | Contract |
|---|---|
| Frame kinds | Existing generated `RelayFrame`: `ciphertext`, `presence`, `wake_registration`. No transcript/text/inner-payload field exists outside ciphertext. Strict adapter validation precedes storage, logging or forwarding. Relay never decrypts. |
| Frame cap | **1,052,672 UTF-8 bytes**, including outer JSON. This covers the schema's maximum 1,048,576 base64 characters plus three maximum-length escaped IDs and framing overhead. Larger frames close with 1009; invalid/binary frames with 1008. |
| Maximum dictation | A legal `dictation_text` has up to 16,384 Unicode scalars: worst-case text is 65,536 UTF-8 bytes, plus at most 2,304 escaped bytes for three identifiers and fixed JSON fields. Even two Noise tags/framing plus base64 fit well within the relay cap. The local runtime test sends this size through a room. |
| Noise record limit | Noise itself caps one record at 65,535 bytes including its authentication tag. A maximum-size Unicode dictation can require multiple Noise records. Endpoint framing/reassembly is client work; this relay transports each record as opaque ciphertext and sets no smaller payload limit. [Noise specification](https://noiseprotocol.org/noise.html#message-format). |
| Broadcast | Ciphertext goes to other enrolled members. There is no outer recipient in v1; Noise and inner target fields select meaningful endpoint recipients. Newly joined devices do not receive historical queued frames. |
| Queue limits | **Per offline recipient:** 32 frames, 2,105,344 encoded-frame bytes, five-minute TTL. SQLite stores bounded individual frame rows, not one KV value. Eight members bounds room fanout/storage. |
| Overflow | Drop that recipient's oldest frames until both bounds fit. Continue live delivery and other queues. Never close the sender for an offline recipient's overflow. Persist the number of overflow drops for that recipient. |
| Reconnect | Report overflow count in `X-Relay-Dropped-Frames`, then replay retained unexpired frames in order and remove them. Reset the reported count. TTL expiration is not included in overflow count. The count, like delivery, is best effort if upgrade fails. |
| Delivery meaning | There is no application/execute acknowledgment. Crashes can lose or duplicate delivery; endpoints need retry and command idempotency. A relay send is not proof a task executed. |
| Presence / wake | Server emits online/offline presence. Wake registration is only for the authenticated sender, stored as routing metadata, never broadcast. APNs receives only a fixed background signal, with no room/task/content payload. |

## Admission, errors and verification

Creation: 60 attempts/minute per IPv4 address or normalized IPv6 **/64**.
Failed token matching: 60 failures/minute **per room and source prefix**, charged
only after mismatch. Valid token redemption bypasses the failure budget, including
behind the attacker's NAT. Failed attempts in another room do not share its
bucket. Signed controls use device-key possession and partitioned challenge slots,
not an attacker-controlled global room counter. Cloudflare's trusted ingress
supplies `CF-Connecting-IP`; clients cannot choose it in production.

Errors are closed metadata responses: 400 malformed request, 403 forbidden or
invalid/expired token, 409 existing room/device or room full, 413 body too large,
426 missing upgrade, 429 admission/challenge limit, 503 unavailable trusted time
or storage. Responses are `Cache-Control: no-store`. Logs contain only fixed event
names and numeric counts/byte counts, never bodies, ciphertext, tokens or keys.

Evidence: [integration tests](../../SW/relay/test/relay.test.ts),
[adapter/bounds tests](../../SW/relay/test/codec.test.ts), and
[mutation runner](../../SW/relay/ci/check-mutations.mjs). The mutation runner proves
tests fail without membership/generation checks, queue purging, closed ciphertext
fields or payload-safe logging. Real deployment, two-network pairing, endpoint
Noise fragmentation/reassembly and phone wake remain **unverified**.
