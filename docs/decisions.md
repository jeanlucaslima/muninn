# Muninn v2 — Decisions

Companion to `docs/designs/muninn-v2.md` and `docs/proofs.md`. Every decision has an ID that is never reused. A reversed decision is marked **Revised** with its date; it's never deleted.

**Statuses:** **Accepted** · **Revised** · **Pending proof** (accepted in principle, but only built once the named proof passes) · **Open** (needs input) · **Deferred**

## Waiting on proofs

These decisions are accepted only as hypotheses. Nothing that depends on them is built until their proof passes.

| Decision | Hypothesis | Proof |
|---|---|---|
| D2 | SQLCipher's official Swift package gives encryption + FTS5 (word and trigram) in our build | PROOF-004 |
| D3 / §4.4 | A private data-protection keychain group works for a Developer ID helper (bundle or bare executable) | PROOF-003 |
| D15 | The inline/external asset threshold, and whether an external encrypted store is worth having **at all** | PROOF-005 |
| D16 | Trigram index size is acceptable at 100k items, or needs a cap | PROOF-004 |
| D17 | An on-demand sandboxed XPC worker isolates crashes and returns memory | PROOF-013 |
| D21 | The Unix socket plus audit-token code identity rejects unauthorized clients reliably | PROOF-002 |
| D22 | Secure Enclave wrapping adds real protection without breaking unattended unlock | PROOF-017 (deferred) |
| D23 | Which process reads the pasteboard: helper or app | PROOF-001 |
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
| D15 | Asset size cap and the inline/external threshold | — | Set by PROOF-005 |
| D16 | Trigram index cost on huge items | index everything · index only the first N KB of each representation in the trigram index (word index stays complete) | Decide from the benchmark's index-size numbers. If capped, the cap is documented and `get` reports `trigramIndexedBytes`, so nothing is silently unsearchable. |
| D17 | Run processors out of process | in-helper with limits vs. an on-demand worker | **Revised:** an on-demand `muninn-worker` (sandboxed XPC service in the bundle, run in-process under tests). It keeps the helper small (§4.13) and isolates parsing of untrusted files (§1.1). |
| D18 | Storage growth once binaries are stored | automatic eviction of old binaries · **no automatic deletion of originals** | **Revised:** history is permanent. Limits apply at capture time; only regenerable data (previews, caches) is pruned automatically; warnings at thresholds and user-driven cleanup tools. A best-effort "binary cache" mode, if ever added, must be opt-in and clearly labeled as not history. |
| D20 | Limit defaults (§4.14) | the values in the §4.14 tables | Start there and tune rate limits and caps from real usage in gate B. Hard ceilings are fixed in code. |
| D19 | Moving history to a new Mac | not in v2 · encrypted export/import (`muninn export --out file`, passphrase-wrapped key) | Not in v2, but the device-only key consequence (§4.4) is documented from day one. |
| D21 | Transport between app/CLI and helper | keep the Unix socket + our peer auth · XPC Mach service (launchd `MachServices`) with `xpc_connection_set_peer_code_signing_requirement` | Keep the socket: one transport for app and CLI, inspectable with `muninn debug send` and in dev with `socat`, and our audit-token check uses the same `SecCode` machinery as XPC. Revisit if the peer-auth code proves fragile. |
| D22 | Wrap the DB key with a Secure Enclave key | no · yes | **Deferred.** Adopt only after a spike shows a real security benefit over the data-protection keychain **and** reliable unattended unlock for a background helper after login. |
| D23 | Which process reads the pasteboard | helper · app | Decided by PROOF-001. Leaning: the helper if it's attributed to "Muninn", otherwise the app. |
| D24 | Who draws the scratched raven | commission an illustrator · draw in-house | Needs input. Brief: §4.17. Deliverables: layered app icon (`.icon`), menu bar template icon in 4 states pixel-fit at @1x/@2x, derived first-run, *About* and empty-state art. The terminal ASCII raven is a separate, in-house track. |
| D25 | Stricter unlock mode | none (v2 default: lock with the Mac, reopen on OS unlock) · Touch ID in Muninn after every unlock or restart, enforced by a key with `.userPresence` access control | Not in v2. Revisit with D22; it needs an authenticated context handed from the app to the helper. |
| D26 | Previews for formats ImageIO/PDFKit can't render from memory | generic icon · a file-based preview path | Generic icon in v2. Any file-based path needs its own secure design (e.g. a sandboxed, memory-backed or encrypted-at-rest scratch area with proven cleanup). It must not weaken invariant 1. |

