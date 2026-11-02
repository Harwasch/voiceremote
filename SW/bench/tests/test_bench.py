"""Purpose: synthetic-only metric/contract checks. Inputs: invented fixtures. No engine measurements."""
import copy
import json
import subprocess
import sys

import pytest
from jsonschema import ValidationError

from benchkit.cli import report
from benchkit.scoring import align, battery, gate, stt_metrics, timing, tokens
from benchkit.validation import ROOT, REPO, read_json, validate_run, validator


@pytest.fixture
def run():
    return read_json(ROOT / "fixtures/synthetic-run.json")


@pytest.fixture
def config():
    return read_json(ROOT / "gate.json")


def test_synthetic_report_verdicts_and_chart(run, config):
    output = report(run, config)
    assert "SYNTHETIC DATA" in output
    assert "STT winner against gate: **passing-engine**" in output
    assert "PASS: term error reduction 66.7%" in output
    assert "FAIL: WER does not beat Apple" in output
    assert "Brain leader: **synthetic-brain-correct**" in output
    assert "1.000 pp" in output
    assert output.count("xychart-beta") == 1
    assert "codec checks geek" not in output


@pytest.mark.parametrize("ref,hyp,edits", [
    ("one two three", "one four three", 1),
    ("one two", "one extra two", 1),
    ("first second", "second", 1),
    ("one two", "", 2),
    ("ONE, two!", "one two", 0),
    ("one", "one two three", 2),
])
def test_edit_distance(ref, hyp, edits):
    assert align(tokens(ref), tokens(hyp))[0] == edits


def test_micro_average_repeated_multiword_and_clipping():
    cases = [dict(id='a', expected_text='Codex Core ML Codex'), dict(id='b', expected_text='start')]
    results = [dict(case_id='a', text='Codex Core extra ML wrong', clipped_first_word=False),
               dict(case_id='b', text='', clipped_first_word=True)]
    m = stt_metrics(cases, results, ['Codex', 'Core ML'])
    assert m['errors'] == 3
    assert m['words'] == 5
    assert m['wer'] == .6
    assert (m['term_errors'], m['term_total']) == (2, 3)
    assert (m['clipped'], m['clipped_n'], m['first_deleted']) == (1, 2, 1)


def test_no_terms_or_annotations_is_unknown():
    m = stt_metrics([dict(id='a', expected_text='hello')], [dict(case_id='a', text='hello')], ['Codex'])
    assert m['term_accuracy'] is None
    assert m['clipped_n'] == 0


def metric(wer=.2, errors=3, total=8):
    return dict(wer=wer, term_errors=errors, term_total=total)


@pytest.mark.parametrize("candidate,baseline,target,prefix", [
    (metric(), metric(.3, 4), .25, 'PASS'),
    (metric(), metric(.3, 4), .26, 'FAIL'),
    (metric(.3), metric(.3, 4), .25, 'FAIL'),
    (metric(.4), metric(.3, 4), .25, 'FAIL'),
    (metric(errors=0), metric(.3, 0), .25, 'FAIL'),
    (metric(), None, .25, 'INCOMPLETE'),
    (metric(), metric(.3, 0, 0), .25, 'INCOMPLETE'),
    (metric(errors=4), metric(.3, 4), 0, 'FAIL'),
    (metric(errors=0), metric(.3, 4), 1, 'PASS'),
])
def test_gate_boundaries(candidate, baseline, target, prefix):
    assert gate(candidate, baseline, target).startswith(prefix)


def test_threshold_override_and_no_winner(run, config):
    config['minimum_term_error_reduction'] = .9
    text = report(run, config)
    assert 'NONE — no candidate qualified' in text
    assert 'FAIL: term error reduction 66.7%' in text


def test_absent_apple_never_passes(run, config):
    run['engines'] = run['engines'][1:]
    assert 'INCOMPLETE: Apple baseline missing' in report(run, config)


def test_missing_and_partial_measurements():
    assert timing([], 'latency_ms') == 'TBD (n=0)'
    assert timing([{}, {'latency_ms': 20}, {'latency_ms': 10}], 'latency_ms') == '15.0 / 20.0 (n=2)'
    assert battery({}) == 'TBD'
    assert battery({'battery': dict(duration_seconds=300, drain_percentage_points=1)}) == '2.000 pp'


@pytest.mark.parametrize('mutation', ['missing', 'duplicate', 'unknown', 'duplicate_engine', 'duplicate_case', 'negative', 'extra', 'empty_words', 'duplicate_vocab', 'empty_vocab', 'bad_battery'])
def test_reject_bad_comparisons(run, mutation):
    engine = run['engines'][0]
    if mutation == 'missing':
        engine['results'].pop()
    elif mutation == 'duplicate':
        engine['results'][1] = copy.deepcopy(engine['results'][0])
    elif mutation == 'unknown':
        engine['results'][0]['case_id'] = 'unknown'
    elif mutation == 'duplicate_engine':
        run['engines'].append(copy.deepcopy(engine))
    elif mutation == 'duplicate_case':
        run['stt_cases'].append(copy.deepcopy(run['stt_cases'][0]))
    elif mutation == 'negative':
        engine['results'][0]['first_text_ms'] = -1
    elif mutation == 'extra':
        engine['results'][0]['unknown_field'] = True
    elif mutation == 'empty_words':
        run['stt_cases'][0]['expected_text'] = '...'
    elif mutation == 'duplicate_vocab':
        run['vocabulary'].append('CODEX!')
    elif mutation == 'empty_vocab':
        run['vocabulary'].append('!!!')
    elif mutation == 'bad_battery':
        engine['battery']['duration_seconds'] = 0
    with pytest.raises((ValueError, ValidationError)):
        validate_run(run)


@pytest.mark.parametrize("field", ["authenticated_actor", "activation_kind", "approval_credential_class", "granted_scope_id"])
def test_expected_authority_rejected_actual_authority_scored_incorrect(run, config, field):
    expected = run['brain_cases'][0]['expected_calls'][0]
    run['engines'][-2]['results'][0]['calls'] = [{**expected, field: 'forbidden'}]
    output = report(run, config)
    assert '| synthetic-brain-correct (synthetic-1) | 0/1 (0.0%) | 1 |' in output
    assert 'forbidden' not in output
    expected[field] = 'forbidden'
    with pytest.raises(ValidationError):
        validate_run(run)


def test_brain_arguments_and_call_order_are_exact(run, config):
    first = run['brain_cases'][0]['expected_calls'][0]
    second = {**first, 'device_id': 'bench-laptop'}
    run['brain_cases'][0]['expected_calls'] = [first, second]
    run['engines'][-2]['results'][0]['calls'] = [second, first]
    assert '| synthetic-brain-correct (synthetic-1) | 0/1 (0.0%) | 0 |' in report(run, config)
    run['engines'][-2]['results'][0]['calls'] = [dict(reversed(list(c.items()))) for c in [first, second]]
    assert '| synthetic-brain-correct (synthetic-1) | 1/1 (100.0%) | 0 |' in report(run, config)


def test_brain_only(run, config):
    run['stt_cases'] = []
    run['engines'] = run['engines'][-2:]
    assert 'no STT data' in report(run, config)


def test_curated_sets_use_offline_contract_and_have_required_counts(run):
    phrases = read_json(ROOT / 'sets/phrases.json')['phrases']
    commands = read_json(ROOT / 'sets/commands.json')['commands']
    assert len(phrases) == len({p['id'] for p in phrases}) == 200
    assert len({p['expected_text'] for p in phrases}) == 200
    assert {cat: sum(p['category'] == cat for p in phrases) for cat in {p['category'] for p in phrases}} == dict(normal=40, whispering=40, names=40, numbers=40, tech_terms=40)
    assert len(commands) == len({c['id'] for c in commands}) == 50
    assert len({c['expected_calls'][0]['kind'] for c in commands}) == 5
    run['stt_cases'] = [{**p, 'recording_id': 'synthetic-' + p['id']} for p in phrases]
    run['brain_cases'] = commands
    run['vocabulary'] = read_json(ROOT / 'sets/vocabulary.json')['terms']
    run['engines'] = [dict(id='synthetic',kind='stt',version='test',results=[dict(case_id=p['id'],text=p['expected_text']) for p in phrases]),
                      dict(id='synthetic-brain',kind='brain',version='test',results=[dict(case_id=c['id'],calls=c['expected_calls']) for c in commands])]
    validate_run(run)
    for path in [ROOT / 'schemas/run.schema.json', ROOT / 'schemas/gate.schema.json']:
        validator(path).check_schema(read_json(path))
    tool = validator(REPO / 'SYS/tools/tool-call.schema.json')
    for command in commands:
        for call in command['expected_calls']:
            tool.validate(call)


@pytest.mark.parametrize('bad_json', ['{"x": NaN}', '{"x": Infinity}', '{"x": 1e999}', '{"x": 1, "x": 2}'])
def test_strict_json(tmp_path, bad_json):
    path = tmp_path / 'synthetic.json'
    path.write_text(bad_json)
    with pytest.raises(ValueError):
        read_json(path)


def test_cli_suppresses_invalid_input_contents(tmp_path):
    path = tmp_path / 'synthetic-invalid.json'
    path.write_text(json.dumps({'synthetic_secret_marker': 'do not print me'}))
    process = subprocess.run([sys.executable, '-c', 'from benchkit.cli import main; raise SystemExit(main())', 'report', str(path)], capture_output=True, text=True)
    assert process.returncode == 2
    assert 'schema validation failed' in process.stderr
    assert 'synthetic_secret_marker' not in process.stderr
    assert not process.stdout


def test_fractional_target_not_rounded_in_report(run, config):
    config['minimum_term_error_reduction'] = .255
    assert '≥25.5% fewer term errors' in report(run, config)


def test_cli_success_from_checkout():
    process = subprocess.run(['vr-bench', 'report', str(ROOT / 'fixtures/synthetic-run.json')], capture_output=True, text=True)
    assert process.returncode == 0
    assert 'SYNTHETIC DATA' in process.stdout
    assert 'PASS: term error reduction 66.7%' in process.stdout
    assert 'FAIL: WER does not beat Apple' in process.stdout
    assert not process.stderr


def test_real_export_cannot_use_synthetic_capture_source(run):
    run['synthetic'] = False
    with pytest.raises(ValidationError):
        validate_run(run)
