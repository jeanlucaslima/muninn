# Muninn v2 — Proofs

Companion to `docs/designs/muninn-v2.md` and `docs/decisions.md`.

We **prove architectural assumptions before committing to them**. A proof is a small, executable experiment that could *disprove* an assumption. Its result is evidence, kept in the repository. We don't try to formally prove the whole application.

Every architectural assumption answers three questions:
1. **What are we assuming?**
2. **What is the smallest experiment that could disprove it?**
3. **What evidence is enough to accept it?**

The cycle is *hypothesis → proof → evidence → decision*, repeated until the architecture is validated.

---

## Rules

1. **A proof passes only on executed evidence.** Writing a test is not evidence. Running it and keeping the actual output is. The agent or person running a proof must execute it and commit the raw results. Never mark a proof *Passed* from reasoning, from code alone, or from an expected result.
2. **Evidence is kept raw.** Each run writes to `docs/evidence/PROOF-NNN/<date>/`:
   - `environment.txt`: macOS version and build, hardware, Xcode/Swift version, git commit, signing identity (dev or release)
   - the exact commands run
   - raw output: logs, benchmark JSON, screenshots of system alerts or settings panes when the claim is about UI the system shows
   - `summary.md`: observed vs. expected
3. **The claim matches the evidence level** (below). A unit test doesn't prove that macOS code signing works, and a benchmark doesn't prove security. Each proof states which level it provides.
4. **Proofs never touch real user data.** They use disposable data directories, synthetic corpora, a *copy* of a v1 DB, and a separate macOS user account where system state (permissions, Keychain) would otherwise be polluted.
5. **Spikes are throwaway.** Proof code lives in `spikes/PROOF-NNN/` and is not production code. Production code is written afterwards, justified by the proof.
6. **Failure is a result.** A *Failed* or *Inconclusive* proof updates `docs/designs/muninn-v2.md` and `decisions.md` before anyone builds past it.
7. **Re-run on change.** A proof is re-run when what it depends on changes: macOS major version, SQLCipher version, signing setup. The register records when it last passed.

### Evidence levels

| Level | Kind | Demonstrates | Example |
|---|---|---|---|
| **L1** | Behavioral | A component does what it claims: unit, contract and property tests (seeded generators) | `acao` finds `ação`; deleting an item removes its index rows |
| **L2** | Integration and security | Real macOS processes and APIs, **including failure paths**; signing-dependent claims need **release-signed** binaries | An unsigned process can't read history; a scripted signed CLI can't bypass protected-item approval |
| **L3** | Operational | Realistic workloads: latency, resources, recovery over time | 100k items stay searchable and the helper's memory doesn't grow over time |

### On formal methods

We don't use a theorem prover for the system. It can't prove how macOS pasteboard permissions, the Keychain or memory budgets behave; executable proofs, property-based tests, fault injection, integration tests and benchmarks do that. A narrow formal model could be worth it later for a subtle state machine (migration, session/grant transitions), but only with evidence of a real correctness problem there.

### Statuses

**Proposed** → **Running** → **Passed** · **Failed** · **Inconclusive**. Also **Deferred**, and **Stale** (passed, but something it depends on has since changed).

---

## Register

| ID | Claim | Level | Gate | Decides | Status |
|---|---|---|---|---|---|
| PROOF-001 | **Layout matrix (with PROOF-003):** pasteboard access and onboarding for a signed app and helper; helper location × reader process × worker launch × Keychain group × referenced-file access; peak memory of large pasteboard reads; all on the minimum OS | L2 | A | D23, D38, §4.16 | Proposed |
| PROOF-002 | Caller identity over XPC (signed app and CLI accepted, everything else rejected); session binding to the terminal's session leader, including tty reuse and no-terminal callers; every §4.6 transport requirement met | L2 | A | D21, D33, §4.6, §4.12 | Proposed |
| PROOF-003 | Keychain: private access group for a Developer ID helper (bare vs. bundled); `AfterFirstUnlock` vs. `WhenUnlocked` across lock, restart and missing keys; lock signals for an agent; the helper can launch the embedded sandboxed worker in each packaging variant | L2 | A | D3, D38, §4.4 | Proposed |
| PROOF-004 | SQLCipher + FTS5 from the exact package: encrypted, no plaintext artifacts; **trigram-only baseline first**, two indexes only if it fails relevance; latency and size at 100k | L1–L3 | A | D2, D16, D35, §4.7 | Proposed |
| PROOF-005 | Chunked assets inside SQLCipher against a **sizing target** (light, typical and heavy users at 1 and 3 years): DB size, latency, WAL behavior, vacuum, backup and Time Machine cost, chunk size | L3 | B | D15, D34 | Proposed |
| PROOF-006 | Access policy against a scripted signed CLI: every scope × command, `metadata` refuses text queries, protected items excluded without leaking counts, session binding (reused tty, no terminal), lock | L2 | B | §4.12, D36, D39 | Proposed |
| PROOF-007 | `--all` streams are consistent under concurrent captures, deletions and reprocessing, and a stalled reader is cut off by the stream deadline before the WAL grows unbounded | L1–L2 | B | §4.7 | Proposed |
| PROOF-008 | Capture guarantees: gap detection (excluding self-writes), coalescing, backpressure bounds, self-copy recorded once, identity for omitted representations (never merged), capture-path targets, capture-to-searchable time | L2–L3 | B | §4.3, §4.8, D6, D30 | Proposed |
| PROOF-009 | Helper memory baseline and scale independence (100 vs. 100k items) | L3 | B | §4.13 budgets | Proposed |
| PROOF-010 | Migration of a **copy** of a real v1 DB: text identity recomputed, non-text rows never merged, timestamps and pins preserved, DBs without `schema_version` detected; failure leaves v1 untouched | L2 | C | §5 | Proposed |
| PROOF-011 | Lock behavior on a release-signed build: no data served while locked, sessions ended, clean resume; with `WhenUnlocked` (if adopted), no orphan path on a locked restart | L2 | C | §4.4 | Proposed |
| PROOF-012 | Restart and crash recovery: helper killed at every capture step; no lost or duplicated history; assets complete or absent, never partial | L2 | C | §4.3, §4.8 | Proposed |
| PROOF-013 | Worker isolation: deliberately crashing OCR/PDF/HTML jobs; the helper survives, jobs are recoverable or quarantined, memory returns; an HTML-to-text extractor that works in the sandbox | L2–L3 | D | D17 | Proposed |
| PROOF-014 | Processing idempotency under fault injection | L1–L2 | D | §4.8 | Proposed |
| PROOF-015 | Abuse suite: clipboard flood and repeat flood (both attribution modes), 2 GB text, 500 MB TIFF, 50k×50k PNG, 20k-page PDF, deeply nested HTML, 100k-file Finder copy, a slow promise provider, full disk, IPC connection/request floods and slow readers while the panel stays responsive | L2–L3 | D | §4.14 | Proposed |
| PROOF-016 | 30-day memory soak: no upward trend in idle footprint | L3 | D | §4.13 | Proposed |
| PROOF-017 | Secure Enclave wrapping: real benefit and unattended unlock | L2 | — | D22 | Deferred |

---

## Gate A — platform feasibility

Gate A proofs share one rule: they run on the **minimum OS** (D5), in a **separate macOS user account** where permission or Keychain state would otherwise be polluted, and PROOF-001 and PROOF-003 are run **together as one layout matrix**, because their answers constrain each other.

### PROOF-001: Pasteboard access and the bundle layout matrix

**Hypothesis.** A signed `Muninn.app` with a helper hosted by `SMAppService.agent` can:
1. obtain **persistent** pasteboard access through a deliberate onboarding action, with a clear "Muninn" identity in the alert and System Settings
2. keep reading after app quit, helper restart, logout and reboot without new alerts
3. do so in a bundle layout that also satisfies PROOF-003 (Keychain group, worker launch)
4. read large representations with a known, acceptable memory peak

**Experiment** (`spikes/PROOF-001/`), signed with the dev Team ID, in a fresh user account so the permission starts at `.default`:
1. **Layout matrix:** helper location (bare executable in `Contents/MacOS` vs. bundled login item) × reader (helper vs. app). For each cell, record PROOF-003's Keychain result and whether the helper can launch the embedded sandboxed worker.
2. Record `accessBehavior` at each step. Click *Enable* and trigger the first read from the candidate reader. Record the alert (screenshot), the name and icon shown, and the System Settings entry.
3. Probe which calls trigger the alert, from each process: `changeCount`, `types`, `detectMetadata`, `detectPatterns`, `data(forType:)`.
4. Check whether the alert offers persistent choices, and whether a deep link to the settings pane exists.
5. Set Always Allow, then quit the app, restart the helper (`launchctl kickstart -k`), log out and in, and reboot. Record whether reading continues without alerts.
6. Read the pasteboard off the main thread in the reader.
7. **Memory peak:** copy 500 MB and 2 GB representations; record the reader's peak `phys_footprint` and whether any API reports a size before reading.
8. **Referenced files:** copy files from Desktop, Documents, Downloads, iCloud Drive and a removable volume. Record whether recording the pasteboard's URL and resource values triggers any privacy (TCC) prompt in the helper, and confirm that bookmark creation from the app on user action is attributed to the app.
9. The CLI connects to the helper over XPC and calls `hello` and `status`.

**Acceptance.**
- Permission and attribution behavior are fully explained for both reader options; D23 can be decided.
- At least one layout cell gives persistent, alert-free capture across step 5 **and** passes PROOF-003; that cell fixes D38.
- The large-read peak is measured and documented (invariant 10 states it); capture without background file access raises no TCC prompts.

**If it fails.** If no cell works with the helper as reader, the app reads (§4.16 fallback). If neither reader gets persistent access, capture becomes app-foreground-only and §1.2 goal 2 is rewritten. If the large-read peak is unacceptable, the per-capture cap in `MuninnLimits` drops, and reading in a short-lived process is reconsidered.

**Evidence required.** Screenshots of alerts and System Settings, `accessBehavior` logs per step, the per-call trigger table, the layout matrix with results, peak-memory measurements, TCC observations, environment and `codesign -dvvv` for each binary.

**Decision.** D23, D38; onboarding details in §4.16.

### PROOF-002: Caller identity, session binding, transport

**Hypothesis.** An XPC Mach service with `xpc_connection_set_peer_code_signing_requirement` accepts only the signed Muninn app and CLI, meets every transport requirement in §4.6, and lets the helper identify a CLI caller's **terminal session leader** (pid plus pid version, from the audit token), so a session can't outlive it or pass to a terminal that reuses its tty.

**Experiment** (`spikes/PROOF-002/`). The helper logs its identity decision for each client:
- the signed CLI and the signed app
- an unsigned build of the same CLI source
- a CLI ad-hoc signed with the right identifier but the wrong team
- a binary copied from the bundle and modified (broken signature)
- the signed CLI run from a terminal, from `launchd`/cron (no terminal), under `script`, and from a child process of an authorized terminal

For session binding: open a terminal, start a session, close the terminal, open new terminals until one reuses the tty, and confirm the session doesn't carry over; confirm that "terminal closed" is detected (session-leader exit).

Exercise every §4.6 requirement over XPC: version handshake, concurrent requests with cancellation, a streamed 500 MB payload, event subscription with liveness. Also try the helper verifying a LocalAuthentication result handed over by the app (D33) and record its cost.

**Acceptance.**
- Every non-Muninn client is rejected before any request is processed; signed clients are accepted.
- Session-leader identity is correct in every launch context; tty reuse never inherits a session; callers without a terminal are identified as such.
- XPC meets every §4.6 requirement.

**If it fails.** If XPC can't meet a requirement, build the Unix-socket variant for that requirement only and compare (D21). If session-leader binding is unreliable, sessions bind to a shorter-lived key (per tty and process start time) with shorter lifetimes, and §1.5 is updated.

**Evidence required.** Per-client decision log, kernel-derived session values per launch context, the tty-reuse trace, payload and cancellation measurements, signing details, release-signed run.

**Decision.** D21, D33; §4.6; session binding in §4.12.

### PROOF-003: Keychain lifecycle, lock state, worker launch

**Hypothesis.** A Developer ID helper can keep its key in the **data-protection keychain** under a **private access group**, with predictable behavior across lock, unlock, sleep, restart and missing-key cases, and can launch the embedded sandboxed worker, in at least one packaging variant.

**Experiment** (`spikes/PROOF-003/`), in a separate user account, run with PROOF-001's layout matrix:
1. Sign the helper with `keychain-access-groups`: (a) as a bare executable, (b) as a bundled login item. Record whether a provisioning profile is required and whether each variant can access the item.
2. Confirm the app, CLI and worker (without the entitlement) **can't** read the item.
3. With `AfterFirstUnlockThisDeviceOnly` **and** with `WhenUnlockedThisDeviceOnly`, read the key after login, while locked, after unlock, after sleep and wake, and after reboot before and after first unlock. Record the exact error codes.
4. Delete the item and restart the helper: the orphan path must trigger, and no new key may be written over existing data. With `WhenUnlocked`, restart the helper **while locked**: the orphan path must **not** trigger.
5. Compare candidate lock/unlock signals for a UI-less agent, including fast user switching.
6. From each packaging variant, launch the embedded sandboxed `muninn-worker` XPC service and exchange a message.

**Acceptance.**
- One packaging variant works without unacceptable provisioning constraints, or the constraint is documented and accepted.
- Accessibility classes behave as documented; at least one lock signal is reliable for the agent.
- Missing keys never cause silent history loss, and a locked restart is never mistaken for a missing key.
- The worker launches in the chosen variant.

**If it fails.** If no variant gets a private group, fall back to the legacy keychain with the item's access control limited to the helper's signature, and update §1.5. If the worker can't be launched from the helper's location, the worker moves with the helper, or the helper becomes a bundle. If no lock signal is reliable, the policy treats sleep and screen-saver start as lock.

**Evidence required.** Entitlement and provisioning details, an access matrix (process × state × accessibility class), error codes, lock-signal timing logs, orphan-path logs, worker launch logs, release-signed run.

**Decision.** D3, D38; the accessibility class and lock handling in §4.4; D22 stays deferred.

### PROOF-004: Encrypted search with SQLCipher and FTS5

**Hypothesis.** SQLCipher's official Swift package, built as Muninn builds it, gives an encrypted DB, WAL and journal, plus FTS5 with the `trigram` tokenizer, and **one trigram index** (plus a short-term fallback) meets the §4.7 relevance and latency targets at 100k items with no plaintext on disk.

**Experiment** (`spikes/PROOF-004/`):
1. Build the package (`SQLITE_HAS_CODEC`, pinned version); record `cipher_version`, `sqlite_version()` and compile options.
2. Generate the seeded 100k-item corpus (§4.7).
3. **Baseline:** one trigram index plus the fallback for terms under 3 characters. Run the relevance cases and latency suite.
4. Only for cases the baseline fails: add the `unicode61` word index with rank fusion and rerun.
5. Try the trigram options (case handling, diacritic removal) and record where `LIKE`/`GLOB` acceleration applies, per SQLite's documented restrictions.
6. Scan the DB, WAL, journal and temp directories for seeded plaintext canaries; confirm that opening without the key fails.
7. Restart and run `integrity-check`.
8. Record index size relative to text size (D16).

**Acceptance.**
- All relevance cases pass with the chosen shape; latency meets §4.7 or targets are revised with evidence.
- No canary appears in any file; integrity checks pass after restart; the license is confirmed.

**If it fails.** If the package lacks a working `trigram` tokenizer or fails the encryption checks, try building SQLCipher from the amalgamation with the needed flags (D2's earlier option). If no configuration meets relevance, revisit the query model (§4.7) before gate B.

**Evidence required.** Build configuration, benchmark JSON, relevance results per index shape, canary-scan output, size table, environment.

**Decision.** D2, D16, D35.

## Gates B–D

Entries for PROOF-005 to PROOF-017 are written out in full (hypothesis, experiment, acceptance, **if it fails**, evidence, decision) **before their gate starts**, based on what gate A taught us. Their claims are in the register above, and the related design sections already state the targets they'll be measured against.
