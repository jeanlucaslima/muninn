# Muninn v2 — Decisions

Companion to `docs/designs/muninn-v2.md` and `docs/proofs.md`. Every decision has an ID that is never reused. A reversed decision is marked **Revised** with its date; it's never deleted.

**Statuses:** **Accepted** · **Revised** · **Pending proof** (accepted in principle, but only built once the named proof passes) · **Open** (needs input) · **Deferred**

## Waiting on proofs

These decisions are accepted only as hypotheses. Nothing that depends on them is built until their proof passes.

| Decision | Hypothesis | Proof |
|---|---|---|
| D2 | SQLCipher's official Swift package gives encryption + FTS5 (word and trigram) in our build | PROOF-004 |
| D3 / §4.4 | A private data-protection keychain group works for a Developer ID helper (bundle or bare executable) | PROOF-003 |
| D15 | Chunked assets **inside** SQLCipher are acceptable for size, latency, WAL and backups; an external store is needed only if not | PROOF-005 |
| D16 | Trigram index size is acceptable at 100k items, or needs a cap | PROOF-004 |
| D17 | An on-demand sandboxed XPC worker isolates crashes and returns memory | PROOF-013 |
| D21 | The Unix socket plus audit-token code identity is as reliable as XPC, at an acceptable implementation cost | PROOF-002 |
| D22 | Secure Enclave wrapping adds real protection without breaking unattended unlock | PROOF-017 (deferred) |
| D23 | Which process reads the pasteboard: helper or app | PROOF-001 |
| D30 | Indexing small plain text inside the capture transaction is cheap enough for the capture targets | PROOF-008 |
| D5 | macOS 15 minimum is enough for every API we depend on | PROOF-001…004 (by build) |

## Register

### Decided (2026-11-08)

| # | Decision | Outcome |
|---|---|---|
| D2 | How to bring in SQLCipher | **Revised:** SQLCipher's official Swift package via SwiftPM. This is Muninn's first external dependency and the deliberate exception to the minimal-deps rule. Pin an exact version. Before adopting, verify that the license (Community Edition, BSD-style) fits. **Build verification, run in CI against the exact packaged binary:** the package is configured with `SQLITE_HAS_CODEC`; `PRAGMA cipher_version` is non-empty; a newly created DB file does **not** start with `SQLite format 3` (it's encrypted); opening it without the key fails; FTS5 with both the `unicode61` and the `trigram` tokenizers can be created and queried. |
| D3 | Who holds the DB key | Helper only. UI and CLI go through IPC. |
| D4 | Store original payloads? | **Revised:** keep every compatible pasteboard representation (§4.3). Binary assets go inline or to an external encrypted store, with the threshold set by benchmark. Files are kept as references by default; a snapshot is an explicit capability. |
| D5 | Minimum macOS | macOS 15, which the newer Vision API needs. |
| D6 | Pasteboard change detection | Keep polling (there's no public notification API); revisit the 0.5 s interval. |
| D7 | Excluding sensitive content | At minimum, skip items marked `org.nspasteboard.ConcealedType` / `TransientType`. |
| D8 | Auto-update | None in v2 (Sparkle would be a dependency). |

### Open

| # | Decision | Options | Leaning |
|---|---|---|---|
| D1 | Product scope beyond platform work | snippets, collections, retention/expiry, agent/MCP access, per-app exclude list | Needs input. CLI scope is now defined (§4.11). |
| D9 | Signing identity | personal vs. org Team ID | Needs input |
| D10 | Simulated paste (⌘V into the previous app) from the panel | in v2 vs. later | Later. Needs Accessibility permission; the CLI `paste` prints to stdout instead. |
| D11 | `transform` format list | the initial set in §4.11 vs. more (yaml, csv↔json, hash) | Start with the initial set |
| D12 | What counts as protected | user-marked · protected-apps list · secret detection (API keys, tokens) | User-marked + apps list in v2; heuristic detection later (false negatives would give a false sense of safety) |
| D13 | Lock protected items in the UI too? | always visible in the panel vs. Touch ID to reveal | Touch ID to reveal, as a setting, default off |
| D14 | Extract text from *referenced* files (no snapshot)? | never · opt-in per type with a size cap · on by default | Opt-in. Extracted text is a partial copy of the file, so it falls under the same explicit-capability rule as snapshots. |
| D15 | Asset storage | inline and external from day one · inline only | **Revised 2026-11-09 (review Z2/C1):** every asset is stored as chunks **inside** SQLCipher (`asset_chunks`), with incremental BLOB I/O and incremental auto-vacuum. `assets.storage` reserves `external`. An external store (envelope encryption, crash-safe publish protocol) is designed only if PROOF-005 shows inline is unacceptable. |
| D16 | Trigram index cost on huge items | index everything · index only the first N KB of each representation in the trigram index (word index stays complete) | Decide from the benchmark's index-size numbers. If capped, the cap is documented and `get` reports `trigramIndexedBytes`, so nothing is silently unsearchable. |
| D17 | Run processors out of process | in-helper with limits vs. an on-demand worker | **Revised:** an on-demand `muninn-worker` (sandboxed XPC service in the bundle, run in-process under tests) for **heavy and untrusted** parsing only. **Revised 2026-11-09 (review C4):** three tiers. Materialization (`index`, applying outputs) runs in the helper; light text work is allowed in the helper; heavy parsing runs in the worker. Plain text never touches the worker. |
| D18 | Storage growth once binaries are stored | automatic eviction of old binaries · **no automatic deletion of originals** | **Revised:** history is permanent. Limits apply at capture time; only regenerable data (previews, caches) is pruned automatically; warnings at thresholds and user-driven cleanup tools. A best-effort "binary cache" mode, if ever added, must be opt-in and clearly labeled as not history. |
| D20 | Limit values | numbers in the design · `MuninnLimits` only | **Revised 2026-11-09 (review Z8):** every value (defaults, ceilings, what's user-adjustable) lives only in `MuninnLimits`. The design states what's limited and what happens past the limit. Values are tuned from real use in gate B. |
| D19 | Moving history to a new Mac | not in v2 · encrypted export/import (`muninn export --out file`, passphrase-wrapped key) | Not in v2, but the device-only key consequence (§4.4) is documented from day one. |
| D21 | Transport between app/CLI and helper | Unix socket + our peer auth · XPC Mach service with `xpc_connection_set_peer_code_signing_requirement` | **Needs proof (review Z3):** PROOF-002 compares reliability **and implementation cost**. If the socket stays, §4.6 lists the XPC features we rebuild and why. Evaluate `SCM_RIGHTS` file-descriptor passing instead of binary bodies. |
| D22 | Wrap the DB key with a Secure Enclave key | no · yes | **Deferred.** Adopt only after a spike shows a real security benefit over the data-protection keychain **and** reliable unattended unlock for a background helper after login. |
| D23 | Which process reads the pasteboard | helper · app | Decided by PROOF-001. Leaning: the helper if it's attributed to "Muninn", otherwise the app. |
| D24 | Who draws the scratched raven | commission an illustrator · draw in-house | Needs input. Brief: `docs/brand.md`. Deliverables: layered app icon (`.icon`), menu bar template icon in 4 states, pixel-fit at @1x and @2x; derived first-run, *About* and empty-state art. The terminal ASCII raven is a separate, in-house track. |
| D25 | Stricter unlock mode | none (v2 default: lock with the Mac, reopen on OS unlock) · Touch ID in Muninn after every unlock or restart, enforced by a key with `.userPresence` access control | Not in v2. Revisit with D22; it needs an authenticated context handed from the app to the helper. |
| D26 | Previews for formats ImageIO/PDFKit can't render from memory | generic icon · a file-based preview path | Generic icon in v2. Any file-based path needs its own secure design (e.g. a sandboxed, memory-backed or encrypted-at-rest scratch area with proven cleanup). It must not weaken invariant 1. |
| D27 | Automation (non-interactive) access to history | app-created automation grants · none in v2 | **Deferred 2026-11-09 (review Z4):** no automation access in v2. Grants and the `grants` table are designed only when D1 decides agent access. The `metadata` scope stays (maintainer decision). |
| D28 | Annotation processors (type, language, URLs, image metadata) | ship in v2 · add when a feature needs them | **Deferred 2026-11-09 (review Z7):** v2 ships `text`, `ocr`, `pdf`, `preview` and the `index` step. |
| D29 | Encryption key rotation | manual rotation in v2 · not in v2 | **Not in v2 (review Z2):** the key is device-only, and a compromise implies a threat outside §1.1. If ever needed, `sqlcipher_export` rekeys history and assets in one step. |
| D30 | Index small plain text inside the capture transaction | after commit (default) · inside the transaction | **Pending PROOF-008 (review C4).** Inside the transaction is faster, but it puts work on the capture path. |
| D31 | Production self-monitoring | 24 h memory ring buffer, trend detection and MetricKit · current value only | **Revised 2026-11-09 (review Z7):** `status` and `doctor` show current memory. Trends are covered by the soak benchmark and `leaks` in CI. |
