#!/usr/bin/env python3
"""Generate the deliberately small, closed JSON Schema dialect in this repo.

Inputs: SYS/{protocol,tools}/*.schema.json and adjacent runtime templates.
Verified by test_contract.py and the shared three-language golden vectors.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCES = [ROOT / 'SYS/tools/tool-call.schema.json', ROOT / 'SYS/protocol/protocol.schema.json']
OUTPUTS = {
    'swift': ROOT / 'SW/ios/Packages/Protocol/Sources/VoiceRemoteProtocol/Generated.swift',
    'rust': ROOT / 'SW/desktop/crates/protocol/src/generated.rs',
    'ts': ROOT / 'SW/relay/src/protocol/generated.ts',
}
KEYWORDS = {'$schema', '$id', '$defs', '$ref', 'title', 'description', 'type',
            'properties', 'required', 'additionalProperties', 'items', 'minItems',
            'maxItems', 'minLength', 'maxLength', 'minimum', 'maximum', 'pattern',
            'const', 'enum', 'oneOf', 'allOf', 'if', 'then', 'not'}
PORTABLE_PATTERNS = {
    '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
    '^[A-Za-z0-9+/]{43}=$', '[^A-Za-z0-9+/=]', '^[0-9a-f]+$', '[^0-9a-f]',
    '[\\u0000-\\u001F\\u007F-\\u009F\\u2028\\u2029]',
}


def pascal(s):
    return ''.join(p[:1].upper() + p[1:] for p in s.split('_'))


def schema_children(node):
    yield from node.get('properties', {}).values()
    yield from node.get('$defs', {}).values()
    yield from node.get('oneOf', [])
    yield from node.get('allOf', [])
    for k in ('items', 'if', 'then', 'not'):
        if k in node:
            yield node[k]


def check_dialect(node):
    unknown = node.keys() - KEYWORDS
    if unknown:
        raise ValueError(f'Unsupported schema keywords: {sorted(unknown)}')
    if '$ref' in node and set(node) - {'$ref', '$schema', '$id', '$defs', 'title', 'description'}:
        raise ValueError('$ref siblings are outside the generator dialect')
    if 'pattern' in node and node['pattern'] not in PORTABLE_PATTERNS:
        raise ValueError('New regex pattern needs portability review and vectors')
    if 'type' in node and node['type'] not in {'string', 'integer', 'number', 'boolean', 'array', 'object'}:
        raise ValueError('Unsupported schema type')
    if node.get('type') == 'integer' and not (0 <= node.get('minimum', -1) <= node.get('maximum', 0) <= 9007199254740991):
        raise ValueError('Integer aliases need nonnegative JavaScript-safe bounds')
    if 'enum' in node and (not node['enum'] or not all(isinstance(v, str) for v in node['enum'])):
        raise ValueError('Only nonempty string enums are supported')
    if 'const' in node and not isinstance(node['const'], str):
        raise ValueError('Only string discriminators are supported')
    if node.get('type') == 'object':
        if node.get('additionalProperties') is not False:
            raise ValueError('Records must be closed')
        if set(node.get('required', [])) - node.get('properties', {}).keys():
            raise ValueError('required names an undefined field')
    if node.get('type') == 'array' and 'items' not in node:
        raise ValueError('Arrays need typed items')
    for child in schema_children(node):
        check_dialect(child)


def bundle():
    docs = [json.loads(p.read_text()) for p in SOURCES]
    ids = {d['$id'] for d in docs}

    def normalize(node):
        if isinstance(node, list):
            return [normalize(n) for n in node]
        if not isinstance(node, dict):
            return node
        result = {k: normalize(v) for k, v in node.items()}
        if '$ref' in result:
            base, fragment = result['$ref'].split('#', 1)
            if base and base not in ids:
                raise ValueError(f'External schema not available locally: {base}')
            if not re.fullmatch(r'/\$defs/[A-Za-z][A-Za-z0-9]*', fragment):
                raise ValueError(f'Unsupported reference {fragment}')
            result['$ref'] = '#' + fragment
        return result

    defs = {}
    for doc in docs:
        check_dialect(doc)
        for name, schema in doc['$defs'].items():
            schema = normalize(schema)
            # A same-name cross-document import resolves to the canonical local
            # definition after bundling. Its owner can appear in either order.
            if schema == {'$ref': '#/$defs/' + name}:
                continue
            if name in defs:
                if schema == defs[name]:
                    continue
                raise ValueError(f'Conflicting definition: {name}')
            defs[name] = schema
    # Reject missing/cyclic references before generating potentially recursive types.
    def visit(node, stack=()):
        if '$ref' in node:
            name = node['$ref'].split('/')[-1]
            if name in stack:
                raise ValueError(f'Recursive reference: {name}')
            visit(defs[name], (*stack, name))
        for child in schema_children(node):
            visit(child, stack)
    for name, schema in defs.items():
        visit(schema, (name,))
    return {'$schema': docs[0]['$schema'], '$id': 'https://voiceremote.invalid/bundle/v1', '$defs': defs}


def models(defs, lang):
    # Give inline enums and kind constants real nominal types in Swift/Rust.
    enums = {}
    for name, s in defs.items():
        if 'enum' in s:
            enums[name] = s['enum']
        for key, p in s.get('properties', {}).items():
            if 'enum' in p or 'const' in p:
                enums[name + pascal(key)] = p.get('enum', [p.get('const')])

    def typ(s, owner='', field=''):
        if '$ref' in s:
            return s['$ref'].split('/')[-1]
        if 'enum' in s or 'const' in s:
            if lang == 'ts':
                return ' | '.join(json.dumps(v) for v in s.get('enum', [s.get('const')]))
            return owner + pascal(field)
        t = s['type']
        if t == 'array':
            inner = typ(s['items'])
            return {'swift': f'[{inner}]', 'rust': f'Vec<{inner}>', 'ts': f'Array<{inner}>'}[lang]
        return {'string': {'swift': 'String', 'rust': 'String', 'ts': 'string'},
                'integer': {'swift': 'Int64', 'rust': 'u64', 'ts': 'number'},
                'number': {'swift': 'Double', 'rust': 'f64', 'ts': 'number'},
                'boolean': {'swift': 'Bool', 'rust': 'bool', 'ts': 'boolean'}}[t][lang]

    out = []
    if lang != 'ts':
        for name, values in enums.items():
            if lang == 'swift':
                out.append(f'public enum {name}: String, Codable, Sendable {{')
                out += [f'    case {v} = {json.dumps(v)}' for v in values]
            else:
                out += ['#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]', f'pub enum {name} {{']
                out += [f'    #[serde(rename = {json.dumps(v)})]\n    {pascal(v)},' for v in values]
            out.append('}\n')

    for name, s in defs.items():
        if 'enum' in s and lang != 'ts':
            continue
        if s.get('type') == 'object':
            props = s['properties']
            required = set(s['required'])
            if lang == 'ts':
                out.append(f'export interface {name} {{')
                out += [f'  {k}{"" if k in required else "?"}: {typ(p, name, k)};' for k, p in props.items()]
            elif lang == 'rust':
                out += ['#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]',
                        '#[serde(deny_unknown_fields)]', f'pub struct {name} {{']
                for k, p in props.items():
                    t = typ(p, name, k)
                    if k not in required:
                        out.append('    #[serde(skip_serializing_if = "Option::is_none")]')
                        t = f'Option<{t}>'
                    out.append(f'    pub {k}: {t},')
            else:
                out.append(f'public struct {name}: ProtocolRecord, Equatable {{')
                out.append(f'    public static let schemaName = "{name}"')
                for k, p in props.items():
                    out.append(f'    public let {k}: {typ(p, name, k)}{"" if k in required else "?"}')
                args = []
                for k, p in props.items():
                    t = typ(p, name, k)
                    default = ''
                    if 'const' in p:
                        default = f' = .{p["const"]}'
                    if k not in required:
                        t += '?'
                        default = ' = nil'
                    args.append(f'{k}: {t}{default}')
                out.append('    public init(' + ', '.join(args) + ') {')
                out += [f'        self.{k} = {k}' for k in props]
                out.append('    }')
                out.append('    private enum CodingKeys: String, CodingKey { case ' + ', '.join(props) + ' }')
                out += ['    public init(from decoder: Decoder) throws {',
                        '        try Schema.validate(Self.schemaName, JSONValue(from: decoder))',
                        '        let c = try decoder.container(keyedBy: CodingKeys.self)']
                for k, p in props.items():
                    method = 'decode' if k in required else 'decodeIfPresent'
                    out.append(f'        self.{k} = try c.{method}({typ(p, name, k)}.self, forKey: .{k})')
                out.append('    }')
            out.append('}\n')
        elif 'oneOf' in s:
            names = [r['$ref'].split('/')[-1] for r in s['oneOf']]
            if lang == 'ts':
                out.append(f'export type {name} = ' + ' | '.join(names) + ';\n')
            elif lang == 'rust':
                out += ['#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]', '#[serde(untagged)]', f'pub enum {name} {{']
                out += [f'    {n}({n}),' for n in names]
                out.append('}\n')
            else:
                out += [f'public enum {name}: ProtocolRecord, Equatable {{', f'    public static let schemaName = "{name}"']
                out += [f'    case {n[:1].lower()+n[1:]}({n})' for n in names]
                out += ['    public init(from decoder: Decoder) throws {',
                        '        try Schema.validate(Self.schemaName, JSONValue(from: decoder))',
                        '        let c = try decoder.singleValueContainer()']
                for n in names:
                    out.append(f'        if let value = try? c.decode({n}.self) {{ self = .{n[:1].lower()+n[1:]}(value); return }}')
                out += ['        throw WireError.invalid("No matching union variant")', '    }',
                        '    public func encode(to encoder: Encoder) throws {', '        switch self {']
                out += [f'        case .{n[:1].lower()+n[1:]}(let value): try value.encode(to: encoder)' for n in names]
                out += ['        }', '    }', '}\n']
        else:
            if lang == 'ts':
                out.append(f'export type {name} = {typ(s)};\n')
            elif lang == 'rust':
                out.append(f'pub type {name} = {typ(s)};\n')
            else:
                out.append(f'public typealias {name} = {typ(s)}\n')

    if lang == 'ts':
        out += ['export interface Records {'] + [f'  {n}: {n};' for n in defs] + ['}']
    if lang == 'rust':
        for n, s in defs.items():
            if s.get('type') == 'object' or 'oneOf' in s:
                out.append(f'impl WireRecord for {n} {{ const SCHEMA_NAME: &\'static str = "{n}"; }}')
    return '\n'.join(out) + '\n'


def render():
    schema = bundle()
    compact = json.dumps(schema, separators=(',', ':'), ensure_ascii=True)
    results = {}
    for lang, path in OUTPUTS.items():
        template = (HERE / 'templates' / f'runtime.{lang}').read_text()
        results[path] = template.replace('@SCHEMA@', compact).replace('@MODELS@', models(schema['$defs'], lang))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Regenerate in memory; fail instead of overwriting stale outputs')
    args = parser.parse_args()
    stale = []
    for path, content in render().items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    if stale:
        raise SystemExit('Stale generated files; run make -C SYS generate:\n' + '\n'.join(stale))
    print('Regenerated Swift, Rust, TypeScript: ' + ('byte-for-byte current' if args.check else 'written'))


if __name__ == '__main__':
    main()
