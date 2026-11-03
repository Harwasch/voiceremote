"""Purpose: validate exports offline against local contracts. Inputs: JSON. Verified by tests."""
import json
import math
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def read_json(path):
    # Reject non-JSON NaN/Infinity rather than letting missing timing checks pass.
    def reject(value):
        raise ValueError(f"non-finite JSON number: {value}")

    def finite_float(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("non-finite JSON number")
        return result

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    return json.loads(Path(path).read_text(), parse_constant=reject, parse_float=finite_float, object_pairs_hook=unique)


def validator(schema_path):
    paths = [REPO / "SYS/tools/tool-call.schema.json",
             REPO / "SYS/protocol/protocol.schema.json",
             ROOT / "schemas/run.schema.json"]
    registry = Registry()
    for path in paths:
        schema = read_json(path)
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
    # No HTTP retrieval is configured: all references resolve locally or fail.
    return Draft202012Validator(read_json(schema_path), registry=registry)


def validate_run(run):
    validator(ROOT / "schemas/run.schema.json").validate(run)
    for field in ("stt_cases", "brain_cases", "engines"):
        ids = [entry["id"] for entry in run[field]]
        if len(ids) != len(set(ids)):
            raise ValueError(f"duplicate id in {field}")
    from .scoring import tokens
    vocab = [tuple(tokens(term)) for term in run["vocabulary"]]
    if any(not term for term in vocab) or len(set(vocab)) != len(vocab):
        raise ValueError("vocabulary must contain unique, nonempty normalized terms")
    if any(not tokens(case["expected_text"]) for case in run["stt_cases"]):
        raise ValueError("STT expected_text needs at least one word")
    for engine in run["engines"]:
        cases = run["stt_cases" if engine["kind"] == "stt" else "brain_cases"]
        ids = [row["case_id"] for row in engine["results"]]
        if not cases or len(ids) != len(set(ids)) or set(ids) != {c["id"] for c in cases}:
            raise ValueError("each engine needs exactly one result per case of its kind")

        for row in engine["results"]:
            stages = row.get("stages", {})
            order = ("cleanup_started_ms", "cleanup_completed_ms", "delivery_started_ms",
                     "delivery_completed_ms", "field_confirmed_ms")
            values = [stages[key] for key in order if key in stages]
            if values != sorted(values):
                raise ValueError("stage timestamps must be ordered on one monotonic capture clock")
            for end, start in (("cleanup_completed_ms", "cleanup_started_ms"),
                               ("delivery_completed_ms", "delivery_started_ms"),
                               ("field_confirmed_ms", "delivery_started_ms")):
                if end in stages and start not in stages:
                    raise ValueError("completed stage requires its start timestamp")
        spoken = ["recording_id" in case for case in cases] if engine["kind"] == "brain" else []
        if any(spoken) and (not all(spoken) or any("transcript" not in row for row in engine["results"])):
            raise ValueError("spoken commands require recording IDs and recognized transcripts for every case")
