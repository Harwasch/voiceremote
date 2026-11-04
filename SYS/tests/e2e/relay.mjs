// Purpose: run the unmodified production Worker locally. Inputs: checkout and
// ephemeral output directory. Verification: run.sh drives real endpoint clients.
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
const root = resolve(import.meta.dirname, '../../..');
const require = createRequire(resolve(root, 'SW/relay/package.json'));
const { build } = require('esbuild');
const { Miniflare, convertV4MiniflareOptions } = require('miniflare');
const bundled = await build({ entryPoints: [resolve(root, 'SW/relay/src/worker.ts')], write: false,
  bundle: true, format: 'esm', platform: 'neutral', external: ['cloudflare:workers'], logLevel: 'silent' });
const cloud = process.argv[3] === 'proxy';
const synthetic = 'SYNTHETIC-provider-marker-not-a-credential';
const provisioning = 'SYNTHETIC-test-provisioning-only-00000000';
const { Response: MFResponse, WebSocketPair } = require('miniflare');
const cloudSettings = cloud ? {
  bindings: {
    RELAY_PROVISION_SECRET: provisioning,
    ANTHROPIC_API_KEY: synthetic, ELEVENLABS_API_KEY: synthetic, ASSEMBLYAI_API_KEY: synthetic,
    CLOUD_DEVICE_DAILY_MICROUSD: '10000', CLOUD_GLOBAL_DAILY_MICROUSD: '100000',
    CLOUD_DEVICE_CONCURRENT: '2', CLOUD_GLOBAL_CONCURRENT: '4',
    CLOUD_SPEECH_RESERVATION_MICROUSD: '100', CLOUD_ANTHROPIC_RESERVATION_MICROUSD: '100',
    CLOUD_MAX_BODY_BYTES: '65536', CLOUD_MAX_FRAME_BYTES: '8192', CLOUD_MAX_STREAM_BYTES: '16384',
    CLOUD_MAX_DURATION_MS: '10000', CLOUD_MAX_OUTPUT_TOKENS: '2048',
    CLOUD_ANTHROPIC_MODEL: 'synthetic-model', CLOUD_ANTHROPIC_VERSION: '2026-10-21',
  },
  async outboundService(request) {
    const url = new URL(request.url);
    const expectedTerms = ["O'Brien", "C++ ~ é"];
    if (url.hostname === 'api.anthropic.com') {
      if (request.headers.get('x-api-key') !== synthetic || request.headers.get('anthropic-version') !== '2026-10-21') throw new Error('Synthetic upstream auth/version mismatch');
      const body = await request.json();
      if (body.model !== 'synthetic-model' || body.max_tokens !== 2048) throw new Error('Synthetic model mismatch');
      return new MFResponse('{"type":"message","role":"assistant","content":[],"stop_reason":"end_turn"}');
    }
    const eleven = url.hostname === 'api.elevenlabs.io';
    if (!eleven && url.hostname !== 'streaming.assemblyai.com') throw new Error('Unexpected outbound host');
    const terms = eleven ? url.searchParams.getAll('keyterms') : JSON.parse(url.searchParams.get('keyterms_prompt'));
    if (JSON.stringify(terms) !== JSON.stringify(expectedTerms)) throw new Error('Vocabulary query changed');
    if (request.headers.get(eleven ? 'xi-api-key' : 'authorization') !== synthetic) throw new Error('Synthetic speech credential mismatch');
    const pair = new WebSocketPair(), server = pair[1]; server.accept();
    server.addEventListener('message', event => {
      if (typeof event.data !== 'string') return;
      const value = JSON.parse(event.data);
      if (eleven && value.commit) server.send(JSON.stringify({ message_type: 'committed_transcript', text: 'Synthetic proxy fixture.' }));
      if (!eleven && value.type === 'Terminate') {
        server.send(JSON.stringify({ type: 'Turn', turn_order: 0, end_of_turn: true, transcript: 'Synthetic proxy fixture.' }));
        server.send(JSON.stringify({ type: 'Termination' }));
      }
    });
    return new MFResponse(null, { status: 101, webSocket: pair[0] });
  },
} : {};
const runtime = new Miniflare(convertV4MiniflareOptions({ name: "relay-e2e", modules: true, script: bundled.outputFiles[0].text, compatibilityDate: '2026-07-01',
  host: '127.0.0.1', port: 0, ...cloudSettings, durableObjects: {
    ROOMS: { className: 'Room', useSQLite: true },
    ADMISSION: { className: 'Admission', useSQLite: true },
    WAKE: { className: 'WakeProvider', useSQLite: true },
    CLOUD_BUDGET: { className: 'CloudBudget', useSQLite: true }
  }, resourcePersistencePath: resolve(process.argv[2], 'relay-storage') }));
const url = await runtime.ready;
console.log(url.origin);
if (cloud) {
  const b64 = bytes => Buffer.from(bytes).toString('base64');
  const digest = async text => b64(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
  const keys = await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
  const sign = async text => b64(await crypto.subtle.sign('Ed25519', keys.privateKey, new TextEncoder().encode(text)));
  const room = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('hex');
  const base = `${url.origin}/v1/accounts/proxy-e2e/rooms/${room}`;
  async function post(op, raw, headers = {}) {
    const response = await fetch(base + '/' + op, { method: 'POST', body: raw, headers: { 'content-type': 'application/json', ...headers } });
    if (!response.ok) throw new Error('Synthetic provisioning failed');
    return response.json();
  }
  const raw = JSON.stringify({ device_id: 'desktop', public_key: b64(await crypto.subtle.exportKey('raw', keys.publicKey)) });
  const created = await post('create', raw, { authorization: 'Bearer ' + provisioning, 'x-relay-signature': await sign(JSON.stringify(['voiceremote-relay-create-v1', 'proxy-e2e', room, await digest(raw)])) });
  const token = b64(crypto.getRandomValues(new Uint8Array(32)));
  const invite = JSON.stringify({ token_sha256: await digest(token), expires_at: created.expires_at });
  const challengeBody = JSON.stringify({ device_id: 'desktop', operation: 'invite', body_sha256: await digest(invite) });
  const challenge = await post('challenge', challengeBody, { 'x-relay-signature': await sign(JSON.stringify(['voiceremote-relay-challenge-v1', 'proxy-e2e', room, await digest(challengeBody)])) });
  await post('invite', invite, { 'x-relay-challenge': challenge.challenge, 'x-relay-signature': await sign(challenge.message) });
  console.log('PROXY_INVITE:' + JSON.stringify({ kind: 'pairing', account_id: 'proxy-e2e', relay_room_id: room,
    one_use_token: token, expires_at: created.expires_at, desktop_public_key: b64(crypto.getRandomValues(new Uint8Array(32))) }));
}
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, async () => { await runtime.dispose(); process.exit(0); });
