# Reviews

Records of design reviews: findings from fresh-context (Goldfish) reviewers, and how each was resolved.

**One file or folder per review.** EGM writes its output to `docs/reviews/egm-YYYY-MM-DD/` (e.g. `zoom_out_report.md`), and we keep it as is. Hand-written reviews use `YYYY-MM-DD-<scope>.md`. Either way, the maintainer's classification is appended to the report itself.

Each file contains:
1. **Scope and inputs:** the document and revision reviewed, which source material reviewers received, and what they did **not** receive (e.g. "no design conversation").
2. **Isolation check:** how we confirmed reviewers had fresh context, and what they inherited (e.g. `AGENTS.md`).
3. **Findings**, each classified by the maintainer:

| Class | Meaning | Goes to |
|---|---|---|
| **Valid** | Real gap; fix the design | `docs/designs/` + `docs/decisions.md` |
| **Needs proof** | Can't be settled by argument | a PROOF entry in `docs/proofs.md` |
| **Disputed** | Rejected, with the reason recorded | stays here |
| **Deferred** | Valid but not now | `docs/decisions.md` (Deferred) |

A review **raises questions**. It never closes them; only a decision or executed evidence does.
