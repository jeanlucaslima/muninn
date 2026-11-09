# Stage 5: Initial Zoom Out: `docs/designs/muninn-v2.md`

## Scope and inputs

- **Target:** `docs/designs/muninn-v2.md`, whole file (lines 1–1295), **Draft** status. The file is untracked in git (last commit `ab1e0b2`), so this review covers the working copy as of 2026-11-09.
- **Reviewers:** `egm-zoom-out` (simplicity and scope) and `egm-inventive-catalyst` (false compromises), run in parallel.
- **Standard:** `zoom-out-standard.md`.
- **Reviewers received:** the target, plus `docs/decisions.md` and `docs/proofs.md` as baseline context.
- **Reviewers did not receive:** the design conversation, `AGENTS.md`/`CLAUDE.md` (the adapters set `omitClaudeMd`), or memory.
- **Isolation:** each reviewer was a fresh subagent with no parent history. The zoom-out reviewer also read v1 source files on its own to check §2 claims. It confirmed: `NSLock`, `Thread.detachNewThread`, `LIKE` search, `Process()`, and `SMAppService.mainApp` only.

**Verdicts:** both reviewers recommend **Revise**. Neither found a Blocker, and both passed the context check: the goal and its rationale are clear.

## Overlap between the two reviewers

| Topic | Zoom-out | Catalyst | Notes |
|---|---|---|---|
| External asset store and chunked AEAD before PROOF-005 | Z2 | C1 | Both say: go inline-only first and keep the external store as a contingency. C1 adds an `asset_chunks` table and envelope encryption if the external store survives. |
| Pagination snapshots | Z6 | C5 | Z6: keyset pagination for `list`, limit plus `--all` for `search`, drop the HMAC. C5: as-of keyset over append-only events. |
| Processors and the worker | Z7 | C4 | Z7: cut the annotation processors. C4: `index` can't run in a worker that has no DB or key, and §4.2 contradicts §4.8. |
| D23 fallback (the app reads the pasteboard) | Z1 (in part) | C7 | Z1: gate A outcomes would rewrite later sections. C7: specify the fallback channel now so the result doesn't reopen §4.6, §4.12 and §4.13. |

---

## Zoom-out reviewer

### 🟡 Z1. Later gates are designed in detail before the gate A proofs that could invalidate them (§4.3–§4.17, §7; lines 246–1232, 1260–1277)
- **What's wrong:** §7 says work inside a gate is limited to what that gate's proofs have justified (line 1262). Yet the doc already fixes these in detail:
  - the chunked-AEAD file format
  - tombstones and key rotation
  - XPC worker limits
  - per-processor eligibility tables
  - menu bar raven poses and the colour palette

  Several open items could rewrite large parts of this:
  - **D23** (whether the helper or the app reads the pasteboard) changes §4.13, §4.8, and the app's memory budget.
  - **PROOF-003** (helper as a bare executable or a bundle) changes §4.1, §4.4 and §4.5.
  - **D15** asks whether an external asset store is worth having at all.
  - **D1** (product scope) is still open (line 47).
- **Why it matters:** each gate A result forces edits across hundreds of lines, and reviews spend effort on gate D detail that may never ship in this form.
- **Suggestion:** keep §1–§3, the §4 overview, the invariants, and the gate A/B architecture at interface level. Cut gate C and D sections (§4.13 budgets and soak, §4.14 tables, §4.17) to intent plus the proof that will decide them. Expand each when its gate starts, as `proofs.md` line 175 already does for PROOF-005 to PROOF-017.

### 🟡 Z2. External asset store, chunked AEAD, crash protocol and key rotation are designed before they're shown to be needed (§4.3, lines 320–369)
- **What's wrong:** about 50 lines specify:
  - a STREAM-style file format
  - a write, verify and publish protocol
  - tombstones and reconciliation
  - HMAC file names
  - versioned keys and resumable re-encryption

  But D15 says the external store is unproven, and line 323 says both modes are supported "from day one".
- **Why it matters:** inline BLOBs in SQLCipher already give:
  - encryption and page authentication
  - atomic commit and atomic delete
  - bounded-memory streaming (incremental BLOB I/O)
  - rekeying (`sqlcipher_export`)

  The external path adds a second crash-consistency domain plus its own fault-injection suite (line 699).
- **Suggestion:** ship inline-only. Keep the `assets.storage` column so external storage can be added later without a schema change. Specify the external store only if PROOF-005 fails. Remove manual key rotation from v2: the key is device-only, so a suspected compromise of it implies a threat §1.1 already puts out of scope.

### 🟡 Z3. The custom socket protocol rebuilds what XPC already provides (§4.6, lines 452–468; §4.14 IPC table, lines 1053–1066; D21)
- **What's wrong:** protocol v2 adds:
  - a handshake
  - `requestId` multiplexing, cancellation and `supersedes`
  - binary bodies
  - event subscriptions
  - keepalive, partial-frame timeouts and quotas

  It also checks code identity by hand from the audit token. A launchd `MachServices` XPC endpoint with `xpc_connection_set_peer_code_signing_requirement` already provides most of this, and the design already uses XPC for the worker.
- **Why it matters:** this is a lot of framing and lifecycle code that security depends on. D21's reasons for the socket are weak against that cost: "one transport" is equally true of XPC, and "inspectable with socat" works only in dev builds.
- **Suggestion:** have PROOF-002 also compare the implementation cost of the two options. If the socket stays, list which XPC features are being rebuilt and why. Consider passing a file descriptor (`SCM_RIGHTS`) instead of binary-body framing.

### 🟡 Z4. The access policy has more parts than the current scope needs (§4.12, lines 826–868; invariant 3, line 81)
- **What's wrong:** the policy defines:
  - five scopes, including `metadata`
  - default and ceiling durations for each scope
  - terminal binding through the kernel audit session
  - automation grants with an optional parent-executable restriction
  - a needs-attention raven while a grant is active

  Agent and automation access is still an open question (D1).
- **Why it matters:** every scope × command pair needs its own test (line 676). The README promises "No manual setup required", but under this design no CLI read works without Touch ID, and the doc doesn't call that out as a product change.
- **Suggestion:** for v2, ship `read`, `protected` and `manage` sessions bound to the terminal. Defer automation grants, the `metadata` scope and the `grants` table until D1 decides agent access. State the UX change in §1.

### 🟡 Z5. Gate B promises sessions, but the approval prompt only exists from gate C (§7, lines 1268–1269; §4.12, lines 842–846)
- **What's wrong:**
  - Gate B requires "sessions and access policy" with no polished UI.
  - Sessions are approved only through a prompt shown by the app, and "app unreachable → exit 6, never a fallback".
  - The app arrives in gate C.
- **Also:** line 1273 says the §4.1 restructure happens in gate C, but gate B already builds `MuninnSearch` and `MuninnSecurity`, and v1 already has the `packages/` and `apps/` layout. What actually moves in gate C is unclear.
- **Suggestion:** do one of these:
  - bring a minimal approval surface into gate B;
  - restate gate B as "policy enforced, approval via the scripted approver (L1 only)".

  Also spell out exactly what the gate C restructure changes.

### 🟡 Z6. Search pagination snapshots are heavy machinery for a top-N type-ahead (§4.7, lines 517–532)
- **What's wrong:** pagination uses:
  - snapshots for each connection, with 4 per connection and 32 in total
  - LRU eviction plus an idle TTL
  - HMAC-signed cursors
  - `skippedDeleted` and `snapshotCapped` fields
  - a separate `--all` path

  The HMAC is redundant if snapshots are already scoped to one connection.
- **Why it matters:** the panel shows a top-N list that is replaced on every keystroke, and the CLI shows 20 results by default. Holding stable order across many pages is a niche need, yet it adds the `cursor_expired` error for clients to handle and its own proof (PROOF-007).
- **Suggestion:** use keyset pagination on `(last_captured_at, id)` for `list`, and limit plus `--all` for `search`. Add snapshots only if real use shows the need. At minimum, drop the HMAC.

### 🟡 Z7. More processors and production self-monitoring than any stated feature uses (§4.8, lines 626–636; §4.13, lines 951–961)
- **What's wrong:**
  - The `type`, `language`, `urls` and `image` annotations aren't read by any feature, except that `language` picks the OCR language (which user settings already cover). `type` repeats what capture already records.
  - Job dependencies mostly exist to run `index` after these.
  - The `phys_footprint` ring buffer, trend detection and MetricKit in production duplicate the soak benchmark and the `leaks` CI check.
- **Suggestion:** start with `text`, `ocr`, `pdf`, `preview` and `index`, and add annotation processors when a feature needs them. Drop the in-production monitoring, and the MetricKit half of PROOF-016, until there is a field problem to diagnose.

### 🟡 Z8. Too much low-level detail, and limits with two sources of truth (lines 427–429, 917–918, 991–1005, 1036–1066, 1180–1232)
- **What's wrong:**
  - The doc specifies `memset_s`, `cache_size = -2048`, token-bucket rates, the 64 KB chunk size, timeouts, ping intervals, raven poses and the palette.
  - Line 968 makes `MuninnLimits` the source of truth, yet the doc hard-codes the same numbers.
  - D20 expects these numbers to be tuned.
- **Why it matters:** the numbers will drift, and every tuning change becomes a design-doc commit (line 1295).
- **Suggestion:** for §4.13 and §4.14, state what is limited, where it is enforced, and what happens past the limit, and point to `MuninnLimits` for the values. Move §4.17 to a brand brief (D24 already treats it as a separate track).

### 🟢 Z9. The glossary definition of "Grant" contradicts §4.12 (line 1292 vs. lines 864, 872)
The glossary says grants allow "non-interactive **protected** reads", but §4.12 says grants can never have the `protected` scope.

### 🟢 Z10. Repeat coalescing conflicts with the capture guarantees (line 995 vs. line 604 and invariant 5, line 301)
Coalesced repeats write no event, yet the doc promises that every observed change is persisted or counted as skipped, and that "History keeps every copy". Name a counter for coalesced repeats or soften the guarantee.

### 🟢 Z11. Muninn could capture its own `copy` (§4.11, lines 771, 773)
The doc doesn't say how the monitor avoids recording Muninn's own write, which would create two events. The same applies to `transform --copy`, which runs in the CLI.

### 🟢 Z12. "Delta from v1" understates what v1 already has (§3, line 120; §4.1)
v1 already has the `packages/` and `apps/` split, the Carbon hotkey (`HotKeyManager.swift`), `Paths`, and the CLI process test harness (`CLITests.swift`). Say what is reused rather than rewritten.

---

## Inventive catalyst reviewer

The reviewer treated platform limits as constraints, not as contradictions to solve: macOS has no clipboard-change notification (D6), and pasteboard data is opaque until read (line 1008).

### 🟡 C1. Building two asset stores "from day one" pulls in a homemade crypto format and a crash protocol that spans the DB and files (§4.3, lines 320–369; §4.4 line 401; D15)
- **False compromise:** the design assumes large binaries must live outside the DB. That forces:
  - a custom chunked-AEAD format
  - HMAC names
  - a 4-step publish protocol
  - tombstones and daily reconciliation
  - the `assetMissing` state
  - re-encrypting every file during key rotation
- **Transform (Segmentation, plus Preliminary Action):**
  - By default, store large binaries as chunked inline BLOBs: an `asset_chunks(asset_id, idx, data)` table with 64 KB–1 MB rows, written with incremental BLOB I/O, and `auto_vacuum = INCREMENTAL`.
  - SQLCipher then provides atomicity, encryption, authentication and rotation.
  - Specify the external store only if PROOF-005 fails.
  - If it survives, use envelope encryption (a random key per asset, wrapped by a key-encryption key), so rotation rewraps small keys instead of re-encrypting files.
- **Side costs:** a large DB file, which makes VACUUM, backups and Time Machine heavier; WAL bursts that need `wal_autocheckpoint` tuning; and one large file to restore if corrupted. PROOF-005 has to measure these.

### 🟡 C2. The capture backlog holds plaintext in helper memory, and one capture can exceed the queue's own limit (§4.8, lines 608–611; §4.14, lines 997–1013; §4.13 line 946)
- **False compromise:**
  - The queue is bounded at 16 captures / 200 MB, but one capture can be 100 MB by default and 1 GB at the hard ceiling. The doc doesn't say what happens when one capture is bigger than the queue.
  - Under disk contention, 200 MB of plaintext sits in the helper, which conflicts with invariant 9 (small, fixed idle footprint).
- **Transform (Preliminary Action, plus Blessing in Disguise):** stream-encrypt each representation to the existing `.partial` path as it is read, and queue handles to ciphertext. Memory is then bounded by one representation, and the backlog by disk, which the disk floor already governs. The existing reconciliation cleans up orphans.
- **Side costs:** extra I/O within the ≤ 20 ms / ≤ 100 ms budget (line 598); and if C1 removes external files, this still needs a small encrypted spill area, so **resolve C1 and C2 together**.

### 🟡 C3. Flood pausing is keyed on an unreliable source-app guess, so an attacker can turn it against a real app (§4.14, lines 991–995; line 797; line 1155)
- **False compromise:**
  - `source_app` is a "best guess" (the frontmost app), yet the token bucket, the 10-minute pause and *Always ignore* all trust it fully.
  - A background script that floods the clipboard gets blamed on Safari or Terminal.
  - The notice then invites the user to permanently ignore that innocent app.
- **Transform (Dynamics):**
  - When attribution is high-confidence (`org.nspasteboard.source`, or the user was interacting with the app that changed the clipboard), apply the per-app pause.
  - When it is low-confidence, apply a short, global, metadata-only degrade that lifts automatically.
  - Never offer *Always ignore* on a low-confidence attribution.
  - Word the notice as "something changed the clipboard 340 times while *App* was frontmost".
- **Side costs:** two limiter modes to test (PROOF-015). A global degrade thins copies from every app for its duration. `CapturePolicy` must still stay pure.

### 🟡 C4. Treating `index` and the light text jobs as worker processors ties searchability to a worker cold start (§4.8, lines 626–639, 665; §4.13, lines 896, 902–903; §4.2 line 224; §4.7 line 573)
- **Internal inconsistencies:**
  - Line 665 says all jobs run in the worker, but `index` only writes to the DB, and the worker has no DB and no key.
  - §4.2 line 224 has `ProcessingRunner` running processors in a helper `TaskGroup`, which contradicts §4.8 and §4.13.
- **False compromise:** every plain-text copy enqueues `urls` and `language`. With the worker exiting after 30 s idle, ordinary sparse copying cold-starts the worker about once per copy. The "searchable within 1 s" and "worker at 0 MB when idle" targets conflict, with no stated tie-break.
- **Transform (Segmentation):** split the pipeline into three tiers:
  1. materialization steps (index rebuild, applying outputs), run in the helper and not called processors;
  2. light text work (`urls`, `type`), allowed in the helper;
  3. heavy parsers and untrusted input, run in the worker.

  Optionally, index small plain text inside the capture transaction and keep the `index` job for rebuilds.
- **Side costs:** `NSDataDetector` runs on untrusted text in the helper. Inline indexing bends invariant 4, so restate it as "*heavy* processing". The fault-injection harness (PROOF-014) gets more complex.

### 🟢 C5. Pagination snapshots ignore what the append-only event log already provides (§4.7, lines 517–532; invariant 5)
- **Transform (Inversion):** derive "as of T" values from `capture_events`, so `list` becomes stateless keyset pagination with the cursor `(asOf, last_captured_at_asOf, id)`. Keep snapshots only for `search`.
- **Side costs:** an index on `(content_item_id, captured_at)`; two pagination mechanisms; and recency decay must be evaluated at `asOf`.

### 🟢 C6. Wiping keys on lock costs a lot and protects little under the stated threat model (§4.4, lines 411–432; §1.1 lines 68, 73)
- **The issue:** with `AfterFirstUnlock`, the helper rereads the key without the user present. The wipe therefore defends only against debugger-level reads of memory while the Mac is locked, which line 73 puts out of scope. The real guarantee is the policy gate (`locked`, and sessions and grants end).
- **Fix:** do one of these:
  - call the wipe defense in depth and treat the policy gate as the guarantee;
  - make the wipe meaningful by requiring user presence to reopen (D25).
- **Side costs:** D25 means a Touch ID prompt after every unlock or restart.

### 🟢 C7. The D23 fallback (the app reads the pasteboard) quietly changes the trust and memory model (§4.16, lines 1130–1132; §4.13 lines 897, 947; §4.12 line 837)
- **The issue:**
  - The app's 40 MB budget would hold payloads of up to 1 GB.
  - The helper would need an IPC path for incoming captures, guarded only by `client = app`.
  - An app crash would mean missed captures.
- **Transform (Extraction):** specify the fallback now as a one-way capture channel: its own frame type, accepted only from the app, streamed without buffering in the app, and never mixed with UI requests.
- **Side costs:** a second capture path to test, IPC latency inside the capture budget, and the app becoming part of capture availability.

### No false compromise found
- The approval-anchored CLI access model (§4.12).
- The "do less, never part" guardrail philosophy (§4.14).

---

## Maintainer classification

Classified 2026-11-09 by the maintainer. The elephant's proposals were reviewed; the only override was Z4's `metadata` scope, which is kept. All changes are applied together across `docs/designs/muninn-v2.md`, `docs/decisions.md`, `docs/proofs.md` and `docs/brand.md`.

**Note on scope:** the report says the target was untracked. In fact it was committed in `272b082` on `v2/design`, and the reviewed working copy matched that commit.

| ID | Class | Resolution |
|---|---|---|
| Z1 | Valid | Gate C/D sections cut to intent, constraints and the deciding proof (§4.13, §4.14); new rule in §7: "detail follows the gate". |
| Z2 | Valid | Assets stored inline only, as chunks in SQLCipher. External store, chunked-AEAD file format, publish protocol, tombstones and reconciliation removed; designed only if PROOF-005 fails (D15). Key rotation not in v2 (D29). |
| Z3 | Needs proof | PROOF-002 now compares socket vs. XPC on reliability **and implementation cost**. §4.6 lists the XPC features the socket rebuilds and why; `SCM_RIGHTS` to be evaluated (D21). |
| Z4 | Valid in part | Automation grants and the `grants` table deferred until D1 (D27). The product change is stated in §1. **Override:** the `metadata` scope is kept, per the maintainer's earlier requirement to separate metadata from content access. |
| Z5 | Valid | Gate B enforces the policy with the scripted approver (unit-level evidence); the real prompt arrives in gate C. §4.1 lists exactly what the gate C restructure changes. |
| Z6 | Valid | Result snapshots and the signed cursor removed. `list` uses stateless "as of" keyset paging; `search` is top-N plus a streamed `--all`. |
| Z7 | Valid in part | v2 processors: `text`, `ocr`, `pdf`, `preview` + the `index` step; annotation processors deferred (D28). The ring buffer, trend detection and MetricKit dropped; current memory is still shown in `status`/`doctor` (D31). |
| Z8 | Valid | Values live only in `MuninnLimits` (D20); §4.13/§4.14 state what's limited, where, and what happens. §4.17 moved to `docs/brand.md`. |
| Z9 | Valid | Glossary now defines Session and Automation grant (deferred). |
| Z10 | Valid | `coalescedRepeats` counter; guarantee reworded to "persisted, coalesced, or counted as skipped". |
| Z11 | Valid | Self-copy marker carries the item id; exactly one `muninn`-sourced event; `transform --copy` is captured as new content (§4.8). |
| Z12 | Valid | §2 lists what's reused from v1. |
| C1 | Valid | Merged with Z2: an `asset_chunks` table; envelope encryption noted for a future external store. |
| C2 | Valid (different fix) | Not the spill-to-disk idea, which would reintroduce external files. Instead, one capture in flight plus a small text-only queue; anything that doesn't fit isn't read, and is counted (§4.8). |
| C3 | Valid | Flood response depends on attribution confidence: per-app pause only when confidence is high; otherwise a global metadata-only slowdown with no *Always ignore*, and honest wording (§4.14). |
| C4 | Valid | Three tiers: `index` and applying outputs in the helper, light text work allowed in the helper, heavy parsing in the worker; plain text never touches the worker. Indexing inside the capture transaction is pending PROOF-008 (D30). |
| C5 | Valid | Merged with Z6: `list` pages "as of" a capture event id. |
| C6 | Valid | The policy gate is the guarantee while locked; key wiping is defense in depth; D25 is the path to a meaningful wipe. |
| C7 | Valid (brief) | §4.16 states the constraints for the app-as-reader fallback; it's designed in full only if PROOF-001 chooses it. |

**Next:** run `/egm:egm-review` again on the revised design. The Zoom Out stage should confirm the scope reduction; the later stages then review the slimmer doc.
