import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const probes = {
  membership: "denies an in-flight frame after membership removal",
  generation: "denies a frame with a stale enrollment generation",
  purge: "purges actual queued frames",
  plaintext: "schema-closed ciphertext",
  logging: "schema-closed ciphertext",
};
for (const [mutation, test] of Object.entries(probes)) {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("../node_modules/vitest/vitest.mjs", import.meta.url)),
    "run", "test/relay.test.ts", "-t", test, "--maxWorkers=4"], {
    cwd: fileURLToPath(new URL("../", import.meta.url)), encoding: "utf8",
    env: { ...process.env, RELAY_TEST_MUTATION: mutation },
  });
  const output = result.stdout + result.stderr;
  // A compile/setup failure is not evidence that the invariant test detects it.
  if (result.status !== 1 || !/Tests\s+1 failed/.test(output) || !output.includes("AssertionError")) {
    throw new Error(`Mutation ${mutation} was not caught by its assertion.\n${output}`);
  }
  console.log(`${mutation}: invariant test failed as expected`);
}
