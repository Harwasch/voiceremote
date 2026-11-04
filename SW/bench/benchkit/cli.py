"""Purpose: privacy-conscious Markdown report CLI. Inputs: local JSON. Verified by tests."""
import argparse
import math
import sys

from jsonschema import ValidationError

from .scoring import battery, gate, stt_metrics, timing, stage_timing
from .validation import ROOT, REPO, read_json, validate_run, validator


def safe(value):
    # Only identifiers/metadata are rendered, never prompt text or model proposals.
    return str(value).replace("|", "\\|").replace("`", "'").replace("\n", " ").replace("\r", " ").replace("<", "&lt;")


def report(run, config):
    validate_run(run)
    validator(ROOT / "schemas/gate.schema.json").validate(config)
    stt = [e for e in run["engines"] if e["kind"] == "stt"]
    brain = [e for e in run["engines"] if e["kind"] == "brain"]
    metrics = {e["id"]: stt_metrics(run["stt_cases"], e["results"], run["vocabulary"]) for e in stt}
    baseline = metrics.get(config["apple_engine_id"])
    verdicts = {name: gate(metric, baseline, config["minimum_term_error_reduction"])
                for name, metric in metrics.items() if name != config["apple_engine_id"]}
    passing = [name for name in verdicts if verdicts[name].startswith("PASS")]
    winner = min(passing, key=lambda name: (metrics[name]["wer"], metrics[name]["term_errors"], name)) if passing else None
    lines = ["# Voice Control Fabric benchmark", "",
             "**SYNTHETIC DATA — fixture only; no engine performance or shipping claim.**" if run["synthetic"] else
             "**Owner export — measurements supplied by recorder; provenance unverified by this offline scorer.**",
             "", f'Device: {safe(run["device"])}; capture: {safe(run["capture_source"])}; session: {safe(run["session_id"])}.',
             f'STT cases: {len(run["stt_cases"])}; brain cases: {len(run["brain_cases"])}.',
             f'Gate: lower WER than {safe(config["apple_engine_id"])} AND ≥{config["minimum_term_error_reduction"] * 100:g}% fewer term errors ({config["target_status"]}); strict term improvement required.',
             f'STT winner against gate: **{safe(winner) if winner else "NONE — no candidate qualified"}**.', "",
             "| STT engine (version) | WER (edits/words) | Term accuracy (errors/occurrences) | Clipped first word (annotated) | First word deleted (proxy) | First text mean / p95 ms | EOS→final mean / p95 ms | Battery / 10 min | Gate |",
             "|---|---|---|---|---|---|---|---|---|"]
    for engine in stt:
        name = engine["id"]
        m = metrics[name]
        term = f'{m["term_accuracy"]:.1%}' if m["term_accuracy"] is not None else "TBD"
        clip = f'{m["clipped"]}/{m["clipped_n"]}' if m["clipped_n"] else "TBD (n=0)"
        verdict = "BASELINE" if name == config["apple_engine_id"] else verdicts[name]
        lines.append(f'| {safe(name)} ({safe(engine["version"])}) | {m["wer"]:.1%} ({m["errors"]}/{m["words"]}) | {term} ({m["term_errors"]}/{m["term_total"]}) | {clip} | {m["first_deleted"]}/{len(run["stt_cases"])} | {timing(engine["results"], "first_text_ms")} | {timing(engine["results"], "final_after_eos_ms")} | {battery(engine)} | {verdict} |')
    lines += ["", "| STT engine | Cleanup mean / p95 ms | Delivery mean / p95 ms | Capture→field mean / p95 ms | Battery cohort |",
              "|---|---|---|---|---|"]
    for engine in stt:
        rows = engine["results"]
        cohort = engine.get("battery", {}).get("cohort_id", "TBD")
        lines.append(f'| {safe(engine["id"])} | {stage_timing(rows, "cleanup_started_ms", "cleanup_completed_ms")} | {stage_timing(rows, "delivery_started_ms", "delivery_completed_ms")} | {stage_timing(rows, None, "field_confirmed_ms")} | {safe(cohort)} |')
    # Numeric labels prevent model-supplied identifiers becoming Mermaid syntax.
    lines += ["", "```mermaid", "xychart-beta", '    title "WER percent (lower is better)"']
    if stt:
        lines += ["    x-axis [" + ", ".join(f'"E{i + 1}"' for i in range(len(stt))) + "]",
                  f'    y-axis "WER %" 0 --> {max(100, max(math.ceil(metrics[e["id"]]["wer"] * 100) for e in stt))}',
                  "    bar [" + ", ".join(f'{metrics[e["id"]]["wer"] * 100:.3f}' for e in stt) + "]"]
    else:
        lines += ['    x-axis ["No STT samples"]', '    y-axis "WER %" 0 --> 100', "    bar [0]"]
    lines += ["```", "", "Chart key: " + (", ".join(f'E{i + 1} = {safe(e["id"])}' for i, e in enumerate(stt)) if stt else "no STT data; zero is a placeholder."), "",
              "| Brain (version) | Correct sequences | Invalid proposals | Latency mean / p95 ms | Battery / 10 min | Battery cohort |",
              "|---|---|---|---|---|---|"]
    tool_validator = validator(REPO / "SYS/tools/tool-call.schema.json")
    expected = {c["id"]: c["expected_calls"] for c in run["brain_cases"]}
    ranked = []
    for engine in brain:
        correct = invalid = 0
        for row in engine["results"]:
            valid = all(tool_validator.is_valid(call) for call in row["calls"])
            invalid += not valid
            correct += valid and row["calls"] == expected[row["case_id"]]
        count = len(engine["results"])
        latencies = [r["latency_ms"] for r in engine["results"] if "latency_ms" in r]
        mean = sum(latencies) / count if len(latencies) == count else float("inf")
        ranked.append((-correct / count, mean, engine["id"]))
        lines.append(f'| {safe(engine["id"])} ({safe(engine["version"])}) | {correct}/{count} ({correct / count:.1%}) | {invalid} | {timing(engine["results"], "latency_ms")} | {battery(engine)} | {safe(engine.get("battery", {}).get("cohort_id", "TBD"))} |')
    if ranked:
        lines += ["", f'Brain leader: **{safe(min(ranked)[2])}** (accuracy, then complete mean latency, then ID; no shipping gate specified).']
    lines += ["", "Assumptions and limits:", "",
              "- All engines of a kind cover identical cases; STT comparisons share recording IDs, device, capture source and session. Run sources separately. Recorder provenance is unverified.",
              "- WER is micro-averaged token edit distance; case and punctuation are ignored. Numeric formats are not rewritten. Term accuracy counts expected vocabulary occurrences, including repeats and overlaps, using the same alignment.",
              "- Clipped first words require recorder/human annotation; missing annotations are TBD. First-word deletion is a textual proxy, not evidence of acoustic clipping.",
              "- Timing uses supplied monotonic durations (speech start→first text; EOS→final; brain request→complete proposal). Missing samples are excluded with n shown. Battery is supplied percentage-point drain scaled to 600 seconds, not energy attribution.",
              "- Brain correctness requires schema-valid, exactly ordered calls with exact arguments; object key order is ignored. Invalid proposals count as incorrect. No calls are executed and no authority is granted.",
              "- Proposed term target remains TBC until owner approval. Synthetic verdicts only exercise the gate; real shipping needs the full owner set on a named phone, both microphones and owner review. Latency and battery have no added shipping thresholds.",
              "- No prompt text or proposals are printed. Keep owner exports and reports local and out of CI logs and git; preserve measurement evidence in an owner-approved private location."]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Offline scorer; never executes tool calls")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("report", help="print a Markdown report to stdout")
    command.add_argument("run")
    command.add_argument("--config", default=str(ROOT / "gate.json"))
    args = parser.parse_args()
    try:
        output = report(read_json(args.run), read_json(args.config))
    except (ValueError, ValidationError, OSError) as error:
        # ValidationError's default text contains input values: keep transcripts out of errors.
        detail = "schema validation failed" if isinstance(error, ValidationError) else "invalid or unreadable input"
        print(f"vr-bench: {detail}; check local inputs against schemas (contents suppressed)", file=sys.stderr)
        return 2
    print(output, end="")
    return 0
