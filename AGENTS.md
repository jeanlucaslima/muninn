# AGENTS.md

Stable conventions for any coding agent working on Muninn: Claude Code, Codex, or EGM reviewers.
This file holds **conventions only**. It deliberately contains no design rationale, so a fresh reviewer that inherits it isn't biased toward the current design.

Muninn is a pet project, but a serious one. Keep process proportional: enough rigor to trust the result, no more.

## Where things live

| Path | What |
|---|---|
| `docs/designs/muninn-v2.md` | The v2 design: what we build and why |
| `docs/decisions.md` | Decisions (D1…): accepted, revised, pending proof, open |
| `docs/proofs.md` | Proof register (PROOF-NNN) and rules |
| `docs/evidence/PROOF-NNN/<date>/` | Raw evidence from executed proofs |
| `docs/reviews/` | EGM review findings and how each was resolved |
| `spikes/` | Throwaway proof code, never production |
| `muninn.md` | The raven ASCII art. **Never modify, move or delete it.** |

## Hard rules

1. **Never touch real user data.** Don't run a v1 or v2 helper against `~/Library/Application Support/Muninn/`. Use dev builds (separate data directory), temporary directories, synthetic data, or a *copy* of a database.
2. **Evidence comes from execution.** Never mark a proof *Passed*, or claim something works, without running it and keeping the raw output. A written test is not evidence. A review is not evidence.
3. **Reviews don't replace tests or human judgment.** A reviewer saying something is safe doesn't make it safe.
4. **Decisions belong to the maintainer.** Agents propose; the maintainer accepts. Changes to `docs/designs/` and `docs/decisions.md` go in the same commit.
5. `swift build` and `swift test` must work without opening Xcode.
6. Swift 6 strict concurrency. No new `@unchecked Sendable`, `nonisolated(unsafe)`, GCD or locks outside the allow-listed C-interop files. No shared mutable singletons.
7. No new dependencies without a decision entry.
8. Commit or push only when asked.

## How much process a change needs

| Change | Required |
|---|---|
| Small bug fix | Tests |
| Localized feature | Tests, plus a focused design review if the behavior is non-obvious |
| New architectural decision | Decision entry + Goldfish review + proof |
| Security-sensitive change | Threat-model review (`docs/designs/muninn-v2.md` §1.1) + executable security tests (L2) |
| Gate milestone (A–D) | Implementation-readiness review + drift report + evidence record |

## Validation: who answers which question

| Question | Answered by |
|---|---|
| Is the design coherent and complete? | Goldfish review (`/egm:egm-review`) |
| Does the required macOS behavior work? | Executed spike (proof) |
| Are security boundaries enforced? | Integration and security tests (L2, release-signed where it matters) |
| Does it meet resource and latency targets? | Benchmarks (L3) |
| Does the code match the design? | Tests + `/egm:egm-drift-report` |
