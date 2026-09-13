---
name: escalate-blocker
description: Escalate a blocked work item — write a comment naming the blocker, what would clear it, and who must act, as the signal for the Ops Agent to route. Use when a work item cannot proceed — a dependency not ready, missing tool or access, anything needing the client or another external party, work exceeding the agent's authority (scope, money, outbound communication), a broken plan, or an item that cannot be made true.
---

owner: Project Agent · used by: execute-work (blocked outcome) · requires: Plane read (work items, comments), Plane write (comments only) · last reviewed: 2026-08-19 · review interval: quarterly

## The steps

1. **Verify the blocker is real.** Check Plane relations, the plan, recent comments, and the item's constraints. A transient condition — a temporarily failing build, a flaky service — is a failed step to report in `execute-work`'s progress comment, not a blocker. And never escalate an item you never attempted without saying why: "Cannot plan: the acceptance criteria are too vague."

2. **Name the type**: dependency · access · scope · **needs-the-client** · broken plan · unexecutable. Needs-the-client covers anything requiring someone outside the company to answer, provide, or receive something — you never contact them yourself; Ops routes communication work up, and it reaches the Assistant Agent (the only agent trusted with outbound) if Adam agrees. Include a draft of what needs saying if you have one — drafting is yours, sending is not.

3. **Write the escalation comment** via `plane_create_comment`:

   ```
   Escalation — [blocker type]

   What is blocked: [which step, or the entire work item]
   Why: [the specific condition preventing progress]
   What would clear it: [the specific action, decision, or access needed]
   Who must act: [Ops Agent / Adam / Assistant Agent via Ops]

   This item cannot proceed until this is resolved.
   ```

   Specific enough that someone can read it and clear it — "Docker daemon not reachable on the build server", never "blocked on infrastructure". A blocker you caused (a tool gap, a mistake) is stated honestly, not obscured.

4. **One blocker per comment**, unless several share one root cause.

5. **Repeat escalation?** Re-verify it still holds, then reference the previous escalation comment: "This is the N-th time this blocker has been reported. It remains unresolved."

6. **A blocked item writes no state** — it stays In Progress (or To Do, if it never legally started); there is no Blocked state. The comment is the signal; Ops triages and, if the wait is on Adam, turns the decision into its own `blocked_by`-linked work item.

## What good looks like

- Every blocker names exactly one thing that is wrong and one thing that would fix it, actionable by its reader.
- Repeat blockers cite the previous escalation and its duration.
- No work item sits silently blocked between runs.

## When to stop and ask

- The blocker is Adam's decision alone — scope, money, external commitment → note "requires Adam's judgment" in the comment.
- The blocker is unclear even to you → comment asking Ops to help diagnose.
- The work item fundamentally cannot be made true → comment recommending it be stopped or restructured.
