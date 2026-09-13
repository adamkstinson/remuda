---
name: respond-to-comments
description: Reply to comments from Adam (@dark-horse) or the Ops Agent on a work item — answer questions, acknowledge instructions, absorb clarifications, and note approvals. Comments are the collaboration surface and take priority over execution. Fired by the poll-and-execute Respond trigger (a comment on one of your open items not authored by you), and loaded by execute-work when it finds unanswered comments at pickup.
---

owner: Project Agent · used by: poll-and-execute (Respond trigger) · execute-work step 1 · requires: Plane read (work items, comments), Plane write (comments only) · last reviewed: 2026-08-19 · review interval: quarterly

## The steps

1. **Read all comments first** via `plane_list_work_item_comments` — never reply to one before seeing the whole thread. Identify every comment from Adam or the Ops Agent you have not yet answered.

2. **Classify each**: a question, an instruction, a clarification, or an approval.

3. **Reply via `plane_create_comment`**, one reply covering the thread:

   ```
   Re: [what is being answered]

   [Question →] the direct answer — answer first, then ask anything of your own
   [Instruction →] acknowledged: what you will do, and when
   [Clarification →] confirmed: your restated understanding
   [Approval →] noted: the decision, and that you are proceeding
   ```

   Answer the actual question — never reframe it, and never respond to a question with a different question.

4. **If the comment changes the task** — "do this differently", "stop this" — adjust your plan and write a follow-up comment noting the change, so the plan on the record matches what you will now do.

5. **Never change state or fields in response to a comment.** If a comment requires a state change, say so in your reply and let Ops make it.

6. **Close the loop.** When a conversation is complete, note in your final reply that the thread is resolved.

## What good looks like

- Every comment from Adam or Ops is replied to within one poll-and-execute run — the thread shows engagement, not silence.
- Instructions are acknowledged with concrete next steps, not a bare "will do".
- Only comments were written; no state moved because a comment implied it.

## When to stop and ask

- A comment asks for something outside your authority — scope change, money, anything outbound to the client or another external party → `escalate-blocker`; outbound communication is never yours.
- A comment is ambiguous and you cannot determine what is being asked → reply asking for clarification, specifically.
