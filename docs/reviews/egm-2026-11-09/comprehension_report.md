**What this proposes**

Muninn v2 rebuilds a macOS clipboard history manager with security as the starting point.
- **Storage:** history is kept in an SQLCipher-encrypted database, including binary assets stored as chunks inside it. The key is in a data-protection Keychain access group that only the helper (`muninnd`) can read.
- **The helper:** it is the only process that opens the database. It runs as an `SMAppService.agent`, and it stops serving data and pauses capture whenever the Mac locks.
- **Data model:** each copy is an immutable capture event pointing to a deduplicated content item. The item holds several representations. Derived data (OCR, PDF text, previews, FTS indexes) can be recomputed. Heavy parsing runs in a sandboxed, on-demand XPC worker, so capture is never slowed.
- **Search:** one `SearchService` inside the helper serves both the menu bar app and the CLI. It uses two FTS5 indexes (words and trigram), structured filters and recency-weighted ranking.
- **CLI:** it has a fixed contract: JSON schemas, exit codes and no silent truncation. It reads no history without a session. The user approves the session with Touch ID in the app; it is scoped, short-lived, and bound to one terminal.
- **Delivery:** four evidence gates (A–D), each backed by numbered proofs. Assumptions stay hypotheses until their proof passes.

**How the existing system works, per this document**

v1 is pure SwiftPM: three executables, four libraries and no Xcode project.
- **Processes:** the menu bar app spawns `muninnd` as a child `Process` and restarts it when it exits.
- **Capture and storage:** the helper polls `NSPasteboard` every 0.5 s and writes to a single-table plaintext SQLite database. For non-text content it stores only kind and metadata, not the bytes.
- **Search:** an unranked `LIKE '%q%'`.
- **IPC:** the menu bar app and CLI talk to the helper over an unauthenticated Unix socket using newline-delimited JSON, one request per connection.
- **Concurrency:** async/await mixed with `NSLock`, `@unchecked Sendable`, detached threads and `DispatchQueue.main.sync`.
- **Distribution:** no signing, bundling or notarization pipeline.
- **Access:** the CLI can read all history without any setup.

---

# Stage 6: Comprehension Test: `docs/designs/muninn-v2.md`

## Scope and inputs

- **Target:** `docs/designs/muninn-v2.md` at commit `50152ac`, 1,128 lines.
- **Ranges:** FeatureRange is the whole document. There is no DetailedRange, because the doc has no implementation plan.
- **Reviewer:** `egm-comprehension`, a fresh subagent run in REVIEW mode with no document standard.
- **What it read:** the target document **alone**. It was told not to read `decisions.md`, `proofs.md`, source code or `docs/reviews/`. The test is whether the doc can be understood on its own.
- **Isolation:** no parent history. The adapter sets `omitClaudeMd`, so it inherited no `AGENTS.md` or `CLAUDE.md`.

**Overall:** every section could be paraphrased, so there are no Blockers.
- The architecture, security model and data model read coherently and are largely self-contained.
- The main gaps are:
  - three internal inconsistencies (findings 1–3);
  - the access-scope semantics (finding 5);
  - how much meaning lives only in `proofs.md` and `decisions.md` (findings 4 and 8).
- Totals: 8 Major, 6 Nit.

## Findings

### 1. 🟡 Migration cannot compute v2 content hashes for v1 non-text rows, and "content hash survives" is ambiguous
- **Where:** §5 steps 3 and 5 (lines 1071–1079), against §4.3 Deduplication (line 326).
- **Problem:**
  - v2's `content_hash` is SHA-256 over sorted `(uti, sha256(bytes))` pairs.
  - v1 non-text rows migrate with no representation, so by that formula they all hash the empty set and would merge into a single item.
  - Step 3 merges v1 rows "with the same `content_hash`", and step 5 says the "content hash" must survive. v1's hash has its own, unstated definition.
  - The reader can't tell whether `content_items.content_hash` takes v1's value, is recomputed with the v2 formula, or is something else for rows with no representation.

### 2. 🟡 The unique job key prevents re-running `index`, and it's unclear whether `index` is a job
- **Where:** §4.3 `processing_jobs` (line 306); §4.8 diagram (lines 593–597) and Idempotency (lines 668–670); §4.11 `doctor` check 7 (line 799).
- **Problem:**
  - The pipeline runs `index` after commit and "again" after each worker output is applied.
  - `processing_jobs` is unique on `(content_item_id, processor_id, processor_version)`, and enqueue uses `INSERT OR IGNORE`. So if `index` is a job, a second run for the same item and version is ignored once the first is `done`.
  - The doc mostly calls `index` a "helper step", yet `doctor` checks "the current `index` processor version" and "no `index` job pending > 1 minute".
  - The reader can't tell how `index` is scheduled, versioned or re-triggered.

### 3. 🟡 Parser isolation is described as both deferred and decided
- **Where:** §1.1 "Malicious content" row (line 76), against §4.1 (line 205), §4.8 tiers (line 636) and §4.16 (line 1024).
- **Problem:**
  - The threat table rates parser attacks "⚠️ partial" and says "out-of-process isolation is D17", which reads as undecided.
  - Everywhere else, the design commits to a sandboxed XPC `muninn-worker` (no network, no file access) with status "use".
  - If D17 means something narrower, such as one process per job, the doc doesn't say.

### 4. 🟡 Most proofs in gates B–D are referenced only by number
- **Where:** §7 gate table (lines 1098–1101) and scattered references.
- **Problem:**
  - PROOF-001 to 005 are described inline, and 008, 009, 015 and 016 get a short description each.
  - PROOF-006, 007, 010–014 appear only inside ranges, so nothing in the doc says what they test or what passing means.
  - The doc's own rule is that a failed proof changes the design. So a reader can't tell which parts of gates B–D are still hypotheses without opening `proofs.md`.
- **Fix:** give each proof a one-line claim in the gate table.

### 5. 🟡 Scope model: unclear whether scopes nest and how `protected` works per request
- **Where:** §4.12 Scopes and Interactive sessions (lines 840–861); §4.11 synopsis `session start [--scope …]` (line 735).
- **Problem:**
  - `read` includes `metadata`, and `protected` is "`read` on protected items too". `manage` says nothing about including either.
  - The synopsis accepts a single `--scope`, so the reader can't tell whether a session can hold `read` plus `manage` at once, for example to find an item and then delete it.
  - `protected` is "per request by default", yet it can also be requested as a session scope. How the two interact isn't explained.
  - When a data command auto-starts approval, the doc doesn't say which scope or duration is requested.

### 6. 🟡 "Saved" and "pinned" are not distinguished, and there is no CLI path to "saved"
- **Where:** §4.3 `saved_items` (line 305); §4.7 filters (line 510); §4.12 `metadata` (line 843); §4.11 synopsis.
- **Problem:**
  - `saved_items` covers "Pinned or explicitly saved content", has both `label` and `is_pinned`, and search has separate `saved` and `pinned` filters.
  - But the CLI has only `pin`, `unpin` and `--pinned`. Nothing creates a "saved" item, sets a `label`, or filters on `saved`.
  - "Save snapshot" (line 341) is a different concept with a similar name.
  - The glossary defines neither term.

### 7. 🟡 The CLI synopsis is incomplete for a contract that counts as public interface
- **Where:** §4.11 synopsis (lines 722–737), against flags and commands used elsewhere.
- **Problem:** these appear elsewhere in the doc but not in the synopsis:
  - the options `--json`, `--no-interactive`, `--width`, `paste --as`, `status --audit` and `status --limits`
  - the `debug send` command, `--version` and `help`

  Two further mismatches:
  - `list --all` is in the synopsis, but the pagination section (lines 527–531) describes only cursors for `list`.
  - The `busy` error (§4.14) has no mapped exit code.

  A reader can't build the full command surface from the synopsis.

### 8. 🟡 Decision IDs often stand in for content (taken together)
- **Where:** throughout. Bare or near-bare examples: D7 (870), D8 (718), D12 (870), D13 (849), D15 (302), D16 (491), D17 (76), D18 (802, 944), D24 (1061), D26 (1051), D29 (363), D30 (638).
- **Problem:**
  - Many references carry enough context inline (D14, D21, D22, D23, D25, D27).
  - Others don't say whether the item is decided or open, or what was chosen: for example "out-of-process isolation is D17", "see D16", and "(D18)" on the disk floor.
- **Fix:** give each reference its status (accepted, pending or open) and the gist in one clause.

### 9. 🟢 The invariant on lock conflicts with the stated guarantee
- **Where:** §1.2 invariant 2 (line 86), against §1.1 (line 74) and §4.4 (lines 408, 421).
- **Problem:**
  - Invariant 2 makes "opens the DB only while unlocked" a must-hold rule.
  - §4.4 calls closing the DB "defense in depth only" and says "the guarantee is the policy gate".
  - `status` still answers while the Mac is locked. The doc doesn't say whether it reports item counts with the DB closed.

### 10. 🟢 Privacy skips sit uneasily with the "observed states" guarantee
- **Where:** §4.8 Capture guarantees (line 606); invariant 4; §4.14 Visibility (line 952).
- **Problem:**
  - The guarantee says every observed state is "persisted, coalesced, or counted as skipped with a reason".
  - Invariant 4 says privacy skips leave no trace.
  - The exception is reconciled only later, in §4.14, so the guarantee table reads as contradicting the invariant.

### 11. 🟢 Deleting an item vs. audit-log item ids
- **Where:** invariant 5; §4.3 Deletion; `audit_log` (line 312); §4.12 audit (line 878).
- **Problem:** "Deleting an item removes everything about it", but the audit log records `content_item_id` for each request. The doc doesn't say whether audit rows for a deleted item are kept, scrubbed or deleted.

### 12. 🟢 Keychain "without a prompt" wording
- **Where:** §1.1 (line 70), against §4.4 (lines 390–393).
- **Problem:** "Another process can't take the key without a prompt" suggests a prompt could grant access. §4.4 describes access as gated purely by the entitlement's access group, which normally means there is no prompt path at all.

### 13. 🟢 Terms that are undefined or defined late
- "Goldfish" (line 12) is never defined.
- "The raven" and its *recording* mode first appear at line 422 and are explained only partially in §4.17, which defers to `docs/brand.md`.
- "The earlier phase plan" and "old phases 1–8" (line 1109) refer to a plan that isn't in the doc.
- "SQLCipher + FTS5 from the exact package" (line 1098): the doc never says how SQLCipher is obtained. v1 used a system-SQLite shim, and the design tries to avoid extra dependencies.

### 14. 🟢 Malformed MetricKit table row
- **Where:** §4.16, line 1040.
- **Problem:** the row has a fifth cell ("Feeds `doctor` without sending anything anywhere") in a four-column table, and that cell contradicts the "not in v2" status in the same row. Stage 5 found the same issue (R-Z12).

---

## Cross-reference with Stage 5

These findings overlap with Stage 5 round 2:

| Stage 6 finding | Stage 5 finding | Overlap |
|---|---|---|
| 6 | R-Z10 | The saved-vs-pinned split has no consumer. |
| 7 | R-Z5 | `list` cursors vs. `--all`. |
| 9 | R-Z3, R-C1 | Lock teardown and what the guarantee is. |
| 14 | R-Z12 | The same malformed MetricKit row. |
| 1 | R-Z9 | Both concern content-hash identity. |

## Maintainer classification

Classified 2026-11-09. Maintainer decisions: alternatives live in `decisions.md`; the `metadata` scope is kept, with a user story; `transform` is deferred to D1; the minimum is macOS 27. The other classifications follow Stage 8's sorting, and the resolution rule was that a design-doc change must remove at least as much text as it adds, unless it fixes a contradiction or an invariant. The design went from 1,128 to about 877 lines.

| ID | Class | Resolution |
|---|---|---|
| 1 | Valid | Identity rules in §4.3; §5 recomputes text identity and never merges non-text rows. |
| 2 | Valid | The index step is not a job row; `content_items.indexed_version` tracks freshness (§4.8). |
| 3 | Valid | The threat row says isolation is pending PROOF-013; §4.16 status is `proof`. |
| 4 | Valid | The §7 gate table names each proof with a one-line claim. |
| 5 | Valid | Scopes nest (`read` ⊃ `metadata`, `manage` separate and combinable); `protected` is per request only; an auto-started session asks for the scope its command needs. |
| 6 | Valid | Pinned only (D37). |
| 7 | Valid | The synopsis includes global flags and `debug send`; `busy` maps to exit 9; the full reference is generated from schemas. |
| 8 | Valid in part | `decisions.md` now carries a status and the gist for every ID; design references pair an ID with its gist where it matters. |
| 9 | Valid | Invariant 2 reworded ("serves data only while unlocked"); `status` answers from in-memory counters. |
| 10 | Valid | The guarantee row includes privacy skips. |
| 11 | Valid | Audit rows null the item id on delete. |
| 12 | Valid | "Private access group granted only to the helper." |
| 13 | Valid | "Goldfish" defined; raven pointer; the phase-plan mapping deleted; SQLCipher's source is in D2. |
| 14 | Valid | Row removed. |
