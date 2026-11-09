# Muninn v2 — Decisions

Companion to `docs/designs/muninn-v2.md` and `docs/proofs.md`. Each decision records the **alternatives considered and why they were rejected**. IDs are never reused. A reversed decision is marked **Revised** with its date; it's never deleted.

**Statuses:** **Accepted** · **Revised** · **Pending proof** (accepted as a hypothesis; nothing depending on it is built until the proof passes) · **Open** (needs the maintainer's input) · **Deferred** (not in v2)

## Waiting on proofs

| Decision | Hypothesis | Proof |
|---|---|---|
| D2 | SQLCipher's official Swift package gives encryption and FTS5 (with `trigram`) in our build | PROOF-004 |
| D3 | A private data-protection keychain group works for a Developer ID helper | PROOF-003 |
| D15 | Chunked assets inside SQLCipher hold up at realistic sizes | PROOF-005 |
| D16, D35 | One trigram index (or two, if needed) meets relevance and size targets | PROOF-004 |
| D17 | A sandboxed on-demand XPC worker isolates crashes, returns memory, and can parse HTML without WebKit trouble | PROOF-013 |
| D21 | XPC meets every transport requirement in §4.6 | PROOF-002 |
| D23 | Which process reads the pasteboard | PROOF-001 |
| D38 | `SMAppService.agent` can host the helper in the layout the Keychain and worker require | PROOF-001, PROOF-003 |

## Register

| # | Decision | Status | Chosen | Alternatives → why rejected |
|---|---|---|---|---|
| D1 | Product scope beyond platform work | **Open** | — | Candidates: snippets, collections, retention, `transform` (D11), agent/MCP access (D27), per-app exclude list. Needs input. |
| D2 | Encryption at rest | **Pending proof** (PROOF-004) | SQLCipher via its official Swift package (pinned; Community Edition, BSD-style). Muninn's first external dependency, accepted deliberately. CI verifies against the exact packaged binary: `SQLITE_HAS_CODEC` set, `cipher_version` non-empty, file header isn't `SQLite format 3`, opening without the key fails, FTS5 + `trigram` work. | **CryptoKit per column/blob over plain SQLite** → FTS5 indexes and the WAL would hold plaintext, or search breaks. **SQLite SEE** → commercial licence. **FileVault only** → doesn't protect against other local processes or copied backups. **Vendored amalgamation** (earlier choice) → more build work than the official package for no security gain. |
| D3 | Who holds the DB key | **Accepted** (packaging: PROOF-003) | Helper only; UI and CLI go through IPC | Shared access group with the app → widens who can read the key for no need. |
| D4 | Store original payloads | **Revised 2026-11-09** | Keep every compatible representation (§4.3), stored as chunks **inside** SQLCipher (D15). Files are references; a snapshot is explicit. | Text-only (v1) → loses screenshots and rich text (§1.1). External encrypted files → see D15. |
| D5 | Minimum macOS | **Revised 2026-11-09** | **macOS 27**: the version every proof runs on. Widen later only with a test environment for the older version. | 15 (earlier) → `accessBehavior` didn't exist before 15.4, so capture couldn't be specified. 15.4 / 26 → no machine to prove them on. |
| D6 | Pasteboard change detection | **Accepted** | Fixed-interval polling of `changeCount`; gaps counted as `missedChanges`. | No public change notification exists. Adaptive polling → deferred until `missedChanges` data (PROOF-008) shows a need (review R-C5). |
| D7 | Excluding sensitive content | **Accepted** | Skip `org.nspasteboard.ConcealedType` / `TransientType` with no trace. | Heuristic secret detection → see D12. |
| D8 | Auto-update | **Accepted** | None in v2 | Sparkle → a dependency for a single-user tool. |
| D9 | Signing identity | **Open** | — | Personal vs. organization Team ID. Blocks gate A. |
| D10 | Simulated ⌘V from the panel | **Deferred** | — | Needs Accessibility permission; `paste` prints to stdout instead. |
| D11 | `muninn transform` | **Deferred 2026-11-09** | Not in v2; part of D1 | Keep in v2 → a product feature outside v2's scope that duplicates `jq`/`base64`/`tr` on `paste` output, and adds public CLI contract (review R-Z4). |
| D12 | What counts as protected | **Open** | Leaning: user-marked + protected-apps list | Secret detection → false negatives would give a false sense of safety. |
| D13 | Lock protected items in the UI | **Open** | Leaning: Touch ID to reveal, a setting, default off | Always visible → weaker for shared screens. |
| D14 | Extract text from referenced files (no snapshot) | **Open** | Leaning: opt-in | It's a partial copy of the file, so the same explicit-capability rule as snapshots applies. |
| D15 | Asset storage | **Pending proof** (PROOF-005) | Chunks inside SQLCipher (`asset_chunks`), incremental BLOB I/O, incremental auto-vacuum. `assets.storage` reserves `external`. | External encrypted files from day one → a second crash-consistency domain and a custom file format (review Z2/C1). Shard DBs via `ATTACH` → not atomic across files in WAL mode; considered only if PROOF-005 shows single-file cost is unacceptable **and** Time Machine exclusion (D34) doesn't solve it (review R-C2). |
| D16 | Trigram index size on huge items | **Pending proof** (PROOF-004) | Decide from measured sizes; any cap is documented and reported per item. | Index everything blindly → unknown cost. |
| D17 | Where parsers run | **Pending proof** (PROOF-013) | Sandboxed on-demand XPC worker for `text`, `ocr`, `pdf`, `preview`; the helper runs only the index step and applies outputs. | In the helper → heavy frameworks stay resident, and a parser exploit runs next to the key. One process per job → startup cost per copy. |
| D18 | Storage growth | **Revised** | History is permanent; limits at capture, pruning of regenerable data, warnings and user-driven cleanup. | Automatic eviction of old binaries → "history" would silently lose originals. |
| D19 | Moving history to a new Mac | **Deferred** | Not in v2; the device-only key consequence is documented. | Encrypted export/import → later. |
| D20 | Limit values | **Revised 2026-11-09** | Only in `MuninnLimits`; the design states what's limited and what happens. | Numbers in the design → two sources of truth. |
| D21 | Transport | **Revised 2026-11-09 · pending proof** (PROOF-002) | **XPC Mach service by default**, with `xpc_connection_set_peer_code_signing_requirement`. A Unix socket only if PROOF-002 finds a requirement XPC can't meet. | Custom socket protocol → rebuilds identity checks, framing, concurrency and liveness by hand. Readability isn't a reason: `muninn debug send` provides it over any transport (review R-Z2, R-C6). launchd `Sockets` → needs a per-user absolute path a bundle plist can't hold. |
| D22 | Secure Enclave key wrapping | **Deferred** | — | Adopt only if a spike (PROOF-017) shows a real benefit and reliable unattended unlock. |
| D23 | Which process reads the pasteboard | **Pending proof** (PROOF-001) | Leaning: the helper, if it's attributed to "Muninn"; otherwise the app, over a one-way streamed capture channel (§4.16). | — |
| D24 | Who draws the scratched raven | **Open** | — | Illustrator vs. in-house. Brief: `docs/brand.md`. |
| D25 | Stricter lock: user presence to reopen | **Deferred** | — | Wiping keys on lock without it protects only against an out-of-scope threat (review R-Z3); with it, a Touch ID prompt after every unlock. Revisit with D22. |
| D26 | Previews beyond ImageIO/PDFKit | **Accepted** | Generic icon | A file-based preview path → would write decrypted content to disk (invariant 1). |
| D27 | Automation access to history | **Deferred 2026-11-09** | None in v2; callers without a terminal are refused. | App-created automation grants → a non-interactive credential whose only consumers (scripts, agents) aren't in v2 scope; designing it now would fix a security model before D1 says agent access is wanted. |
| D28 | Annotation processors (type, language, URLs, image metadata) | **Deferred** | Add when a feature needs them | Ship in v2 → no consumer. |
| D29 | Key rotation | **Deferred** | Not in v2 | The key is device-only; a compromise implies an out-of-scope threat. `sqlcipher_export` can rekey if ever needed. |
| D30 | When plain text is indexed | **Accepted 2026-11-09** | Right after commit, in the helper | Inside the capture transaction → puts work on the capture path for a gain of milliseconds (review R-C7). PROOF-008 reports capture-to-searchable time. |
| D31 | Production self-monitoring | **Revised 2026-11-09** | Current memory in `status`/`doctor` | Ring buffer, trends, MetricKit → no field problem needs them; soak and `leaks` cover memory. |
| D32 | Rewrite vs. evolve v1 | **Accepted** | Rewrite (keeping the modules listed in §2) | Evolve v1: encrypt the store in place and add FTS → v1's one-string-per-copy model can't hold representations, and the plaintext store, unauthenticated IPC and process-spawned helper all need replacing anyway (§1.1). Migration carries the history over (§5). |
| D33 | Who verifies user presence for a session | **Open** | Leaning: the helper accepts the signed app's word in v2 | The helper verifies the LocalAuthentication result itself (e.g. an externalized LA context) → stronger, but only if PROOF-002 shows it's cheap. |
| D34 | Exclude the DB from Time Machine | **Open** (PROOF-005) | — | Keep backed up → restores work on the same Mac; cost grows with one large changing file. Exclude → no hourly re-copy; a lost disk means lost history. |
| D35 | Search index shape | **Pending proof** (PROOF-004) | Baseline: one `trigram` index plus a short-term fallback | Two indexes with rank fusion → adopt only if the baseline fails specific relevance cases (review R-Z6). In-memory n-gram index → breaks invariant 9. SearchKit → no control over ranking, filters or encryption. |
| D36 | CLI access model | **Accepted** | Sessions approved with Touch ID in the app; scopes `metadata`, `read`, `manage`; protected items per request; no-terminal callers refused | No CLI history access → loses the terminal workflow. App-only workflow → same. Touch ID per command → unusable for search loops. Unrestricted (v1) → any local process reads all history. |
| D37 | Saved vs. pinned | **Accepted 2026-11-09** | Pinned only (`content_items.is_pinned`) | Separate "saved" state with labels → no command or feature uses it (review R-Z10). |
| D38 | How the helper is hosted | **Pending proof** (PROOF-001, PROOF-003) | `SMAppService.agent` from the app bundle | Login-item helper app → may be required if the Keychain entitlement needs a bundle (PROOF-003). Child process of the app (v1) → dies with the app; no launchd supervision. |
| D39 | Protected items in CLI results | **Accepted 2026-11-09** | Excluded for every scope; read only per request | Redacted rows → reveal that protected items exist, when, and from which app (review S7-16). |
