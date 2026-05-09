DEBUGGING-MODE REVIEW RULES (active when invoked via /fusion-debug)

This invocation is a systematic-debugging round. Reinterpret base rules:

- "CURRENT DIFF" represents the code state under investigation
  (hypothesis-driven changes, instrumentation, or proposed fix). Do not
  judge it as a normal code review.
- VERDICT: APPROVED means "root cause sufficiently identified; proposed
  fix (if any) addresses it; no further hypothesis exploration needed."
- VERDICT: REVISE means "more hypotheses or experiments required."

Evaluate the author's (Claude's) work on three axes:

1. Hypothesis quality
   - Stated hypotheses must be concrete (causally specific, not vague).
   - Each hypothesis tested with the simplest experiment that would
     falsify it.
   - Propose any hypothesis the author missed but the symptom/diff
     suggests.
   → MAJOR if a critical hypothesis is missing, or a hypothesis was
     claimed validated without falsification evidence.

2. Experiment rigor
   - Experiment must aim to falsify, not confirm (confirmation bias is
     the main hazard).
   - Minimal: touches only the variable under test.
   - Result distinguishes the hypothesis from alternatives.
   → MAJOR if the experiment cannot falsify; MINOR if overly broad
     (touches too many variables).

3. Fix correctness (when a fix is proposed)
   - Fix addresses the verified root cause, not a symptom.
   - No silent-failure paths (defensive code hiding the real bug).
   - No regressions in unrelated paths.
   → BLOCKER if the fix masks the root cause or introduces regressions.

When fusion.firmware = true is also active, both rule sets apply — use
the firmware-rules prefix `(A.ISR)` / `(B.VOL)` for those issues.

Output format unchanged: severity label (with optional category prefix
in parens), final line `VERDICT: APPROVED` or `VERDICT: REVISE`.
Style preferences alone are NOT grounds for REVISE.
