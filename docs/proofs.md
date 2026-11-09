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
| PROOF-001 | Signed app + helper can get persistent pasteboard access with clear attribution; CLI ↔ helper communication works | L2 | A | D23, onboarding (§4.16) | Proposed |
| PROOF-002 | IPC caller identity: signed app and CLI accepted, everything else rejected; terminal binding comes from the kernel; **socket vs. XPC compared on reliability and implementation cost** | L2 | A | D21, §4.6, §4.12 binding | Proposed |
| PROOF-003 | Keychain lifecycle: private access group, behavior across lock/unlock/restart, missing-key handling, lock signals for an agent | L2 | A | D3, §4.4 | Proposed |
| PROOF-004 | SQLCipher + FTS5 (word + trigram) from the exact package: encrypted, correct, fast enough at 100k | L1–L3 | A | D2, D16, §4.7 | Proposed |
| PROOF-005 | Chunked assets **inside** SQLCipher: size, latency, WAL behavior, vacuum, backup and restore cost, bounded memory, chunk size. Decides whether an external store is ever needed. | L3 | B | D15 | Proposed |
| PROOF-006 | Access policy holds against a scripted signed CLI: every scope × command, `metadata` refuses text queries, protected items excluded without leaking counts, sessions bound to a terminal | L2 | B | §4.12 | Proposed |
| PROOF-007 | `list` "as of" pagination never duplicates or skips under concurrent captures, re-captures, deletions and reprocessing; `search --all` is stable within one read transaction | L1–L2 | B | §4.7 | Proposed |
| PROOF-008 | Capture guarantees: gap detection, coalescing, backpressure bounds, self-copy recorded once, capture-path targets; cost of indexing small text inside the capture transaction | L2–L3 | B | §4.8, D30 | Proposed |
| PROOF-009 | Helper memory baseline and scale independence (100 vs. 100k items) | L3 | B | §4.13 budgets | Proposed |
| PROOF-010 | Migration of a **copy** of a real v1 DB: hashes, timestamps, pins, duplicates preserved; failure leaves v1 untouched | L2 | C | §5 | Proposed |
| PROOF-011 | Session lock: no data served while locked, sessions ended, clean resume, on a release-signed build. Key-buffer wiping is checked as defense in depth. | L2 | C | §4.4 | Proposed |
| PROOF-012 | Restart and crash recovery: helper killed at every capture step; no lost or duplicated history; assets complete or absent, never partial | L2 | C | §4.3, §4.8 | Proposed |
| PROOF-013 | Worker isolation: deliberately crashing OCR/PDF jobs; the helper survives, jobs are recoverable or quarantined, memory returns | L2–L3 | D | D17 | Proposed |
| PROOF-014 | Processing idempotency under fault injection | L1–L2 | D | §4.8 | Proposed |
| PROOF-015 | Abuse suite: floods (high- and low-confidence attribution modes), giant payloads, crafted files, IPC floods stay within limits and are labeled | L2–L3 | D | §4.14 | Proposed |
| PROOF-016 | 30-day memory soak: no upward trend in idle footprint | L3 | D | §4.13 | Proposed |
| PROOF-017 | Secure Enclave wrapping: real benefit and unattended unlock | L2 | — | D22 | Deferred |

---

## Gate A — platform feasibility

### PROOF-001: Signed app, helper and pasteboard access

**Hypothesis.** A signed `Muninn.app` with an embedded helper registered via `SMAppService.agent` can:
1. obtain **persistent** pasteboard access through a deliberate onboarding action
2. show the user a clear "Muninn" identity, both in the alert and in System Settings
3. keep reading after app quit, helper restart, logout and reboot without new alerts
4. talk to a signed CLI over the socket

**Experiment** (`spikes/PROOF-001/`). Use a minimal app, helper and CLI signed with the dev Team ID, and a **fresh macOS user account** so the permission starts at `.default`.
1. Record `accessBehavior` at each step.
2. Click *Enable* in the app and trigger the read from **the helper**. Record the alert (screenshot), the name and icon shown, and the System Settings entry.
3. Repeat with **the app** as the reader.
4. Probe which calls trigger the alert, from both processes: `changeCount`, `types`, `detectMetadata`, `detectPatterns`, `data(forType:)`.
5. Check whether the alert offers persistent choices and whether a deep link to the settings pane exists.
6. Set Always Allow, then: quit the app, `launchctl kickstart -k` the helper, log out and in, reboot. Record whether reading still works without alerts.
7. Read the pasteboard off the main thread in the helper.
8. Have the CLI send `hello` and `status` to the helper.

**Acceptance.**
- Permission and attribution behavior are **fully explained** for both reader options. That's enough to settle D23.
- At least one option gives persistent, alert-free capture across all transitions in step 6.
- Off-main reads either work or have a documented alternative.

**Evidence required.** Screenshots of the alerts and System Settings, `accessBehavior` logs per step, per-call trigger table, environment, signing details (`codesign -dvvv`).

**Decision.** Pending: D23 (helper vs. app as reader); onboarding flow details in §4.16.

### PROOF-002: IPC caller identity

**Hypothesis.** On a Unix socket, the helper can reliably tell the signed Muninn app and CLI from any other process running as the user, using peer UID and the audit token checked against a `SecCode` designated requirement. It can also read a CLI peer's controlling terminal and audit session **from the kernel**, for session binding.

**Experiment** (`spikes/PROOF-002/`). The helper accepts connections and logs its identity decision for each one. Clients:
- the signed CLI and the signed app
- an unsigned build of the same CLI source
- a CLI ad-hoc signed with the right identifier but the wrong team
- `socat` and `nc`
- a Python client
- the signed CLI run from a terminal, from `launchd`/cron, under `script`, from a child process of an authorized terminal, and with its binary copied and modified (signature broken)

Also build an **XPC Mach-service variant** using `xpc_connection_set_peer_code_signing_requirement` (D21), with the same capabilities: identity check, concurrent requests with cancellation, a streamed binary payload (and `SCM_RIGHTS` file-descriptor passing on the socket), and an event subscription. Record the **lines of code and moving parts** for each, not just whether it works.

**Acceptance.**
- Every non-Muninn client is rejected before any request is read.
- The signed clients are accepted.
- Terminal and audit-session info matches reality for every launch context, including the cases we accept as limitations (child of an authorized terminal).
- **D21 is decided on evidence:** the socket stays only if it's as reliable as XPC and its extra implementation cost is justified by concrete needs (inspectability, one wire format). Otherwise, switch to XPC.

**Evidence required.** A per-client decision log, the kernel-derived TTY/session values per launch context, signing details for each binary, release-signed run.

**Decision.** Pending: D21; §4.6 layer 3; §4.12 session binding.

### PROOF-003: Keychain lifecycle and lock state

**Hypothesis.** A Developer ID helper can store and read a key in the **data-protection keychain** under a **private access group** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), with predictable behavior across lock, unlock, sleep, restart and missing-key cases. A background agent can reliably observe screen lock and unlock.

**Experiment** (`spikes/PROOF-003/`), in a separate user account:
1. Sign the helper with the `keychain-access-groups` entitlement: (a) as a bare executable, (b) as a bundled helper app. Record whether a provisioning profile is required and whether each variant can access the item.
2. Confirm the app and CLI (without the entitlement) **can't** read the item.
3. Read the key: after login; while the screen is locked; after unlock; after sleep and wake; after reboot before and after first unlock.
4. Delete the item and restart the helper: the orphaned-DB path must trigger, and no new key may be written over existing data.
5. Compare candidate lock/unlock signals for a UI-less agent, including fast user switching.
6. Measure how long the full lock sequence takes (close DB, wipe key buffers) and confirm key buffers are zeroed (memory inspection in a debug build).

**Acceptance.**
- One packaging variant works without unacceptable provisioning constraints (or the constraint is documented and accepted in §4.1/§4.5).
- Accessibility behaves as documented; at least one lock signal is reliable for the agent.
- Missing keys never cause silent history loss.

**Evidence required.** Entitlement and provisioning details, an access matrix (process × state), lock-signal timing logs, orphan-path logs, release-signed run.

**Decision.** Pending: helper packaging (bundle vs. bare executable); §4.4 as written; D22 stays deferred.

### PROOF-004: Encrypted search with SQLCipher and FTS5

**Hypothesis.** SQLCipher's official Swift package, built in our exact configuration, provides an encrypted database, encrypted WAL and journal, and FTS5 with `unicode61 remove_diacritics 2` and `trigram`. It meets our search requirements at 100k items without plaintext artifacts on disk.

**Experiment** (`spikes/PROOF-004/`):
1. Build the package as Muninn will (`SQLITE_HAS_CODEC`, pinned version). Record `cipher_version`, `sqlite_version()` and compile options.
2. Generate the seeded 100k-item corpus (§4.7: PT/EN prose, code, URLs, UUIDs, OCR-like text, large logs).
3. Build both indexes and run the §4.7 relevance cases and latency suite.
4. Try the trigram configurations (case-sensitive or not, diacritic removal) and record where `LIKE`/`GLOB` acceleration applies, per SQLite's documented restrictions.
5. Inspect the DB, WAL and journal files and temp directories for plaintext canaries seeded in the corpus.
6. Confirm that opening without the key fails.
7. Restart and run `integrity-check` on both indexes.
8. Record index sizes relative to text size, with and without a trigram cap (D16).

**Acceptance.**
- All relevance cases pass.
- Latency meets the §4.7 targets, or the targets are revised with evidence.
- **No canary appears in any file.**
- Integrity checks pass after restart.
- The license is confirmed acceptable.

**Evidence required.** Build configuration, benchmark JSON, relevance results, canary-scan output, size table, environment.

**Decision.** Pending: D2 (package), D16 (trigram cap), tokenizer configuration in §4.7.

---

## Gates B–D

Entries for PROOF-005 to PROOF-017 are written out in full (hypothesis, experiment, acceptance, evidence, decision) **before their gate starts**, based on what gate A taught us. Their claims are in the register above, and the related design sections already state the targets they'll be measured against.
