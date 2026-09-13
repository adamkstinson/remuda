---
name: plan-work-item
description: Write a plan for a work item at first pickup, as a comment — the Project Agent's proposal for how to execute the task, concrete enough that a later session can resume from it cold. If the item is too vague to plan, the comment is clarifying questions instead. Loaded by execute-work when the Start trigger fires and no plan comment exists — planning happens at start-of-execution, never on Backlog items, because planning unchosen work is working unchosen work.
---

owner: Project Agent · used by: execute-work (Start trigger, no plan exists) · requires: Plane read (work items, comments), Plane write (comments only) · last reviewed: 2026-08-19 · review interval: quarterly

## The steps

1. **Read the work item** — challenge, acceptance criteria, constraints, description. Understand what must be produced before proposing how. The plan says *how*; a plan that just rewords the criteria is not one.

2. **Cold-reader test.** If you cannot state from the record alone what a successful outcome looks like, do not plan — write a comment asking specific questions (never a bare "please clarify"). A plan built on unclear criteria is guessing.

3. **Check dependencies first.** Plane relations (blocked_by), parent/child, and any external conditions in the description. An unmet dependency makes "wait for X" step 1 of the plan — or, if nothing can proceed at all, load `escalate-blocker` instead.

4. **Write the plan as a comment** via `plane_create_comment`:

   ```
   Plan for this work item:

   1. [First step] — what, how, expected output
   2. [Second step] — what, how, expected output
   n. [Final step] — deliverable and evidence format

   Dependencies: [what must be true before starting, if anything]
   Expected number of steps: [N]
   Next action: [step 1, with what to do first]
   ```

   Every step is a single action with a clear artifact or output. The final step names the evidence format the completion report will cite.

5. **Too large?** State it in the plan comment and propose where the split should occur — the Ops Agent performs splits; you never do.

6. **Reference the plan comment id in your reply** — execute-work checks for it at every pickup.

## What good looks like

- The plan is concrete enough that a later session executes step 1 without your context.
- Dependencies are stated explicitly — nothing is assumed ready.
- The plan went in a comment, never a work item edit.

## When to stop and ask

- Too vague for even one concrete step → ask, with specific questions.
- A step needs a tool or access you don't have → state the gap in the plan comment.
- The plan reveals a scope, cost, or commitment issue → `escalate-blocker`.
