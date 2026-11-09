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

---

# Re-audit (Stage 5, round 2)

## Scope and inputs

- **Target:** the revised `docs/designs/muninn-v2.md` (1,128 lines), working copy as of 2026-11-09, after the maintainer's round-1 changes. Round 1 reviewed the doc as committed in `272b082` on `v2/design`.
- **Reviewers:** a fresh `egm-zoom-out` and a fresh `egm-inventive-catalyst`. Neither saw the round-1 findings or anything under `docs/reviews/`.
- **Context:** `docs/decisions.md` and `docs/proofs.md` only. They did not receive `docs/brand.md`.
- **Isolation:** same as round 1. The zoom-out reviewer checked §2 against the v1 code and confirmed: `MuninnPaths.pasteboardMarkerType`, the `nonisolated(unsafe)` global in `HotKeyManager`, `HelperManager`, and the socket `unlink` in `IPCServer.swift`.
- **Cap:** this is Stage 5's one allowed re-audit. Any further findings become accepted trade-offs unless the maintainer acts on them.

**Verdicts:**
- **Zoom-out:** Revise. No Blockers, 7 Major and 5 Nits.
- **Catalyst:** the foundation holds up. No Blockers, 5 Major and 2 Nits.

**"Returning"** marks a finding that reopens something the maintainer already classified in round 1. The maintainer's earlier decision stands unless they revisit it.

| ID | Returning? | Related round-1 decision |
|---|---|---|
| R-Z1 | partly | Z1 (Valid): gate C/D cut. The reviewer says §4.6, §4.9 and §4.16 still have more detail than their gate allows. |
| R-Z2, R-C6 | yes | Z3 (Needs proof): PROOF-002 compares socket and XPC. |
| R-Z3 | yes | C6 (Valid): key wiping kept as defense in depth. |
| R-Z5 | yes | Z6/C5 (Valid): the maintainer chose "as of" keyset paging for `list`. |
| R-Z7 | yes | Z4 (override): the `metadata` scope is kept. |
| R-C1 | related | C6 / D25: a different route to a meaningful lock. |
| R-C2 | related | Z2/C1 (Valid): inline only; a new middle option. |
| All others | new | |

---

## Zoom-out reviewer (round 2)

### 🟡 R-Z1. Text for later gates still has more detail than the "detail follows the gate" rule allows (§7 lines 1104–1105, against §4.6 458–474, §4.9 700–712, §4.14 905–952, §4.16 968–1011) *(partly returning: Z1)*
- **What's wrong:** the doc still fully specifies these, even though each depends on a proof or belongs to gate C/D:
  - the socket wire protocol (depends on PROOF-002)
  - the 4-step onboarding state machine (depends on PROOF-001)
  - the "app becomes the reader" constraint list
  - two-mode flood handling (gate D)
  - specific abuse fixtures (2 GB text, 50k×50k PNG, 20k-page PDF, 100k files)
- **Why it matters:** proofs.md rule 6 makes any proof failure a large rewrite of the doc.
- **Suggestion:**
  - Reduce these sections to intent, constraint and deciding proof.
  - Move the fixtures to PROOF-015.
  - Move frame details to a future IPC spec once D21 is decided.

### 🟡 R-Z2. The doc hand-builds a socket protocol when XPC already provides most of it (§4.6 lines 444–474; §4.11 IPC table 811–826; §4.16 line 1028) *(returning: Z3)*
- **What's wrong:** §4.6 now lists what the socket rebuilds, so the remaining distinct benefits are readability and a single wire format. Readability already needs `muninn debug send` for release builds. Meanwhile §4.16 marks launchd `Sockets` as "adopt", which assumes the socket wins before PROOF-002 decides.
- **Suggestion:**
  - Make XPC the default, and treat the socket as the alternative PROOF-002 must justify.
  - Change the `Sockets` row to "proof (D21)".
  - Drop `debug send` if XPC wins.

### 🟡 R-Z3. The lock teardown is kept even though the doc says it protects against no in-scope threat (§4.4 lines 406–423, step 5 at 421; §1.1 line 74; PROOF-003 step 6) *(returning: C6)*
- **What's wrong:** on every lock, step 5 closes connections, zeroizes keys, enables SQLCipher memory security, drops caches, and reopens everything on unlock. The doc itself says this only helps against an out-of-scope threat.
- **Why it matters:** the reopen path on unlock can race with in-flight jobs, the capture queue and the reader pool.
- **Suggestion:**
  - Keep steps 1–4.
  - Move step 5 to D25.
  - Drop PROOF-003 step 6.

### 🟡 R-Z4. `transform` is a product feature, not platform work (§4.11 line 731, row 785; §4.1 line 201 `MuninnTransform`; line 807; D11; line 620) *(new)*
- **What's wrong:** D1 says product features beyond the platform are not yet scoped. Even so, v2 adds:
  - a module
  - a command with 10 formats
  - `--copy` capture semantics
  - a scope row

  No v2 goal mentions it, and the doc's reason ("the panel can reuse it later") is speculative.
- **Why it matters:** it adds public surface under a contract where any change is a breaking change. It also duplicates `jq`, `base64` and `tr` on the output of `muninn paste`.
- **Suggestion:** remove `transform` and `MuninnTransform` from v2, and fold the idea into D1.

### 🟡 R-Z5. "As of" cursor paging for `list` brings its own index and proof for a need no one has named (§4.7 lines 523–536; PROOF-007; §4.11 line 724) *(returning: Z6/C5)*
- **What's wrong:** `search` drops cursors until "real use shows a need", but `list` keeps:
  - cursors
  - a composite index
  - an `invalid_cursor` error
  - half of PROOF-007

  No consumer is named: the panel uses subscriptions, `--all` covers scripts, and scripts have no access in v2 anyway (D27).
- **Suggestion:** use `--limit` plus a streamed `--all` for `list` too, and drop `--cursor`, `nextCursor` and the cursor half of PROOF-007.

### 🟡 R-Z6. Two FTS indexes, a heuristic query planner and rank fusion are built before any evidence that one index isn't enough (§4.7 lines 480–499, 515–521) *(new)*
- **What's wrong:**
  - The design maintains `unicode61` and `trigram` indexes, with planner rules (non-word characters, camelCase/snake_case, "fewer than one page") and reciprocal-rank fusion.
  - Trigram index size is already a worry (D16).
  - The simpler baseline is never tested: trigram only with `remove_diacritics`, plus a `LIKE`/prefix fallback for terms under 3 characters.
- **Suggestion:**
  - Add a trigram-only baseline to PROOF-004.
  - Adopt two indexes plus fusion only if the baseline fails specific relevance cases.
  - Replace the planner rules with a sentence of intent.

### 🟡 R-Z7. The access-policy surface is larger than an interactive-only v2 needs (§4.12 lines 838–862; §1.1 line 72; D27) *(returning: Z4 override)*
- **What's wrong:** with automation deferred, every v2 CLI caller is a person at a terminal who has already passed Touch ID. The doc still has:
  - five scope tiers
  - per-scope default and ceiling lifetimes
  - `metadata`'s special rule (filter-only searches allowed, text queries refused)
  - `status --audit` gated on `metadata`

  No v2 consumer of `metadata` is named.
- **Suggestion:** write down the one v2 user story that `metadata` serves. If there isn't one, collapse to `read` (which includes `manage`) plus per-request `protected`.

### 🟢 R-Z8. The TIFF pixel-match dedupe rule contradicts the memory and read rules (§4.3 line 334 vs. §4.13 line 899, §4.14 line 929) *(new)*
A pixel compare needs both images fully decoded in the helper, which line 899 forbids, and line 929 says TIFF isn't read at all when a compact format exists. Delete the pixel-compare rule.

### 🟢 R-Z9. The content hash covers every representation, so "the same thing" may not dedupe (§4.3 line 326 vs. line 383) *(new)*
The same text copied from a browser (plain plus HTML) and from a terminal (plain only) becomes two items. Say whether that is intended. If not, define identity by the primary representation.

### 🟢 R-Z10. Placeholders with no v2 consumer (lines 635, 305, 1125) *(new)*
- Tier 2 "light text work" is "none in v2": drop the row.
- `saved_items.label` and the saved-vs-pinned split have no command that uses them: reduce to the pin, or fold `is_pinned` into `content_items`.
- The glossary still defines "Automation grant": remove it, or point it to D27 only.

### 🟢 R-Z11. `MuninnCore` is described as "no I/O", but pasteboard writing needs a home (§4.1 line 193; §4.8 lines 618–620) *(new)*
v1's `packages/MuninnCore/Sources/ClipboardWriter.swift` writes to `NSPasteboard` from `MuninnCore`, and v1's marker is empty `Data`, while v2's marker carries the item id. Name the module that owns pasteboard writes (probably `MuninnCapture`), and list `ClipboardWriter` as reused and moved.

### 🟢 R-Z12. A malformed MetricKit row in §4.16 (line 1040) *(new)*
The row has 5 cells in a 4-column table. The extra cell ("Feeds `doctor`…") is left over from before D31 was revised and contradicts "not in v2".

---

## Inventive catalyst reviewer (round 2)

### 🟡 R-C1. The key stays readable while the Mac is locked, but nothing needs it then (§1.1 line 74; §4.4 lines 389, 404–424; D25) *(related: C6)*
- **False compromise:** the doc picks `AfterFirstUnlockThisDeviceOnly` so the helper can run in the background. But while the Mac is locked, the design already pauses capture, stops jobs and serves no data. And because the helper starts at login, it always starts while the Mac is unlocked.
- **Transform (Blessing in Disguise):** extend PROOF-003 step 3 to test `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` in the data-protection keychain. Does it actually become unreadable when the screen locks, on both Apple silicon and Intel? If it does, the OS enforces "no data while locked", and the policy gate becomes the defense in depth. That needs no D25 prompt.
- **Side costs:**
  - The design must tell `errSecInteractionNotAllowed` apart from `errSecItemNotFound`. Otherwise a crash restart while locked would trigger the orphan path and move the DB aside (lines 398–402). This needs its own test.
  - The helper gains a "wait for unlock" state at startup.
  - The behavior may vary across hardware and OS versions.
  - If macOS doesn't honor the class on screen lock, the current design stands.

### 🟡 R-C2. The asset store choice is framed as only two options: "one big file" or "an external envelope store" (§4.3 lines 345–361; §4.16 line 1044; D15; PROOF-005) *(related: Z2/C1)*
- **False compromise:** each capture changes the DB, and binaries are kept permanently (D18). So Time Machine re-copies a file of many GB every hour, and pre-migration and orphan copies duplicate the same large file.
- **Transform (Segmentation):** a middle option. Store assets in additional SQLCipher shard files, opened with `ATTACH` under the same key:
  - The main DB holds metadata, text and FTS, plus a "hot" shard that receives new assets.
  - Shards are sealed by size or period.
  - Backup and vacuum then work shard by shard.
  - `assets.storage` gains a shard id.

  PROOF-005 would measure this option alongside the other two.
- **Side costs:**
  - Commits that span attached DBs are **not atomic** in WAL mode. Writes need an order (chunks first, then the reference) plus a startup sweep, which brings back a small part of the reconciliation that inline storage avoided.
  - More files and connections.
  - A delete re-dirties a sealed shard.

### 🟡 R-C3. "No single copy can exhaust memory" doesn't match "peak memory follows the payload" (invariants 9–10, lines 93–94; §4.8 625–628; §4.13 891; §4.14 917, 928–930; line 702) *(new)*
- **False compromise:** macOS doesn't expose a representation's size until it is read. So the per-representation size limit is checked only after a 2 GB copy is already in the always-running helper. Invariant 10 is stated without that caveat.
- **Transform (Extraction):**
  - Read large or non-text representations in a short-lived process.
  - Cheap size checks (`types`, file-URL `stat`, `detectMetadata`) still run first, in the helper.
  - This depends on whether that process can read the pasteboard under the existing grant. Add that question to PROOF-001 step 4.
  - If it can't, restate invariant 10 honestly: the bound holds after the read. Then record the measured peak in PROOF-008 or PROOF-015.
- **Side costs:**
  - Extra latency for large captures, against the ~100 ms screenshot target.
  - A possible second permission identity to onboard.
  - Another IPC channel to authenticate.

### 🟡 R-C4. Invariant 5 promises complete deletion, but the storage engine keeps traces (line 89; §4.3 365–369; line 353; line 378; line 400; §4.7) *(new)*
- **False compromise:** after the delete commits, deleted content still exists as ciphertext in:
  - freed pages (when `secure_delete` is off)
  - the WAL until a checkpoint
  - old FTS5 segments until a merge
  - the `pre-<version>` and `orphaned-<date>` DB copies

  The at-rest threat model still holds, but "deletion is complete" claims more than that.
- **Transform (Beforehand Cushioning):**
  - Turn on `PRAGMA secure_delete` (or `FAST`).
  - Run a `TRUNCATE` checkpoint after user deletes.
  - Schedule an FTS5 `merge`/`optimize` through the existing background scheduler.
  - Cover the DB copies in the user-facing deletion story.
  - Restate invariant 5 as: unreachable at commit, physically purged within a stated bound.
- **Side costs:** write and battery cost from `secure_delete`, the CPU cost of merges, a latency spike at checkpoint, and a weaker "eventual" wording.

### 🟡 R-C5. Fixed polling treats missed clipboard changes as an unavoidable loss, when the interval could adapt (goal 2 line 32; §4.8 604–614; §2 line 101; D6) *(new)*
- **False compromise:** polling itself is a platform limit, but the interval isn't. §4.8 never states the interval, and D6 only says "revisit". Checking `changeCount` is cheap and reads no content.
- **Transform (Dynamics):**
  - Poll tightly (50–100 ms) for a short window after a change, a hotkey, or a change of frontmost app.
  - Relax when idle, in Low Power Mode, or under thermal pressure.
  - Use `missedChanges` as the feedback signal.
  - Let the flood limiter override tight polling.
  - PROOF-008 compares fixed and adaptive intervals.
- **Side costs:** capture tests need fake clocks, and there are more wake-ups while the user is actively copying.

### 🟢 R-C6. Inspectability is counted as a reason for the socket, but it belongs to `debug send` (§4.6 lines 448–456, 474; D21; PROOF-002) *(returning: Z3)*
`debug send` could encode and decode JSON over XPC just as well. Drop inspectability from the PROOF-002 comparison, and specify `debug send` as JSON on stdio whatever the transport. Side cost: dev builds lose `socat` as a way in.

### 🟢 R-C7. D30 sets up a trade-off between capture latency and searchability that probably doesn't exist (§4.8 line 638; D30; PROOF-008) *(new)*
- The after-commit `index` step runs right after commit, in the same process. Against the < 1 s target, that gap is almost certainly milliseconds.
- **Suggestion:** fix "after commit" as the design, and have PROOF-008 report only the measured capture-to-searchable time. If that ever misses, a fallback is a direct scan of items whose `index` step is still pending. That scan must respect invariant 7: same results whichever path serves them.

### Checked and not a false compromise
- Inheriting the terminal session (the `sudo`-like trade-off).
- Polling as such (D6).
- The backpressure memory bound.
- Flood handling that depends on attribution confidence.
- The three-tier processing split.
- Shipping v2 without automation access (D27).

---

## Maintainer classification (round 2)

Classified 2026-11-09. Maintainer decisions: alternatives live in `decisions.md`; the `metadata` scope is kept, with a user story; `transform` is deferred to D1; the minimum is macOS 27. The other classifications follow Stage 8's sorting, and the resolution rule was that a design-doc change must remove at least as much text as it adds, unless it fixes a contradiction or an invariant. The design went from 1,128 to about 877 lines.

| ID | Class | Resolution |
|---|---|---|
| R-Z1 | Valid | Wire-protocol detail removed from §4.6 (now intent plus requirements); abuse fixtures moved to PROOF-015; the app-as-reader fallback cut to a few lines in §4.16. The onboarding flow stays, because it's a gate A deliverable. |
| R-Z2 | Valid | XPC is the default; a socket must earn its place in PROOF-002 (D21). |
| R-Z3 | Valid | Lock teardown (close DB, wipe keys) removed from v2; it's covered by D25. |
| R-Z4 | Valid (maintainer) | `transform` deferred to D1 (D11). |
| R-Z5 | Valid | `list` cursors removed; `--limit` plus streamed `--all`. |
| R-Z6 | Valid | A trigram-only baseline comes first in PROOF-004; two indexes only if it fails (D35). |
| R-Z7 | Disputed (maintainer) | `metadata` kept; the user story is written in §4.12. |
| R-Z8 | Valid | Pixel-compare rule removed; type-based rule instead. |
| R-Z9 | Valid | Text identity is the plain text; representations are append-only (§4.3). |
| R-Z10 | Valid | Tier-2 row removed; "saved" dropped in favor of pinned only (D37); automation-grant glossary entry removed. |
| R-Z11 | Valid | `ClipboardWriter` and the marker move to `MuninnCapture`; listed as reused. |
| R-Z12 | Valid | MetricKit row removed. |
| R-C1 | Needs proof | PROOF-003 tests `WhenUnlocked`, including the locked-restart vs. missing-key distinction. |
| R-C2 | Deferred | Shards only if PROOF-005 shows the single-file cost is unacceptable **and** Time Machine exclusion (D34) doesn't fix it (D15). |
| R-C3 | Valid in part | Invariant 10 restated; the peak is measured in PROOF-001 step 7. The short-lived reader is rejected unless that measurement fails. |
| R-C4 | Valid | Invariant 5 now says unreachable at commit, purged within a bounded time; `secure_delete`, a checkpoint and index merges added; the DB copies are covered. |
| R-C5 | Deferred | Adaptive polling waits for `missedChanges` data (D6). |
| R-C6 | Valid | Inspectability comes from `muninn debug send` over any transport. |
| R-C7 | Valid | D30 closed: index right after commit. |
