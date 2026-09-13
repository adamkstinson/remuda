---
name: execute-work
description: Start or continue a work item and execute toward a natural stopping point — done, blocked, or a genuine pause — documenting the session in one progress comment. Fired by the Start trigger (a To Do item of yours with no open blockers) and the Continue trigger (an item of yours in In Progress). Owns the agent's two state transitions, each behind its gate.
---

owner: Project Agent · used by: poll-and-execute (Start and Continue triggers) · requires: Plane read (work items, comments, relations, states), Plane write (comments; the two gated transitions), any tools the task delegates · last reviewed: 2026-08-19 · review interval: quarterly

## The steps

1. **Read the full record**: `plane_retrieve_work_item` (title, description, Requirements, state), `plane_list_work_item_comments`, `list_work_item_relations`. The workflow's snapshot may be stale — every gate below is re-verified from this fresh read. Any comment from Adam or Ops you have not answered → handle it per `respond-to-comments` before working; it may override everything below.

2. **Starting (item in To Do)** — re-verify the gate yourself, then transition:
   - Every `blocked_by` target in a completed or cancelled group. **That is the whole gate** — you are an agent, so there is no date window and no capacity limit; a `start_date` is not required and usually will not exist (Adam's ruling, 2026-08-22). Sequencing is the only constraint. An open blocker → the blocked outcome below; never start around it. Among several startable items, take priority order, then earliest target date.
   - No plan comment exists → load `plan-work-item` first.
   - Write a starting comment (which plan step you are picking up), then move **To Do → In Progress**: resolve the In Progress state UUID via `plane_list_states`, `plane_update_work_item`, re-read to confirm it stuck.

3. **Continuing (item in In Progress)**: re-read the plan comment — the comment conversation may have changed it — and find the next step not yet done.

4. **Execute toward a stopping point.** Work the plan — commands, files, builds, research — inside this workspace's deliverable repos, committing as you go with a `Co-Authored-By` trailer. Keep going until the item is done, blocked, or you reach a genuine stopping point; a session is as much work as the work allows, never one artificial step. Failures are documented, not skipped — "tried X, got Y" with a proposed correction; a *transient* failure (flaky build, brief outage) is progress to report, not a blocker. If it becomes clear the target date will be missed, say so in the comment the moment it is clear.

5. **End the session in exactly one of three ways:**
   - **Done** — every Requirement self-verifies pass → load `report-completion`: completion comment first, then the **In Progress → Ready For Review** transition.
   - **Blocked** — a real blocker (dependency, access, needs-the-client, authority, broken plan) → load `escalate-blocker`; the item stays In Progress; no state write.
   - **Progress** — anything short of those → one session progress comment via `plane_create_comment`:

   ```
   Session progress: [which plan steps this session covered]

   What I did: [specific actions taken]
   Artifacts: [repo-relative path + commit hash, URL, or record id]
   Result: [what changed, what was produced]
   Next: [the next step, and anything the next session must know]
   ```

   Artifacts are checkable references, never descriptions — a repo-relative path plus commit hash resolves for a stranger; "worked on it" resolves for no one.

## What good looks like

- Every session leaves exactly one comment with checkable artifacts and a named next step — a cold reader can resume from it.
- The only state writes are the two transitions, each verified against its gate from a fresh read and re-read after writing.
- Commits in the deliverable repos line up with the comments citing them.

## When to stop and ask

- The plan no longer fits reality → propose the correction in a comment; re-plan before executing against a stale plan.
- The step needs a tool, access, or anything from the client → `escalate-blocker`; you never contact anyone outside the company.
- The step would change project scope, terms, or commitments → `escalate-blocker`.
