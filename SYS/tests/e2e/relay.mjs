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
const runtime = new Miniflare(convertV4MiniflareOptions({ name: "relay-e2e", modules: true, script: bundled.outputFiles[0].text, compatibilityDate: '2026-07-01',
  host: '127.0.0.1', port: 0, durableObjects: {
    ROOMS: { className: 'Room', useSQLite: true },
    ADMISSION: { className: 'Admission', useSQLite: true },
    WAKE: { className: 'WakeProvider', useSQLite: true },
    CLOUD_BUDGET: { className: 'CloudBudget', useSQLite: true }
  }, resourcePersistencePath: resolve(process.argv[2], 'relay-storage') }));
const url = await runtime.ready;
console.log(url.origin);
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, async () => { await runtime.dispose(); process.exit(0); });
