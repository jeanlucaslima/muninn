# Stage 7: Critic Review: `docs/designs/muninn-v2.md` (round 1)

## Scope and inputs

- **Target:** `docs/designs/muninn-v2.md` at commit `50152ac`, all lines 1–1128. The doc has no separate implementation plan.
- **Reviewers:** three fresh subagents run in parallel:
  - `egm-design` (design critic), against `feature-spec-standard.md`
  - `egm-structural`, against `feature-spec-standard.md`
  - `egm-style`, with its persona only
- **What reviewers received:** the target, plus `docs/decisions.md` and `docs/proofs.md` as baseline context.
- **What reviewers did not receive:** anything under `docs/reviews/`, the design conversation, or `AGENTS.md`/`CLAUDE.md`. The adapters set `omitClaudeMd`.
- **Code check:** the design critic checked one claim against v1 code, `packages/MuninnStore/Sources/ClipboardStore.swift`.
- **Reviewer status:** all three ran to completion. None failed.

| Reviewer | Verdict | 🔴 | 🟡 | 🟢 |
|---|---|---|---|---|
| design | Fails the standard as written | 1 | 15 | 9 |
| structural | Not ready | 1 | 5 | 9 |
| style | No blockers | 0 | 7 | 9 |

**Round status:** **not clean**. There are two Blockers, and both reviewers raised the same one. Under the review-loop rules, the stage converges only after two clean rounds in a row.

Raw finding IDs follow the pattern `<reviewer>-<round>-<n>`. For example, `design-1-M3` is the design reviewer's round 1 finding M3. Consolidated items are **S7-NN**. The **Earlier** column shows where Stage 5 (`zoom_out_report.md`) or Stage 6 (`comprehension_report.md`, finding `Cn`) already raised the same issue.

---

## Consolidated findings

### 🔴 Blockers

#### S7-01. No "Alternatives considered" section; core choices are presented as single paths
*Sources: design-1-B1, structural-1-B1. Earlier: none.*

- **Where:** the whole document. Alternatives appear only in fragments:
  - §4.3 (line 361)
  - §4.6 (lines 444–456)
  - §4.11 design notes (lines 804–809)
  - §4.16 "don't use" table (lines 1046–1057)
  - the Porter-stemmer note
- **Problem:** the feature-spec standard fails a spec that proposes one path without showing that viable alternatives were considered and rejected for concrete reasons. These core choices have no recorded alternative in the doc:
  - **Rewriting rather than evolving v1.** Why not encrypt the v1 store and add FTS?
  - **SQLCipher** against CryptoKit encryption of columns or blobs over plain SQLite, SQLite SEE, or FileVault plus Data Protection classes. SQLCipher is the project's first external dependency (D2), and D2 lists no options.
  - **Two FTS5 indexes (word and trigram)** against a single FTS5 index with a custom tokenizer, an in-memory n-gram index, or SearchKit.
  - **The session/approval access model** against no CLI history access, an app-only workflow, or Touch ID approval for each command.
  - **Hosting the helper with `SMAppService.agent`** against a login-item helper app.
  - **Pasteboard polling.** Only D6 covers it.
  - **Helper vs. app as the pasteboard reader.** Only one side's trade-offs are listed (lines 1007–1011).
- **Fix:**
  - Add a top-level **Alternatives considered** section between §4 and §5.
  - Use one table: decision area | chosen | alternatives | rejected because | ref.
  - Cover at least: disk encryption, asset storage, transport, parser isolation, helper hosting, search engine and tokenizers, change detection, ORM, previews, and rewrite vs. evolve.
  - Link the scattered notes to the table rather than moving them.
  - See S7-30 for the D27 citation.

### 🟡 Major

#### S7-02. No problem statement or success criteria
*Sources: structural-1-M1, design-1-M1. Earlier: none.*

- **Where:** lines 5–23, §1 and §2.
- **Problem:**
  - The motivation is spread across the intro and the v1 table. "A new, better product" (line 16) is a stance, not a problem.
  - Nothing says which user problems justify a full rewrite plus a stricter CLI, or who the user is.
  - Nothing says how success is judged beyond the latency benchmarks.
- **Fix:**
  - Add a **Problem** section before the Goals, with 3–5 concrete v1 failures that point to rows in the §2 table: plaintext DB, unauthenticated socket, binaries not stored, unranked `LIKE` search.
  - Add success criteria the user can observe.
  - Make each goal trace back to a problem.

#### S7-03. No Risks and Mitigations section beyond the security threat model
*Sources: structural-1-M2, design-1-N1. Earlier: none.*

- **Where:** §1.1 (lines 55–79) covers security only. Other risks are scattered across §4.8, §4.14 and §7 line 1106.
- **Problem:** "A failed proof changes the design" (line 1106), but no proof has a fallback named in advance. Risks with no stated mitigation:
  - the SQLCipher package lacks trigram support or fails the encryption checks (PROOF-004)
  - no workable pasteboard reader (PROOF-001)
  - the Keychain access group needs a provisioning profile (PROOF-003)
  - growth of the single DB file
  - `accessBehavior` platform churn
  - SQLCipher licence changes
  - the dual SwiftPM/Xcode build
- **Fix:** add a §1.3, or a separate section, with one table: risk | likelihood/impact | mitigation | fallback if the proof fails | proof. Give one row to each gate A proof, plus rows for the dependency, scale and platform risks.

#### S7-04. Invariants are said to hold "in every build", but the gate plan ships builds that break them
*Sources: design-1-M2. Earlier: none.*

- **Where:** line 83; invariants 2, 9 and 10; §7 gates B–D.
- **Problem:**
  - Invariant 2 (lock) needs session-lock handling, which arrives in gate C (PROOF-011).
  - Invariants 9 and 10 need the limits and the abuse suite, which arrive in gate D.
  - So the gate B "secure minimum engine" breaks three invariants by design, which line 83 itself calls a bug.
- **Fix:** either scope each invariant by gate ("in force from gate X"), or move a minimal lock refusal and minimal capture size caps into gate B.

#### S7-05. Reading a large pasteboard item has no memory bound, which contradicts invariant 10
*Sources: design-1-M3. Earlier: Stage 5 R-C3.*

- **Where:** line 94, lines 917 and 930, line 628, and the "2 GB text" abuse case at line 702.
- **Problem:**
  - `data(forType:)` returns the whole `Data`. So the "bytes per representation" check runs only after the full payload is already in `muninnd`, the process that holds the key.
  - A 2 GB copy means about 2 GB in the helper. Jetsam may kill it, or memory pressure becomes severe.
  - Backpressure doesn't help, because the read itself is the unbounded step.
- **Fix:**
  - Restate invariant 10 honestly.
  - Add a gate A measurement: peak RSS when reading 500 MB and 2 GB representations, and whether any API reports the size first (`detectMetadata`, promise metadata).
  - If the measured peak is unacceptable, consider moving the read into a short-lived process.

#### S7-06. `content_hash` is undefined when representations are omitted, so unrelated captures can merge
*Sources: design-1-M4. Earlier: Stage 5 R-Z9 (identity), Stage 6 C1 (empty-set hash).*

- **Where:** lines 326, 917, 921 (`omitted: "timeout"`) and 924 (`omitted: "disk"`).
- **Problem:**
  - A capture stored as metadata only (because of size, disk space or timeout) hashes the empty set. Because `content_hash` is unique, every such capture collides into one item: one id and one shared history. This is a data-integrity bug.
  - When only some representations are omitted, the same content becomes a different item from a full capture.
- **Fix:** define the hash for omitted representations. For example, include `(uti, "omitted", size if known, capture id)`. Alternatively, never deduplicate items that have an omitted representation. Add the case to PROOF-008.

#### S7-07. Migration: v1 and v2 hashes are computed differently, and v1 non-text hashes collide
*Sources: design-1-M6. Earlier: Stage 6 C1.*

- **Where:** §5 steps 3 and 5 (lines 1071–1079), and line 1069.
- **Problem:** v1's `ClipboardStore.swift` hashes text as `sha256(content)` (line 73) and non-text as `sha256(kind + metadataJSON)` (line 113).
  - If the v1 hash is copied into `content_hash`, migrated text never deduplicates with the same text copied in v2. If v2 recomputes the hash, the step 5 check that the hash "survives" proves nothing.
  - Two screenshots with the same dimensions share a v1 hash, so step 3 merges them, pins included.
  - `schema_version` 0 doesn't occur in practice: v1 migrates to 1 on every open. A DB older than that has no `schema_version` table at all.
- **Fix:**
  - Recompute the v2 hash for text, and use the v1 hash only as an input check.
  - Never merge non-text v1 rows.
  - Make detection handle a missing table.
  - Add these cases to PROOF-010.

#### S7-08. The TIFF pixel-identity rule needs decoding that the helper is forbidden to do
*Sources: design-1-M5. Earlier: Stage 5 R-Z8.*

- **Where:** line 334, against line 898 ("no full decode in the helper") and line 929 ("TIFF is never read").
- **Problem:** comparing pixels means decoding both images in the helper, on the capture path. Regenerating the TIFF on `copy` means encoding it in the helper. Line 929 contradicts line 334 outright.
- **Fix:** use a type-based rule instead: don't read TIFF when a compact raster type exists. On `copy`, either restore only the stored types or regenerate the TIFF in the worker or the client.

#### S7-09. Binding a session to the terminal is weaker than stated, and terminal close isn't detected
*Sources: design-1-M7. Earlier: none.*

- **Where:** §4.12 lines 859 and 861; §1.1 line 73.
- **Problem:**
  - All Terminal and iTerm windows in one GUI login usually share an audit session, so the binding really rests on the tty.
  - `/dev/ttysNNN` numbers are reused. A new window that gets the same number could inherit a live `read` or `protected` session.
  - The doc says sessions end "when the terminal closes" but never says how that is detected.
- **Fix:**
  - Specify the binding key: the tty, the session-leader pid plus its pid version from the audit token, and the leader's start time.
  - Specify detection, for example a kqueue `NOTE_EXIT` on the session leader.
  - Add a tty-reuse case to PROOF-002 and PROOF-006.

#### S7-10. What happens to a caller with no terminal is contradictory
*Sources: design-1-M8. Earlier: none.*

- **Where:** line 857 (prompt text "*not attached to a terminal*"), against lines 859, 866 and 758.
- **Problem:** the prompt implies a caller with no terminal can be approved. But a session must be bound to a terminal, and automation gets no access. A binding with no terminal would let cron and launchd jobs reuse the session, reopening the hole D27 closed.
- **Fix:** pick one rule. Either a caller with no terminal is always refused with `non_interactive` and the line 857 prompt variant is deleted, or it gets a one-shot approval for a single request.

#### S7-11. `--all` streams can hold a read snapshot open indefinitely, so the WAL grows without bound
*Sources: design-1-M9. Earlier: none.*

- **Where:** §4.7 line 534, line 724, and the §4.14 client-flood row (line 925).
- **Problem:** `muninn search --all | less`, or any stalled reader, keeps the read transaction open. While it is open, the WAL can't be checkpointed and keeps growing as large captures arrive. The IPC limits cover frames coming in, not slow readers of streams going out. This breaks invariant 10.
- **Fix:** do one or more of these:
  - set an output write timeout or a maximum stream duration;
  - materialize the result ids first, then stream rows in short transactions;
  - abort the stream when the WAL passes a size threshold.

  Add the case to PROOF-015.

#### S7-12. launchd `Sockets` (marked "adopt") needs an absolute path that the bundle plist can't hold
*Sources: design-1-M10. Earlier: Stage 5 R-Z2 (the "adopt" status assumes the socket wins).*

- **Where:** §4.16 line 1028; §4.6 line 438.
- **Problem:**
  - `SockPathName` doesn't expand `~`.
  - The `SMAppService.agent` plist is signed inside the bundle, so it can't hold a path specific to one user.
  - `SecureSocketWithKey` creates a random path that clients can't find.
  - Socket activation also doesn't fit dev builds run with `swift run`.
- **Fix:** remove the row, or make it a PROOF-002 item. This is one more point in favor of XPC `MachServices` (D21).

#### S7-13. The sandboxed XPC worker's reachability, packaging and HTML parser are unproven until gate D
*Sources: design-1-M11, structural-1-M5. Earlier: Stage 6 C3 (status of isolation), style-1-M2 (row marked `use`).*

- **Where:** §4.1 lines 205, 206 and 219; the §4 bundle diagram (lines 155–161); §4.8 lines 636 and 655; §4.16 line 1024; §7.
- **Problems:**
  - The bundle diagram and the embedding sentence at line 219 leave out `Contents/XPCServices/muninn-worker.xpc`.
  - It isn't established that a launchd agent in `Contents/MacOS` can reach a bundled XPC service. If PROOF-003 moves the helper to `Contents/Library/LoginItems/`, the service must move with it.
  - HTML-to-text through `NSAttributedString` uses WebKit and expects the main thread. That is unproven inside a sandboxed service with no network and no file access, and HTML is an attack-surface parser.
  - All of this surfaces in gate D, after gate C has fixed the bundle layout.
  - The §4.16 row says `use` while D17 is still pending PROOF-013.
- **Fix:**
  - Add the worker to the diagram and the embedding sentence.
  - Mark the helper's location "pending PROOF-003".
  - Add to gate A a check that the agent can launch the embedded sandboxed XPC service in both packaging variants.
  - Name an HTML extractor that doesn't use WebKit.
  - Change the row status to `proof (PROOF-013)`.

#### S7-14. File references will trigger privacy (TCC) prompts in the background helper
*Sources: design-1-M12. Earlier: none.*

- **Where:** §4.3 lines 338–343; line 782; snapshots; D14.
- **Problem:** the helper makes bookmarks, reads size and mtime, checks availability and takes snapshots. For files in Desktop, Documents, Downloads, iCloud Drive or on removable volumes, that can trigger TCC prompts attributed to `muninnd`, or fail silently. PROOF-001 covers only pasteboard permissions.
- **Fix:**
  - State which process touches referenced files, and when.
  - Add a protected-folder case to PROOF-001.
  - Consider recording only the URL and resource values the pasteboard provides at capture time, and touching the file only on explicit user action.

#### S7-15. No storage footprint estimate, although history is permanent and lives in one file
*Sources: design-1-M13. Earlier: Stage 5 R-C2 (shards for Time Machine cost).*

- **Where:** §4.3 lines 345–361; §4.14 lines 944–948; D18.
- **Problem:** an example rate of 30 screenshots a day at 3 MB each comes to about 33 GB a year, possibly re-copied by Time Machine every hour. Without a growth estimate, D15 and the warning thresholds can't be judged, and PROOF-005 has no acceptance target.
- **Fix:**
  - Add a sizing table for light, typical and heavy users at 1 and 3 years.
  - Add a Time Machine cost estimate.
  - Give PROOF-005 an explicit acceptance target.
  - Consider excluding the DB from Time Machine, since a restore on another Mac is useless anyway (line 1044).

#### S7-16. Protected items: redacted or excluded? Deleted items stay in the audit log
*Sources: design-1-M14. Earlier: Stage 6 C11 (audit log).*

- **Where:** line 844 vs. line 875; invariant 5 (line 89) vs. `audit_log.content_item_id` (line 312).
- **Problem:**
  - Redacted rows in `list` reveal that protected items exist: how many, when, and from which app (for example 1Password). They are visible even under the `metadata` scope, which contradicts the counts guarantee that PROOF-006 tests.
  - The audit log keeps item ids after an item is deleted, and it grows without bound.
- **Fix:**
  - Choose one: exclude or redact.
  - Scrub or anonymize audit rows on delete, or narrow the wording of invariant 5.
  - Give the audit log a retention limit in `MuninnLimits`.

#### S7-17. The minimum macOS version doesn't match the pasteboard API capture depends on
*Sources: design-1-M15. Earlier: none.*

- **Where:** D5 (macOS 15), line 970 (`accessBehavior` "since macOS 15.4"), line 999 (proofs run on macOS 27).
- **Problem:** on macOS 15.0–15.3, `accessBehavior` doesn't exist. The rule "reads only in `.alwaysAllow`" (line 988) then either can't be evaluated or means capture never starts.
- **Fix:** raise the minimum to 15.4 or later, or define what happens when the API is missing. Run PROOF-001 on the minimum OS version too.

#### S7-18. The CLI synopsis, the behavior table and the flags used elsewhere don't match
*Sources: structural-1-M4. Earlier: Stage 6 C7, Stage 5 R-Z5.*

- **Where:** §4.11 synopsis (lines 722–737) and table (lines 776–789).
- **Problem:**
  - These commands have no row in the behavior table: `pin`, `unpin`, `delete`, `session`.
  - `debug send` has a row but is missing from the synopsis.
  - These flags are used elsewhere but missing from the synopsis: `--json`, `--no-interactive`, `paste --as`, `--width`, `status --audit`, `status --limits`, `--version` and `help`.
  - There is a `saved` filter but no `--saved` flag.
  - The `--type` kinds (`rich_text`, `html`) aren't enumerated against `primary_kind`.
  - `busy` has no exit code.
- **Fix:**
  - Make the synopsis complete, including global flags.
  - Give every command a row in the behavior table, with a "Scope needed" column linked to §4.12.

#### S7-19. Claims that depend on pending proofs are stated as fact, with no proof ID
*Sources: style-1-M2. Earlier: Stage 6 C12 (line 70).*

- **Where and fix:** each item names the problem and its fix. Line 14 says proof-marked statements are hypotheses, so these must carry their proof ID:
  - **Line 70** ("can't take the key without a prompt") contradicts §4.4, where access comes from the access group. Rewrite as "private access group granted only to the helper (§4.4, PROOF-003)".
  - **Line 529:** add *(PROOF-007)*.
  - **Line 628:** "fits the memory budget" contradicts line 903, which calls the budget a hypothesis. Point it at PROOF-008 and PROOF-009.
  - **Line 1011:** change "stays within" to "must stay within (PROOF-008)".
  - **Line 1019:** reword in the conditional, referring to D22 and PROOF-017.
  - **Lines 456 and 1022:** the "same `SecCode` machinery XPC uses" claim has no source. Drop it or cite one.
  - **Line 491:** "several times the text size" has no source. Point it at D16 instead.

#### S7-20. "Capture" has three meanings, and the glossary contradicts how the body uses it
*Sources: style-1-M3. Earlier: none.*

- **Where:** line 1117, against lines 606, 625–627, 919–920 and 924.
- **Problem:** the glossary defines a capture as a change "that passed the capture policy". The body uses "capture" for states that were never read and for the process as a whole.
- **Fix:** use **observed change** for pre-policy states and **capture event** for the persisted row, and update the glossary.

#### S7-21. "Saved" and "pinned" have no defined relationship
*Sources: style-1-M7. Earlier: Stage 6 C6, Stage 5 R-Z10.*

- **Where:** lines 305, 510, 519, 725, 818 and 843.
- **Problem:** the doc doesn't say whether "saved" and "pinned" are distinct states. The CLI exposes only `--pinned`.
- **Fix:** define them in the glossary, then either add `--saved` or drop "saved" entirely.

#### S7-22. The §4.16 status column uses values the legend doesn't define
*Sources: style-1-M5, structural-1-N2. Earlier: none.*

- **Where:** line 966, against lines 1018–1044.
- **Problem:** the table uses `rely on`, `use as-is`, `**not in v2**`, `**D22**` and `use (PROOF-003)`, none of which the legend defines. The difference between `use` and `adopt` is also unclear.
- **Fix:** define these statuses: **use**, **proof**, **deferred**, **external**, **no**. Normalize every row to them.

#### S7-23. Self-describing and persuasive wording
*Sources: style-1-M4. Earlier: none.*

- **Where:**
  - line 16: "new, better"
  - line 21: "foundation, not a feature"
  - line 49: "stated plainly"
  - line 273: "most important change"
  - line 347: "for free"
  - line 887: "all day, every day"
  - line 907: "work well for normal use"
  - line 909: "cleanly"
  - line 940: "worded honestly"
  - line 964: "Leveraging macOS", and line 966
  - line 1081: "We say this plainly", "the real protection"
- **Fix:** take the rewrites as listed by the style reviewer.

#### S7-24. Leftover review history in normative text
*Sources: style-1-M6, structural-1-N6, design-1-N8. Earlier: Stage 6 C13.*

- **Line 393:** "'no access group' was wrong; the right statement is…". Rewrite as "No access group is shared between the helper and any other target."
- **Line 1109:** the mapping to "the earlier phase plan" refers to a plan that doesn't exist in these docs. Delete it or link to the plan.

#### S7-25. The MetricKit table row is broken and contradicts itself
*Sources: style-1-M1, structural-1-M3, design-1-N7. Earlier: Stage 5 R-Z12, Stage 6 C14.*

- **Where:** line 1040.
- **Problem:** the row has five cells in a four-column table. The fifth cell, "Feeds `doctor`…", is left over from an earlier version and contradicts "not in v2" and D31. It has now been flagged by **five independent reviewers**.
- **Fix:** delete the fifth cell, or move MetricKit into the "don't use" table.

### 🟢 Nits

| ID | Sources | Where | Issue → fix |
|---|---|---|---|
| S7-26 | structural-1-N1 | lines 29–53 | §1 mixes unnumbered and numbered H3s, and the "Open" and "product change" callouts sit under Non-goals. → Number them 1.1–1.4, and move lines 49–53 to a "Product changes from v1" subsection. |
| S7-27 | structural-1-N3 | lines 120, 148 | The v1 table records v2 work, and "✅ Done" mixes with the Delta vocabulary. → Normalize. |
| S7-28 | structural-1-N4 | lines 283–312 | The schema diagram omits `asset_chunks`, `audit_log`, `settings` and `schema_migrations`, has misleading FTS arrows, and has two leftover "(addition)" labels. → Fix the diagram and remove the labels. |
| S7-29 | structural-1-N5 | lines 185–209 | The repo tree is missing `spikes/`, `docs/evidence/` and `muninn-bench`. → Add them. |
| S7-30 | design-1-B1 (part), structural cross-doc | decisions.md D27; line 51 | D27 says "(maintainer decision)" with no link, which the standard forbids. → Give a technical rationale or a link. |
| S7-31 | structural-1-N7, style-1-N6 | lines 758/881; 51/72/866/1125; 74/408; 1107 | Repeated statements can drift apart: the exit-6 list, the no-automation rule, the lock guarantee, and the "no real user data" rule. → Keep one authoritative copy of each and reference it elsewhere. |
| S7-32 | structural-1-N8, style-1-N2 | §8; lines 12, 33, 422 | Undefined terms: helper, worker, scope, gate, evidence level, tier, `MuninnLimits`, `notProcessed`/`omitted`, "Goldfish", "raven", "PT/EN". Line 1128 is governance text placed in the glossary. → Define the terms and move line 1128. |
| S7-33 | structural-1-N9 | line 968 | An emoji in a heading. → Use a bold "Platform constraint:" instead. |
| S7-34 | style-1-N1 | line 5 | Says "two companion documents" but the table has four rows. → "these documents". |
| S7-35 | style-1-N3 | lines 14, 231, 773, 809 | Hedging asides with no trigger. → Drop them, or name the threshold. |
| S7-36 | style-1-N4 | line 600 | The capture targets can't be measured. → Give p95 values, or point to PROOF-008 and D20. |
| S7-37 | style-1-N5 | lines 924, 1037, 79, 832 | Absolute claims ("never fills the disk", "Instant, space-free", "No design can…"). → Narrow them. |
| S7-38 | style-1-N7 | lines 93–94 | Vague invariant names. → "Idle memory is bounded"; reword "does less, never part of a job". |
| S7-39 | style-1-N8 | lines 16–23 | Hard-wrapped paragraphs, unlike the rest of the file. → Unwrap them. |
| S7-40 | style-1-N9 | lines 1099, 482 | → Say "L1 evidence" instead of "unit-level"; rename the "Good at" column to "Matches". |
| S7-41 | design-1-N2, N3 | lines 1037, 378 | The APFS-clone pre-migration copy could leave plaintext that shares blocks. The `pre-<version>` copy keeps items deleted afterwards. → Clarify (Stage 5 R-C4 raised the same deletion-trace theme). |
| S7-42 | design-1-N4 | line 618 | Any app can spoof the self-copy marker and suppress a capture. → Add a nonce known only to the helper. |
| S7-43 | design-1-N5 | line 608 | Muninn's own writes can increase `missedChanges`. → Exclude self-writes from the count. |
| S7-44 | design-1-N6 | line 939 | "Followed user interaction with that app" can't be observed without Accessibility. → Say how it's detected, or drop it. |
| S7-45 | design-1-N9 | lines 91, 235, 793, 527–531 | Invariant 7 needs "for the same caller permissions". Unstated: dev-build key storage, how the CLI symlink is installed, and a latency target for `list` keyset paging. |

### Cross-document (baseline, not scored)

| ID | Source | Issue |
|---|---|---|
| S7-X1 | structural | `decisions.md` **D4** still says "inline or external, threshold by benchmark", which contradicts §4.3 line 347 and D15 (inline only). Line 1087 requires the doc and `decisions.md` to change together. |

---

## Traceability: raw finding → consolidated item

| Raw | → | Raw | → | Raw | → |
|---|---|---|---|---|---|
| design-1-B1 | S7-01, S7-30 | structural-1-B1 | S7-01 | style-1-M1 | S7-25 |
| design-1-M1 | S7-02 | structural-1-M1 | S7-02 | style-1-M2 | S7-19, S7-13 |
| design-1-M2 | S7-04 | structural-1-M2 | S7-03 | style-1-M3 | S7-20 |
| design-1-M3 | S7-05 | structural-1-M3 | S7-25 | style-1-M4 | S7-23 |
| design-1-M4 | S7-06 | structural-1-M4 | S7-18 | style-1-M5 | S7-22 |
| design-1-M5 | S7-08 | structural-1-M5 | S7-13 | style-1-M6 | S7-24 |
| design-1-M6 | S7-07 | structural-1-N1 | S7-26 | style-1-M7 | S7-21 |
| design-1-M7 | S7-09 | structural-1-N2 | S7-22 | style-1-N1 | S7-34 |
| design-1-M8 | S7-10 | structural-1-N3 | S7-27 | style-1-N2 | S7-32 |
| design-1-M9 | S7-11 | structural-1-N4 | S7-28 | style-1-N3 | S7-35 |
| design-1-M10 | S7-12 | structural-1-N5 | S7-29 | style-1-N4 | S7-36 |
| design-1-M11 | S7-13 | structural-1-N6 | S7-24 | style-1-N5 | S7-37 |
| design-1-M12 | S7-14 | structural-1-N7 | S7-31 | style-1-N6 | S7-31 |
| design-1-M13 | S7-15 | structural-1-N8 | S7-32 | style-1-N7 | S7-38 |
| design-1-M14 | S7-16 | structural-1-N9 | S7-33 | style-1-N8 | S7-39 |
| design-1-M15 | S7-17 | structural cross-doc | S7-X1, S7-30 | style-1-N9 | S7-40 |
| design-1-N1 | S7-03 | design-1-N2, N3 | S7-41 | design-1-N4…N6 | S7-42…44 |
| design-1-N7 | S7-25 | design-1-N8 | S7-24 | design-1-N9 | S7-45 |

## Maintainer classification

Classified 2026-11-09. Maintainer decisions: alternatives live in `decisions.md`; the `metadata` scope is kept, with a user story; `transform` is deferred to D1; the minimum is macOS 27. The other classifications follow Stage 8's sorting, and the resolution rule was that a design-doc change must remove at least as much text as it adds, unless it fixes a contradiction or an invariant. The design went from 1,128 to about 877 lines.

| ID | Class | Resolution |
|---|---|---|
| S7-01 | Valid; resolved in `decisions.md` (maintainer) | Every decision row has "chosen" and "alternatives → why rejected" columns, including D2, D32 (rewrite vs. evolve), D35, D36 and D38; the design links to it. |
| S7-02 | Valid | §1.1 Problem (five v1 failures linked to §2) plus a success line. |
| S7-03 | Valid | Each gate A proof has an "If it fails" block. |
| S7-04 | Valid | Invariants bind release builds from the gate that delivers them. |
| S7-05 | Valid | Invariant 10 restated; PROOF-001 step 7 measures the peak. |
| S7-06 | Valid | Items with an omitted or absent primary representation are never deduplicated. |
| S7-07 | Valid | §5 rewritten; PROOF-010 cases added. |
| S7-08 | Valid | Pixel rule removed. |
| S7-09 | Valid | §4.12 states the property; the mechanism and the tty-reuse case are in PROOF-002. |
| S7-10 | Valid | Callers with no terminal are always refused. |
| S7-11 | Valid | A stream deadline in `MuninnLimits` (the simple variant); PROOF-007. |
| S7-12 | Valid | `Sockets` row moved to "don't use", with the reason. |
| S7-13 | Valid | Worker in the diagram and embedding text; launch tested in PROOF-003 step 6; HTML extractor in PROOF-013; statuses set to `proof`. |
| S7-14 | Valid | The helper never touches referenced files in the background; PROOF-001 step 8. |
| S7-15 | Valid | PROOF-005 sizing target; Time Machine exclusion is D34. |
| S7-16 | Valid | Protected items excluded (D39); audit ids nulled; retention bound. |
| S7-17 | Valid (maintainer) | Minimum macOS 27 (D5). |
| S7-18 | Valid | Full synopsis with a scope column; the generated reference is the authority. |
| S7-19 | Valid | Claims carry proof IDs or were reworded; the `SecCode` claim is removed. |
| S7-20 | Valid | "Observed change" vs. "capture event"; glossary updated. |
| S7-21 | Valid | Pinned only (D37). |
| S7-22 | Valid | Status legend: use, proof, deferred, external, no. |
| S7-23 | Valid | Persuasive phrasing removed in the rewrite. |
| S7-24 | Valid | Both passages removed. |
| S7-25 | Valid | Removed. |
| S7-26 – S7-40 | Valid | Applied in the rewrite: §1 renumbered 1.1–1.6; tree adds `spikes/`, `docs/evidence/` and `muninn-bench`; schema diagram fixed; terms defined; emoji removed; "these documents"; text unwrapped; "L1"; column renamed. S7-30: D27 now has a technical rationale. |
| S7-41 | Valid | The pre-migration copy is a ciphertext clone, removed after the next start; orphaned-DB copies are flagged as possibly holding deleted items. |
| S7-42 | Disputed | No nonce: any app can already opt out with `ConcealedType`; spoofing the marker only suppresses the spoofer's own capture (§1.5, §4.8). |
| S7-43 | Valid | Self-writes excluded from `missedChanges`. |
| S7-44 | Valid | High confidence means only `org.nspasteboard.source`. |
| S7-45 | Valid in part | Invariant 7 says "for the same caller permissions"; dev key storage stated; `list` paging gone. CLI symlink installation stays as v1's `CLIInstaller`. |
| S7-X1 | Valid | D4 corrected. |
