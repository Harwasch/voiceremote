# Generator maintenance

| Feature | Supported usage |
|---|---|
| Types | Closed named records, named string enums, string/integer/number/bool aliases, typed arrays |
| References | Local `$defs` and cross-document refs to the two locally registered `$id` values; no remote fetching or cycles |
| Unions | `oneOf` of named records, distinguished by unique literal `kind` fields |
| Presence | `required` + absence for optionals; no nullable fields or free-form maps |
| Constraints | `const`, `enum`, numeric bounds, string/array lengths, the contract's reviewed pattern strings |
| Conditions | `allOf`, `if` + `then`, `not` for trusted-command approval rules and text/byte constraints |
| Annotations | `$schema`, `$id`, `$defs`, `title`, `description` |

Unsupported keywords, unreviewed regex patterns and unsafe integer aliases fail
generation rather than silently losing validation.
This is a contract-specific generator, not a general JSON Schema implementation.
Extending the dialect needs runtime changes in all languages and independent
Ajv comparisons against new shared vectors. Swift counts Unicode scalars, Rust
counts Unicode characters, and Ajv uses Unicode string lengths. Wire codecs first
parse strict JSON, retaining number token kinds and detecting duplicate decoded
keys before native decoders discard them. Integer fields reject `1.0` and `1e0`;
there is no integer normalization. The TS codec adds an internal Ajv keyword to
integer definitions so JSON-pointer paths retain this lexical restriction.

The original schemas and their generated bundle are both compiled by Ajv in the
TS suite. Every named record and union needs a valid shared vector; unknown
fields, nested authority fields, unsafe integers, malformed base64, dictation
controls and unapproved inferred commands have negative fixtures. `raw_invalid`
fixtures exercise duplicates, surrogates, lossy numeric spellings and grammar;
JSON Schema alone cannot express those lexical rules.

No third-party generator code is copied. Runtime dependencies are serde,
serde_json and regex (MIT/Apache-2.0), Ajv and Vitest (MIT), TypeScript
(Apache-2.0); installed package manifests supply their license declarations.
No Hex/Handy source is reused. Full transitive license audit is **unverified**.

Swift implements the six reviewed patterns with scalar-value predicates and full-sequence ASCII
checks rather than regex. This avoids CRLF grapheme splitting and platform-specific anchor rules.
The generator invariant checks matcher coverage whenever the pattern allowlist changes.
