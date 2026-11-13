# CLI JSON schemas

JSON Schemas (draft 2020-12) for every `muninn … --json` output: part of the CLI contract (design §4.11, rule 1). The CLI tests validate real outputs against them, so a schema and the code can't drift apart silently.

| Command | Schema |
|---|---|
| `status` | `status.json` |
| `status --limits` | `limits.json` |
| `list`, `search` | `page.json` |
| `history` | `history.json` |
| `get` | `get.json` |
| `copy`, `pin`, `unpin`, `delete` | `item-ref.json` |
| `pause`, `resume` | `paused.json` |
| `doctor` | `doctor.json` |
| any failure (on stderr) | `error.json` |

`paste` writes raw bytes, never JSON. `debug send` prints the helper's raw IPC replies, which aren't part of the CLI contract.

Rules:
- Every output carries `schemaVersion` (`common.json`). Within a version, changes are additive only.
- Keys are `camelCase`, timestamps ISO-8601 UTC with milliseconds, ids integers.
- Optional keys are omitted when empty, never `null`.
- `additionalProperties: false` documents the current shape exactly; consumers should still ignore keys they don't know, since later versions may add some.
