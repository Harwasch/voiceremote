import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

/** @param {string} tag @param {string} version */
export function checkReleaseVersion(tag, version) {
  if (tag.startsWith("relay-v") && tag !== `relay-v${version}`) {
    throw new Error("Release tag must equal relay-v plus package.json version");
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  checkReleaseVersion(process.argv[2] ?? "", version);
  console.log("Relay version guard passed.");
}
