# Stage 8: Intermediate Zoom Out: `docs/designs/muninn-v2.md`

## Scope and inputs

- **Target:** `docs/designs/muninn-v2.md` at commit `50152ac`, lines 1–1128. This is unchanged since Stages 6 and 7.
- **Reviewer:** one fresh `egm-zoom-out`, applying `zoom-out-standard.md`.
- **The reviewer received:**
  - the target;
  - `docs/decisions.md` and `docs/proofs.md`;
  - the three prior reports: `zoom_out_report.md`, `comprehension_report.md` and `critic_report.md`.
- **The reviewer did not receive:** the design conversation, `AGENTS.md`/`CLAUDE.md`, or memory.
- **Isolation note:** unlike Stages 5–7, this reviewer **did read earlier findings**, because Stage 8 judges them. So its views on the earlier findings are not independent. Read section 1's sorting as one reviewer's recommendation, not a second opinion. Section 4 is its own new material.
- **Task:** say which proposed additions belong in the design, flag mitigations that cost more than the problem, check that the scope still holds, and find altitude problems nobody raised.

**Verdict: Revise.** The architecture holds. Most Stage 6 and 7 additions belong in `proofs.md`, `decisions.md` or a later per-gate spec, not in this doc. There are two gaps to close before gate A and two one-line rules to settle before gate B.

> **Disagreement for the maintainer to settle:** this reviewer would downgrade **S7-01** (no Alternatives section) from Blocker. It would also move the options into `decisions.md` rather than add a section to the design. Two Stage 7 reviewers rated it a Blocker independently, under the feature-spec standard. Both views are recorded here; the call is the maintainer's.

---

## 1. Which proposed additions belong in the design

The current split is: the design says what and why, `proofs.md` says how we'll know, and `decisions.md` holds the options. Most of Stage 7's "add a section" findings would add about 150–250 lines that duplicate those files and undo the Z1 cut.

### Keep in the design, as a line or a short paragraph each

| Finding | What to add | Why it's design-level |
|---|---|---|
| S7-02 | 4–5 bullets before §1 listing concrete v1 failures, each pointing to a §2 row, plus why we rewrite instead of evolving v1 (the rewrite-vs-evolve part of S7-01). **No** separate success-criteria section: the goals and gates already serve that purpose. | This is the root reason for the project. Today it is a stance, not a stated problem. |
| S7-04 | One sentence after line 83: "Invariants bind release builds and are enforced from the gate that delivers them; nothing before gate C runs on real data (§7)." | It removes a contradiction without changing the gate plan. |
| S7-05 / R-C3 | Restate invariant 10: the bound applies after the read, and the peak is one representation. | An invariant must not claim more than the design delivers. The measurement goes in PROOF-001 or PROOF-008. |
| S7-06 / S7-07 / C1 / R-Z9 | One identity rule in §4.3 (see M1). | A data-integrity bug. |
| S7-10 | Choose "no terminal means refused" and delete the line 857 prompt variant. | A policy contradiction, fixed by deleting text. |
| S7-16 (first half) | Choose **exclude**, not redact, in line 844. This matches line 875. | A policy contradiction. |
| R-C4 | Reword invariant 5: "unreachable at commit; physical purge is best effort." | Same honesty point as invariant 10. The `secure_delete` and checkpoint details are gate B mechanics. |
| S7-08 / R-Z8, S7-12, S7-25, S7-24, S7-34 | Delete the text. | Each of these makes the doc smaller. |

### Route elsewhere and leave the design alone

| Finding | Where it should go |
|---|---|
| **S7-01** (Alternatives) | `decisions.md`. Fill in "options / rejected because" for D2 (SQLCipher vs. CryptoKit over plain SQLite or FileVault alone), D5, D6 and the session model. A second register in the design would drift away from `decisions.md`. |
| S7-03 (Risks) | `proofs.md`. Add an **"If it fails"** line to each gate A proof's *Decision* block. Proof failure is the project's risk model (rule 6). Licence risk is already in D2. |
| S7-09 (binding mechanics) | The design states only the property: "a session can't outlive its terminal or pass to a new terminal that reuses the tty". The mechanism goes in PROOF-002 and PROOF-006. |
| S7-13 (worker reachability) | Add the check to PROOF-003 in gate A, plus one line in the §4 diagram. Record the HTML extractor as a constraint for gate D, not a choice made now. |
| S7-14 (TCC) | Add a protected-folder case to PROOF-001. The design gets one constraint: "the helper never touches referenced files in the background; only an explicit user action does". That is simpler than the current text. |
| S7-15 (sizing, Time Machine) | Make it PROOF-005's acceptance target. Excluding the DB from Time Machine becomes a new open decision. |
| S7-16 (audit retention) | Put the value in `MuninnLimits`, and add one clause to invariant 5 on whether audit rows survive a delete. |
| S7-17 (minimum macOS) | Raise D5 to the oldest OS that PROOF-001 actually runs on. A one-cell change in `decisions.md`. |
| S7-18 (complete synopsis) | The design keeps the command list. The full flag and exit-code reference is generated from `docs/cli-schemas/` in gate B. Otherwise there would be three sources of truth. |
| C4, C8, S7-19, S7-22, S7-32 | Small edits, one clause each. |
| S7-X1 | Fix D4 in `decisions.md`. |

### Reject or defer
S7-42, R-C2, R-C5, the short-lived reader in R-C3, and the "materialize then stream" variant of S7-11. Section 2 gives the reasons.

---

## 2. Mitigations that cost more than the problem

### 🟡 D1. S7-42: a nonce on the self-copy marker
Any app can already opt out of capture with `ConcealedType` (D7), which Muninn honors on purpose. A nonce known only to the helper adds secret state to close a hole that the platform convention leaves open anyway. **Reject.** Optionally add one line to §1.1: "any app can choose not to be recorded."

### 🟡 D2. R-C2: asset shard files attached with `ATTACH`
Commits across attached DBs aren't atomic in WAL mode. That brings back the ordering rules and startup sweep that the inline-only choice (Z2/C1) removed, to solve a Time Machine cost no one has measured. **Measure it in PROOF-005 first.** If the cost is too high, try excluding the DB from Time Machine before considering shards.

### 🟡 D3. R-C3: a short-lived process for large reads
It would add a second permission identity, another IPC channel and more latency, before the peak is known. **Restate invariant 10** and measure peak RSS for 500 MB and 2 GB reads in PROOF-001 or PROOF-008. Revisit only if jetsam actually kills the helper.

### 🟢 D4. R-C5: adaptive polling
This optimizes before `missedChanges` has produced any data. Keep the interval fixed in gate B, record the counter in PROOF-008, and revisit D6 if the numbers call for it.

### 🟢 D5. S7-11: `--all` holding the WAL
"Materialize ids, then stream in short transactions" adds a second read mode. Instead, add slow outbound readers to the client-flood row (line 925), with a stream deadline in `MuninnLimits`. If R-Z5 is adopted, `--all` is the only long reader, so one limit covers it.

### 🟢 D6. S7-09: tty, pid-version and start-time binding plus kqueue
This is too much detail for the design. Bind to the terminal's session-leader process (pid plus pid version from the audit token). Then tty reuse can't match, and "terminal closed" means the leader exited. Put the mechanism in PROOF-002; the design states only the property.

### 🟢 D7. R-C1: the `WhenUnlocked` keychain class
Proportionate as an experiment: one more row in PROOF-003 step 3. Adopt it only if it lets you **delete** the step-5 lock teardown (R-Z3). Otherwise it adds a wait-for-unlock state and an error-code distinction for nothing.

### Round-2 findings this reviewer endorses on simplicity grounds
These remove text or a proof, and none adds a mechanism:
- R-Z4: drop `transform`.
- R-Z5: drop `list` cursors.
- R-Z6: add a trigram-only baseline in PROOF-004.
- R-Z2: make XPC the default the socket must beat.
- R-C7: close D30 as "after commit".

---

## 3. Whether the scope and shape still hold

**They hold.** None of the roughly 80 findings challenges:
- the helper as the only owner of the encrypted DB;
- the split between events, content and derived data;
- one `SearchService`;
- pure processors in an on-demand worker;
- access anchored in user presence;
- gates driven by evidence.

The findings fall into three groups:
1. **Content identity** (S7-06, S7-07, C1, R-Z9): a real bug.
2. **Gaps in what gate A tests** (S7-05, S7-13, S7-14, S7-17): unknowns that could reshape the bundle.
3. **Doc hygiene and consistency:** everything else.

No finding calls for a new component.

### 🔴 B1. The most important fix: gate A doesn't test the full bundle and permission layout
- **Where:** §7 gate A (line 1098), PROOF-001 and PROOF-003.
- **What's wrong:** §7 restructures the bundle in gate C based on gate A's results. But gate A doesn't test these together:
  - whether the helper can launch the embedded sandboxed XPC worker, both as a bare executable and as a `LoginItems` bundle (S7-13);
  - whether a background agent touching referenced files triggers TCC prompts (S7-14);
  - how much memory one large pasteboard read costs (S7-05);
  - whether everything works on the minimum OS (S7-17).

  Each of these can decide where the helper lives and which process reads the pasteboard. Run separately, they could each pass locally but conflict with each other.
- **Why it matters:** if gate D finds the worker can't be reached from the layout gate C chose, the restructure has to be redone. The gate model exists to prevent exactly that.
- **Suggestion:**
  - Before writing any spike, extend PROOF-001 and PROOF-003 into one **layout matrix**: helper location × reader process × worker launch × keychain group × file-reference access, run on the minimum OS.
  - Give each proof an "If it fails" line.
  - The only design text change is one line in the §4 diagram.

### 🟡 M1. Fix before gate B: content identity has no rule for missing representations
- **Where:** §4.3 (line 326), §5 step 3.
- **What's wrong:** S7-06, S7-07 and C1 are one problem: items with omitted or absent representations all hash to the same value and merge.
- **Suggestion:** use one sentence: "An item with any omitted or absent representation is never deduplicated; its identity includes its first capture event."
  - Migration recomputes the v2 hash for text, uses the v1 hash only as an input check, and never merges non-text rows.
  - In the same edit, answer R-Z9: should the same text with or without an HTML representation be one item?

---

## 4. Problems no earlier stage raised

### 🟡 N1. The approval trust chain isn't stated: the app is part of the authorization path (§4.12 lines 853–858; §1.1; invariant 3)
- **What's wrong:** the LocalAuthentication prompt runs in the app, and the helper accepts "approved" because the message comes from `client = app`. So invariant 3 depends on the app's integrity. The app is the largest, always-running process (SwiftUI, a URL-scheme handler). §1.1 treats code injection only generically, and D25 mentions an "authenticated context" only for the stricter mode.
- **Why it matters:** this is the main security boundary of the CLI model, and it's implicit. A reader could assume the helper verifies user presence itself.
- **Suggestion:**
  - Add one sentence to §4.12 and one row to §1.1: "Session approval trusts the signed app; compromising the app grants sessions."
  - Record as a decision whether the helper checks the LA result itself (for example with `LAContext.externalizedContext`) or accepts the app's word.
  - Don't build the stricter option in v2 unless PROOF-002 shows it's cheap.

### 🟡 N2. Gate B promises "encrypted capture", but it has no pasteboard seam and no signed reader (§7 line 1099; §4.1 line 233)
- **What's wrong:** gate B runs before the signed bundle, `SMAppService` and onboarding, which all arrive in gate C. An unsigned `swift run muninnd` has a different pasteboard-permission identity from a release build, which is exactly the problem PROOF-001 is about. §4.1 lists `KeyProvider` and `PeerAuthenticator` as test seams, but not the pasteboard. This is Z5's problem again (approval wasn't available in gate B), this time for capture.
- **Why it matters:** gate B's capture evidence would come either from a dev identity that doesn't match release, or from nothing, and nobody would notice until gate C.
- **Suggestion:** add a `PasteboardSource` seam to the line 233 list. Gate B's capture evidence is then "through an injected source (L1)", and real pasteboard capture becomes a gate C deliverable.

### 🟢 N3. CLI and IPC are still written as changes to v1 (§4.11 lines 787, 811–826)
- **What's wrong:** the table uses "Add…", "Replace `offset`…" and "As in v1", although lines 16–18 say v1 interfaces are not constraints. A reader must know v1 to understand v2's protocol.
- **Suggestion:** describe each IPC method as it is in v2, or move the table into the per-gate IPC spec that R-Z1 proposes.

### 🟢 N4. No size budget for the doc while findings pile up
- **What's wrong:** about 80 findings are unclassified across Stage 5 round 2, Stage 6 and Stage 7, with heavy overlap. Resolving each one by adding text would grow the doc back past the Z1 cut.
- **Suggestion:** classify all three reports in one pass, using the overlap maps and section 1's sorting. Set a rule for that pass: a design-doc change must remove at least as much as it adds, unless it fixes a contradiction or an invariant.

---

## Maintainer classification

Classified 2026-11-09. Maintainer decisions: alternatives live in `decisions.md`; the `metadata` scope is kept, with a user story; `transform` is deferred to D1; the minimum is macOS 27. The other classifications follow Stage 8's sorting, and the resolution rule was that a design-doc change must remove at least as much text as it adds, unless it fixes a contradiction or an invariant. The design went from 1,128 to about 877 lines.

| ID | Class | Resolution |
|---|---|---|
| B1 | Valid | PROOF-001 and PROOF-003 now form one layout matrix on the minimum OS, with "If it fails" lines; gate A in §7 says so. |
| M1 | Valid | One identity rule set in §4.3; R-Z9 answered (same text is one item). |
| N1 | Valid | Trust chain stated in §4.12 and §1.5; D33 is open (leaning: accept the app's word in v2; PROOF-002 measures the stronger option). |
| N2 | Valid | `PasteboardSource` seam; gate B capture evidence is L1 through an injected source; real capture is in gate C. |
| N3 | Valid | IPC methods described as v2, not as changes to v1. |
| N4 | Valid | Applied as the resolution rule: 1,128 → ~877 lines. |
| D1–D7 | Accepted as recommended | Nonce rejected; shards and the short-lived reader deferred to measurements; adaptive polling deferred; the simple stream deadline; the binding property only; `WhenUnlocked` as an experiment. |
| S7-01 severity dispute | Maintainer: `decisions.md` | Alternatives recorded per decision, not as a design section. |

---

# Re-audit (Stage 8, round 2)

## Scope and inputs

- **Target:** the revised `docs/designs/muninn-v2.md` (about 877 lines), working copy as of 2026-11-09. The revision is staged but not yet committed. The base is `50152ac`.
- **Reviewer:** one fresh `egm-zoom-out`.
- **The reviewer received:** `decisions.md` and `proofs.md`, both also revised, plus all four prior reports with their maintainer classification tables.
- **Files it checked on its own:** `Package.swift`, `AGENTS.md`, and `apps/muninn-menubar/Sources/CLIInstaller.swift`.
- **Task:** spot-check that the claimed resolutions are in the text, find contradictions the rewrite introduced, and judge whether the doc is at the right level of detail. Settled and disputed findings were not to be re-argued.
- **Cap:** this is Stage 8's one allowed re-audit.

**Verdict: Revise lightly.** Most fixes are in the text, and at about 877 lines the doc is at the right level of detail for a design before gate A. Three gaps remain that gate B would hit: F1, F2 and F5.

## Resolution spot-checks

| ID | Status | Evidence / gap |
|---|---|---|
| Stage 8 B1 (layout matrix) | **landed** | `proofs.md` lines 52, 54, 74, 85, 92 and 141; "If it fails" at 100, 126, 150 and 174; design lines 166–167 and 843. |
| Stage 8 M1 (content identity) | **partial** | Lines 295–297 cover omitted or absent primaries and R-Z9. Nothing says how the primary representation is chosen (F1). |
| Stage 8 N1 (trust chain) | **landed** | §1.5 row 82, line 638, D33 (Open), PROOF-002 line 119. |
| Stage 8 N2 (`PasteboardSource` seam) | **partial** | Seam at 229; gate B uses an injected source at L1 (844). But PROOF-006 and PROOF-008 still claim L2 evidence in gate B (F3). |
| S7-01 (alternatives) | **landed** | `decisions.md` lines 22–62. One gap: D23's alternatives cell is "—" (line 46). |
| S7-04 | **landed** | Line 92. The timing gap is F4. |
| S7-05 | **landed, with a residue** | Line 103 and PROOF-001 step 7. Line 717 states as fact what step 7 tests, and there is a second peak (F6). |
| S7-06 / S7-07 | **landed** | Line 297; §5 lines 819–824; PROOF-010 line 61. |
| S7-10 | **landed** | Lines 80, 659 and 588; D27. |
| S7-16 | **landed** | Lines 652, 290, 331 and 671; D39. The audit schema doesn't match (F8). |
| S7-17 (macOS 27) | **partial** | D5, line 61 and `proofs.md` line 74 agree, but `Package.swift` still says `.macOS(.v13)` (F9). |
| S7-45 (`CLIInstaller` stays) | **partial** | §2's reuse list (lines 130–136) doesn't name `CLIInstaller`; only `doctor` check 1 (line 615) mentions the symlink. |

## New findings

### 🟡 F1. Content identity depends on a "primary representation" that is never defined (§4.3 lines 280, 295–297)
- **What's wrong:**
  - Text items take their identity from normalized plain text. Non-text items take it from the primary representation's bytes.
  - Real copies often carry both kinds. A browser image comes with a URL or alt text, and a Finder copy comes with the file name as plain text.
  - If such a copy counts as text, two different images with the same accompanying text become one item. And because a later capture only adds types the item doesn't already have, the second image's bytes are dropped silently.
- **Why it matters:** this is the same class of data-integrity bug that M1 was meant to close.
- **Suggestion:**
  - Add a precedence rule to §4.3, for example: "the primary is the first kept type in the order file URL > image > PDF > rich text > plain text; plain-text identity applies only when no richer type is kept."
  - Add the case to PROOF-008.
  - State that "normalized" is fixed per schema version.

### 🟡 F2. The unsigned dev helper in gate B needs signing for its default transport and its key storage (§4.1 line 230, §4.4 lines 342–343, §4.6 line 369, §7 line 844)
- **What's wrong:**
  - The default transport, XPC through `MachServices`, needs a registered launchd plist. `swift run` and `swift test` don't have one.
  - The data-protection keychain needs entitlements that an unsigned binary can't carry (`errSecMissingEntitlement`).
  - Line 230 says only "its own Keychain service".
- **Why it matters:** this is N2's problem again, for the key and the transport. Gate B's evidence would come from a dev path the doc never defines.
- **Suggestion:**
  - Add two lines to §4.1:
    - Dev and test builds use `KeyProvider`'s in-memory or legacy-keychain variant.
    - Dev and test builds use an anonymous XPC listener: in-process for tests, a user LaunchAgent for dev.
  - Add "transport endpoint" to the seam list.
  - Have PROOF-002 confirm that the dev variant works.

### 🟡 F3. Gate B proofs claim evidence levels gate B can't produce (`proofs.md` lines 57, 59; design lines 844–845, 462)
- **What's wrong:**
  - PROOF-006 runs at L2 against a *signed* CLI, but gate B has no signing, and dev builds authenticate by UID only.
  - PROOF-008 claims L2–L3 capture-path targets, but gate B capture is L1 through an injected source.
- **Why it matters:** a gate B record could show "passed" for behavior never observed on the real platform. That contradicts the N2 and Z5 resolutions.
- **Suggestion:** split each proof by gate:
  - **PROOF-006:** L1 with the scripted approver in gate B; L2 with the release-signed CLI in gate C.
  - **PROOF-008:** policy, coalescing, backpressure and identity at L1 in gate B; real gap detection, self-copy and latency at L2–L3 in gate C.

  Alternatively, fold the L2 halves into PROOF-011 and PROOF-012.

### 🟡 F4. Gate C runs on real data, but invariant 10's capture-side limits arrive only in gate D (§7 lines 845–846, line 103, §4.14 lines 705–715)
- **What's wrong:** the capture-side limits are size per representation and per capture, flood, slow promise, disk floor, and client flood. They sit on the capture path, but gate D delivers "limits and the abuse suite" as one block. So the daily-use month in gate C runs with no per-capture cap.
- **Suggestion:**
  - Move the capture and IPC limits to gate B or C. Keep processor eligibility, quarantine and the full abuse suite in gate D.
  - Split PROOF-015 the same way, or test the capture-side cases inside PROOF-008.

### 🟡 F5. Image and PDF header parsing still runs in the helper, which contradicts §1.5 and D17 (§4.13 line 688, §4.14 line 712, §1.5 row 85)
- **What's wrong:** the helper reads dimensions through ImageIO properties and checks eligibility by pixel count and page count. That means parsing untrusted headers in the always-running process that holds the key. §1.5 says parsers run only in the worker, and D17 rejects parsing in the helper for exactly this reason.
- **Suggestion:**
  - Make dimensions and page counts worker outputs, and have the helper's eligibility checks use byte size and UTI only.
  - Otherwise, state the exception explicitly in §1.5 and D17.

  The first option is simpler, and it removes a framework from the helper.

### 🟢 F6. Backpressure allows two maximum-size reads (line 103, lines 485–487)
- **What's wrong:** a text change observed while a maximum-size capture is in flight still has to be read before its size is known. So the peak memory is two reads, not one.
- **Suggestion:**
  - Either cap the size of text read while a capture is in flight and state the peak as two reads, or don't read at all while a capture is in flight.
  - Separately, tag line 717 ("macOS doesn't expose the size before it's read") with PROOF-001, since step 7 is still testing it.

### 🟢 F7. The `metadata` scope conflicts with CLI contract rule 4 (line 594 vs. line 645)
- **What's wrong:** rule 4 says `list` and `search` always return a `preview`, but the `metadata` scope forbids previews.
- **Suggestion:** add "in `read` scope; omitted under `metadata`" to rule 4. The scope itself is settled.

### 🟢 F8. The audit schema doesn't match what is audited (line 290 vs. line 671; invariant 5)
- **What's wrong:**
  - The audit table has one `content_item_id` column, but list and search return many item ids per request.
  - The "bounded time" purge promise in invariant 5 has no stated bound.
- **Suggestion:**
  - For the schema, either audit only single-item commands by id and log counts for list and search, or add a child table.
  - Put the purge bound in `MuninnLimits`.
  - Consider FTS5's own `secure-delete` option, which removes the dependency on idle-time index merges.

### 🟢 F9. Status and reference drift across the three docs
- `Package.swift` line 6 says `.macOS(.v13)`, but D5 says 27. Fix it, or note it as a gate B task.
- D3 is listed as Accepted (line 26) and also under "Waiting on proofs" (line 12).
- §4.16 marks `SMAppService.agent` (line 782) and the data-protection keychain (line 774) as `use`. Under the legend they are `proof`, because D38 and D3 depend on PROOF-001 and PROOF-003.
- The §4 diagram (line 166) says "pending PROOF-003". It should be D38 (PROOF-001 + PROOF-003).
- The §4.1 dependency rules (line 217) don't cover the D23 fallback, where the app would need `MuninnCapture`.

### 🟢 F10. Protected items: v2 builds the mechanism, but D12 is still open (line 652, D12, PROOF-006)
- **What's wrong:** gate B builds and tests the exclusion, but the trigger that makes an item protected is undecided. The per-request approval read also has no command, no flag, and no way for a caller to learn the id of an item it can't see.
- **Suggestion:** settle D12 before gate B. In v2, make protected items readable only in the app (CLI: excluded, with no exceptions).

## Altitude

The doc is about right at about 877 lines, and the resolution rule held. Three things could still move out:
- **§4.2 "Swift conventions" (lines 243–252)** is code-level rules. Move them to `AGENTS.md`, and keep goal 7 and the isolation table.
- **§4.11's `doctor` checks (lines 614–624) and the full exit-code table (lines 580–591)** duplicate the generated reference that line 571 calls authoritative.
- **§4.16's "What we use" table (lines 772–794)** is where the F9 drift lives. Keep only rows with status `proof` or `no`, plus the rows a reader could get wrong.

These are missing and need about one line each: F1 (the rule for choosing the primary), F2 (dev-build variants of the key and transport), and F4 (which gate delivers the capture-side limits). Nothing that was cut needs to come back.

**Not re-argued (settled):** the `metadata` scope, S7-42, alternatives in `decisions.md`, `transform` deferred, R-C2 and R-C5 deferred.

## Maintainer classification (round 2)

*(To fill in.)*

| ID | Class | Resolution |
|---|---|---|
| F1–F10, altitude moves | | |
