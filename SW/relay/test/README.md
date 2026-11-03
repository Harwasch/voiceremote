```mermaid
flowchart LR
  Vitest[Vitest: ≤4 workers] --> Runtime[relay.test.ts + runtime-fixture.ts]
  Runtime --> Miniflare[Real Workers runtime + SQLite Durable Objects]
  Clients[Two synthetic signing/encryption clients] <--> Miniflare
  Vitest --> Contract[protocol.test.ts + codec.test.ts]
  Vitest --> Guards[apns.test.ts + ci.test.ts]
```

| File | What it verifies | Status |
|---|---|---|
| [relay.test.ts](relay.test.ts) | First pair, eviction-safe deadlines, orphan cleanup, stale membership/generation, actual queue purge, silent closure, per-recipient drops, legal maximum frames, schema-closed payloads and APNs cache eviction | ✅ local runtime + native network socket |
| [runtime-fixture.ts](runtime-fixture.ts) | Test-only subclass for storage inspection/expiry injection; never the Wrangler entrypoint | ✅ |
| [codec.test.ts](codec.test.ts) | Worker adapter agreement with generated codec, shared vectors and variant/field mutations | ✅ |
| [protocol.test.ts](protocol.test.ts) / [protocol-README.md](protocol-README.md) | Existing generated contract/vector suite | ✅ unchanged |
| [apns.test.ts](apns.test.ts) | Absent/partial/invalid credentials disable or contain wake without sensitive logs | ✅ |
| [ci.test.ts](ci.test.ts) | Release version, trigger scope and deploy secret/tag gates | ✅ local guards; hosted CI unverified |
| [mutations.ts](mutations.ts) / [../ci/check-mutations.mjs](../ci/check-mutations.mjs) | Remove membership, generation, queue purge, closed fields or payload-safe logging in test bundles; require assertion failures | ✅ five caught |

Start with `npm --prefix SW/relay test`. Synthetic keys are generated in memory;
no real keys, audio or transcripts are fixtures. Test expiry injection ages stored
deadlines; the local runtime's clock is not mocked. The hibernation test uses
Miniflare's actual eviction API. Each room uses a unique account; storage
inspection bypasses ingress **only in the test bundle**. Run
`npm --prefix SW/relay run test:mutations` to reproduce the five negative checks.
The exchange test makes no claim that encrypting its own marker proves relay
privacy; explicit schema rejection and payload-log mutations test that boundary.
Unknown-room join probes also verify that rejected requests create no persistent
application tables; SQL schema initialization follows authenticated creation.

Trace: REQ-22, REQ-24–26, REQ-61. Two distinct real networks, actual Noise/client
pairing, real APNs phone wake and delivery performance remain **unverified**.
