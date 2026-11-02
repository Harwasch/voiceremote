"""Structural security invariants; mutate schemas in memory to prove detection.

Inputs: the source schemas and generator. Verified by `make -C SYS check`.
"""
import copy
import json
import subprocess
import sys
import unittest

from generate import ROOT, bundle, check_dialect, render, schema_children

# Product §4.1–4.4 and §7: input evidence, policy decisions, approval bindings
# and execution results are trusted; proposed risk/payload and UI state are hints.
FORBIDDEN = {'authenticated_actor', 'activation_kind', 'approval_credential_class',
             'granted_scope_id', 'source_tier', 'approval_event_id', 'policy_version',
             'risk_class', 'payload_hash', 'execution_state', 'outcome',
             'speaker_evidence', 'recording_consent_state'}
DICTATION_FIELDS = {'kind', 'account_id', 'segment_id', 'revision', 'state', 'target_device_id', 'text'}
RELAY_FIELDS = {
    'RelayCiphertext': {'kind', 'account_id', 'room_id', 'sender_device_id', 'ciphertext'},
    'RelayPresence': {'kind', 'account_id', 'room_id', 'sender_device_id', 'state'},
    'RelayWakeRegistration': {'kind', 'account_id', 'room_id', 'sender_device_id', 'apns_wake_token', 'environment'},
}


def reachable(node, defs, seen=None):
    seen = set() if seen is None else seen
    yield node
    if '$ref' in node:
        name = node['$ref'].split('/')[-1]
        if name not in seen:
            seen.add(name)
            yield from reachable(defs[name], defs, seen)
    for child in schema_children(node):
        yield from reachable(child, defs, seen)


def model_invariant(defs):
    for root in ('CandidateAction', 'ToolCall'):
        for node in reachable(defs[root], defs):
            assert not FORBIDDEN.intersection(node.get('properties', {})), f'{root}: model authority field'
            if node.get('type') == 'object':
                assert node.get('additionalProperties') is False, f'{root}: open object'


def dictation_invariant(defs):
    props = defs['DictationText']['properties']
    assert set(props) == DICTATION_FIELDS, 'dictation field surface changed'
    assert props['kind'] == {'const': 'dictation_text'}
    assert props['state'] == {'type': 'string', 'enum': ['partial', 'committed']}, 'dictation state gained an action'
    assert props['text']['type'] == 'string', 'dictation text became structured actions'
    for field in ('account_id', 'segment_id', 'target_device_id'):
        assert props[field] == {'$ref': '#/$defs/Identifier'}, 'dictation identifier gained an action'
    assert props['revision'] == {'$ref': '#/$defs/Counter'}
    assert defs['DictationText']['additionalProperties'] is False
    assert defs['DictationText']['properties']['text'].get('not') == {'pattern': '[\\u0000-\\u001F\\u007F-\\u009F\\u2028\\u2029]'}, 'dictation permits line submission'


def relay_invariant(defs):
    names = {r['$ref'].split('/')[-1] for r in defs['RelayFrame']['oneOf']}
    assert names == RELAY_FIELDS.keys(), 'relay variant surface changed'
    for name, allowed in RELAY_FIELDS.items():
        record = defs[name]
        assert set(record['properties']) == allowed, 'relay plaintext field surface changed'
        assert record['additionalProperties'] is False
        for field, schema in record['properties'].items():
            if field in ('ciphertext', 'apns_wake_token'):
                assert schema == {'$ref': '#/$defs/Base64'}, 'opaque bytes changed to a plaintext type'
            else:
                for node in reachable(schema, defs):
                    assert node.get('type') not in ('object', 'array'), 'relay metadata hides a payload'


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.defs = bundle()['$defs']

    def test_model_authority_fields_are_unreachable(self):
        model_invariant(self.defs)

    def test_dictation_has_only_insertion_fields_and_no_line_separators(self):
        dictation_invariant(self.defs)

    def test_dictation_vectors_cover_every_control_and_keypad_enter(self):
        vectors = json.loads((ROOT / 'SYS/protocol/vectors/golden.json').read_text())
        controls = set(range(0x20)) | set(range(0x7f, 0xa0)) | {0x2028, 0x2029}
        by_name = {v['name']: v for v in vectors['invalid']}
        for point in controls:
            vector = by_name[f'dictation control U+{point:04X}']
            self.assertEqual(vector['schema'], 'DictationText')
            self.assertIn(chr(point), vector['value']['text'])
        self.assertIn('\x1bOM', by_name['dictation control keypad Enter']['value']['text'])
        changed = copy.deepcopy(self.defs)
        del changed['DictationText']['properties']['text']['not']
        with self.assertRaisesRegex(AssertionError, 'submission'):
            dictation_invariant(changed)

    def test_relay_is_only_opaque_bytes_and_allowlisted_metadata(self):
        relay_invariant(self.defs)

    def test_each_record_has_required_account_id_and_is_closed(self):
        for name, schema in self.defs.items():
            if schema.get('type') == 'object':
                with self.subTest(name=name):
                    self.assertIn('account_id', schema['required'])
                    self.assertFalse(schema['additionalProperties'])

    def test_mutations_are_detected_including_nested_tools(self):
        for record in ('CandidateAction', 'DelegateTaskTool'):
            for field in FORBIDDEN:
                with self.subTest(record=record, field=field):
                    changed = copy.deepcopy(self.defs)
                    changed[record]['properties'][field] = {'type': 'string'}
                    with self.assertRaisesRegex(AssertionError, 'model authority'):
                        model_invariant(changed)
        for record, field, check in [('DictationText', 'send', dictation_invariant),
                                     ('RelayCiphertext', 'plaintext_payload', relay_invariant)]:
            changed = copy.deepcopy(self.defs)
            changed[record]['properties'][field] = {'type': 'string'}
            with self.assertRaises(AssertionError):
                check(changed)

    def test_generator_is_deterministic(self):
        self.assertEqual(render(), render())

    def test_unsupported_keywords_fail_closed(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            check_dialect({'type': 'string', 'format': 'arbitrary-future-rule'})
        with self.assertRaisesRegex(ValueError, 'portability'):
            check_dialect({'type': 'string', 'pattern': '(?=lookahead)'})
        with self.assertRaisesRegex(ValueError, 'safe bounds'):
            check_dialect({'type': 'integer', 'minimum': -1, 'maximum': 42})

    def test_stale_check_fails_without_overwriting(self):
        path = next(iter(render()))
        existing = path.read_text()
        try:
            path.write_text(existing + '// intentional stale-check probe\n')
            result = subprocess.run([sys.executable, str(ROOT / 'SYS/codegen/generate.py'), '--check'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Stale generated files', result.stderr)
            self.assertEqual(path.read_text(), existing + '// intentional stale-check probe\n')
        finally:
            path.write_text(existing)

    def test_every_record_and_union_has_a_shared_valid_vector(self):
        vectors = json.loads((ROOT / 'SYS/protocol/vectors/golden.json').read_text())
        covered = {v['schema'] for v in vectors['valid']}
        records = {n for n, s in self.defs.items() if s.get('type') == 'object' or 'oneOf' in s}
        self.assertFalse(records - covered, f'Uncovered types: {records - covered}')


if __name__ == '__main__':
    unittest.main()
