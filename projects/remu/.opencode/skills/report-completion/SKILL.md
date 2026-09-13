---
name: report-completion
description: The done handoff — self-verify against every acceptance criterion, write a completion comment with checkable evidence, then move the item to Ready For Review for the Ops Agent to verify and close. The comment always precedes the transition, and the Project Agent never sets Done. Loaded by execute-work when a session ends with every Requirement passing.
---

owner: Project Agent · used by: execute-work (done outcome) · requires: Plane read (work items, comments, states), Plane write (comments; the In Progress → Ready For Review transition) · last reviewed: 2026-08-19 · review interval: quarterly

## The steps

1. **Self-verify against the acceptance criteria.** Read each criterion and check it against the artifact you actually produced — Ops will check again, and a gap you gloss over here costs a round trip. "All criteria met" without what was checked and how is a skipped self-check.

2. **Any criterion fails → do not report.** Resume `execute-work` and fix it. Three of four criteria is not done.

3. **Write the completion comment** via `plane_create_comment`:

   ```
   Completion report

   What was delivered: [one sentence]
   Evidence:
   - [repo-relative path + commit hash, URL, or record id]
   - [second artifact if applicable]

   Acceptance criteria self-check:
   - Criterion 1: [pass/fail] — [what you checked]
   - Criterion 2: [pass/fail] — [what you checked]

   Ops Agent: please verify against the criteria and close.
   ```

   Evidence is checkable by a stranger — a repo-relative path plus commit hash, a URL, or a record id, never a description. "Tested and working" is not evidence; the test results' path is. The explicit "please verify" handoff line is not optional.

4. **An ambiguous criterion gets flagged, not glossed**: "Criterion 3 is unclear — my interpretation was X. Please confirm this is what was intended."

5. **Then — and only after the comment is on the record — move the item to Ready For Review.** Resolve the Ready For Review state UUID by name via `plane_list_states`, set it with `plane_update_work_item`, and re-read to confirm it stuck. This is one of your two permitted transitions; it is the claim Ops verifies. You never set Done or anything else — Ops closes after verification, or sends the item back to In Progress with a comment naming what falls short.

## What good looks like

- Every criterion is addressed in the self-check, each with what was checked.
- The completion comment alone is the definitive record of what was delivered — a stranger can verify it end to end.
- The comment's timestamp precedes the transition, every time.

## When to stop and ask

- A criterion cannot be verified because the artifact is unreachable → report the gap in the comment; never claim it on trust.
- A criterion appears written for a different deliverable → flag it in the comment.
- The deliverable is client-facing → note explicitly that it needs Adam's approval before anything reaches the client; delivery to the client is never yours.
