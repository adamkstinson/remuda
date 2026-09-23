# Remuda

Rails for agent harnesses. A Ruby gem that builds, runs, and maintains agent directories: the CLI, the workflow runner, the scheduler, and the Docker sandbox that runs Pi.

## How work reaches you

You are this repository’s coding agent. A scheduled workflow reads GitHub and starts you with one situation: implement an issue, continue a draft pull request, fix failing checks, or answer review. The prompt names the issue, the pull request, and the branch. The branch is already checked out.

Adam hands an issue to you by adding the `agent` label. Work on what the prompt names.

## The loop

1. Read the issue: Goal, Context, Requirements. If you cannot tell what done looks like, ask on the issue and stop.
2. Write a failing test for a requirement, then the code that passes it. Repeat for each requirement.
3. Commit in small steps. At the first commit, push and open a draft pull request with `Fixes #<issue>` in the body (the `pull-request` skill).
4. When every requirement holds and the proof command below is green, mark the pull request ready and request Adam’s review.
5. Review arrives on the pull request. Check each point against the code, then fix it on the same branch or answer with your reasoning.

The workflow merges after Adam approves and checks are green.

## Rules

- The default branch moves only through a merged pull request. Commit on the branch you were given.
- Push new commits. Pushed history stays as it is.
- End every commit message with `Co-Authored-By: Coding Agent <coding-agent@darkhorse.so>`.
- End every comment and pull request body you write with `<!-- coding-agent -->`. The workflow uses it to tell your writing from Adam’s.
- You work alone in the session. Where a skill says to ask your human partner, comment on the pull request (or on the issue, before a pull request exists) and stop.
- When only Adam can unblock you (access, a decision, a secret), comment what you need and stop. If you already asked and nothing has changed, comment `Parked: <reason>` once and stop. The workflow skips the issue until Adam replies.
- Your scope is this repository and the issue in front of you. CI, branch protection, and secrets change only when the issue asks for it.
- A defect you find outside the issue becomes a new issue, without the `agent` label.
- Write commit messages and pull request titles in the style of `git log --oneline -20`.

## Skills

Skills live in `.agents/skills/`. Load the one that matches what you are doing.

| Skill | When |
|---|---|
| `test-driven-development` | Before writing production code |
| `systematic-debugging` | A test fails, a check fails, or behavior surprises you |
| `verification-before-completion` | Before saying anything passes, and before marking a pull request ready |
| `receiving-code-review` | Review comments arrived |
| `pull-request` | Pushing, opening or updating the pull request, reading checks and review threads |

## Proof command

```bash
bundle exec rake test
```

## This product

- Ruby 3.2 or later. ActiveRecord on SQLite, `docker-api`, `fugit`, Minitest.
- `design/` is the spec. Its settled decisions hold. A change that alters one updates that file in the same pull request.
- `README.md` documents the CLI. A change to a command updates it in the same pull request.
- `projects/` holds Plane project-agent brains on disk. It is gitignored and outside your work.
- The version and the built `.gem` files change when the issue asks for a release.
