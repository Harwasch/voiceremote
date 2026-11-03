import { readFileSync } from "node:fs";
import { parse } from "yaml";
import { describe, expect, it } from "vitest";
import { checkReleaseVersion } from "../ci/check-version.mjs";

describe("relay release guards", () => {
  it("checks origin/main ancestry before deploying any release tag", () => {
    const workflow = parse(readFileSync(new URL("../../../.github/workflows/relay.yml", import.meta.url), "utf8"));
    const steps = workflow.jobs.deploy.steps;
    const guard = steps.findIndex((s: any) => /merge-base --is-ancestor/.test(s.run ?? ""));
    expect(guard).toBeGreaterThan(-1);
    expect(steps[guard].run).toContain('"$GITHUB_SHA" origin/main');
    expect(guard).toBeLessThan(steps.findIndex((s: any) => s.run === "npm run deploy"));
  });
  it("requires the exact component version on release tags", () => {
    expect(() => checkReleaseVersion("relay-v0.1.0", "0.1.0")).not.toThrow();
    for (const tag of ["relay-v0.1.1", "relay-v", "relay-v0.1.0-extra"]) {
      expect(() => checkReleaseVersion(tag, "0.1.0")).toThrow();
    }
    expect(() => checkReleaseVersion("dev/integration", "0.1.0")).not.toThrow();
  });
  it("allows daily, release-tag and manual runs; deploy requires a tag and secret", () => {
    const workflow = parse(readFileSync(new URL("../../../.github/workflows/relay.yml", import.meta.url), "utf8"));
    expect(Object.keys(workflow.on).sort()).toEqual(["push", "schedule", "workflow_dispatch"]);
    expect(workflow.on.push).toEqual({ tags: ["relay-v*"] });
    expect(workflow.on.schedule).toHaveLength(1);
    expect(workflow.on.schedule[0].cron.split(" ").slice(2)).toEqual(["*", "*", "*"]);
    expect(workflow.jobs.deploy.needs).toBe("test");
    expect(workflow.jobs.deploy.if).toBe("startsWith(github.ref, 'refs/tags/relay-v') && needs.test.outputs.deploy == 'true'");
    const credentialStep = workflow.jobs.test.steps.find((s: any) => s.id === "credentials");
    expect(credentialStep.env.CLOUDFLARE_API_TOKEN).toBe("${{ secrets.CLOUDFLARE_API_TOKEN }}");
    expect(credentialStep.run).toContain('-n "$CLOUDFLARE_API_TOKEN"');
    for (const job of [workflow.jobs.test, workflow.jobs.deploy]) {
      expect(job.steps.some((s: any) => s.run === 'npm run check-version -- "$GITHUB_REF_NAME"')).toBe(true);
    }
  });
});
