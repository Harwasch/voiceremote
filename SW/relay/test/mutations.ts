import { readFileSync } from "node:fs";
import type { Plugin } from "esbuild";

// Test-bundle transformations only. Production sources are never rewritten.
export function mutationPlugin(): Plugin {
  return { name: "relay-security-mutations", setup(build) {
    build.onLoad({ filter: /\/src\/(room|codec)\.ts$/ }, args => {
      let contents = readFileSync(args.path, "utf8");
      const mutation = process.env.RELAY_TEST_MUTATION;
      const replacements: Record<string, [string, string, string]> = {
        "cloud-revoke": ["room.ts", "this.cloud.revoke(value.device_id as string);", ""],
        membership: ["room.ts", "const member = this.member(state, attachment.device);", "const member = state.members.find(m => m.device === attachment.device) ?? { device: attachment.device, generation: attachment.generation };"] ,
        generation: ["room.ts", 'requireThat(member.generation === attachment.generation && socket.readyState === 1, 403, "forbidden");', ""],
        purge: ["room.ts", "this.queue.revoke(value.device_id as string);", ""],
        plaintext: ["codec.ts", 'record(frame, [...common, "ciphertext"]);', ""],
        logging: ["room.ts", 'metric("accepted", 1, bytes);', 'metric("accepted", 1, bytes); console.log(raw);'],
      };
      if (mutation && replacements[mutation]) {
        const [file, before, after] = replacements[mutation];
        if (args.path.endsWith(file)) {
          if (!contents.includes(before)) throw new Error("Mutation target changed; update the regression harness");
          contents = contents.replace(before, after);
        }
      }
      return { contents, loader: "ts" };
    });
  } };
}
