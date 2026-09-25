---
name: pull-request
description: Use to push your branch and open or update its pull request, to mark it ready for review, to read failing checks, or to read and reply to review comments. The gh commands for each step.
---

# Pull request

The pull request is where your work is proposed, checked, and reviewed. One issue, one branch, one pull request.

Adapted from `yeet` and `gh-fix-ci` in [openai/skills](https://github.com/openai/skills) (Apache-2.0).

## Open the draft

The workflow checked out your branch, named `<issue>-<slug>`. After your first commit:

```bash
git push -u origin HEAD
gh pr view --json number,url,isDraft
```

If a pull request already exists for the branch, update that one. Otherwise open a draft:

```bash
gh pr create --draft --title "<title>" --body-file /tmp/pr-body.md
gh pr edit --add-label agent
```

- Title: what the change does, in the style of `git log --oneline -20`.
- Body: fill `.github/PULL_REQUEST_TEMPLATE.md`. `Fixes #<issue>` on the first line. Why before what. Repo-relative paths. End with `<!-- coding-agent -->`.
- Write the body to a file and pass `--body-file`, so newlines survive.

## Keep it current

After more commits, `git push`. When the net change has moved, rewrite the body to describe the diff as it now stands (`gh pr edit --body-file`). A pull request that is ready stays ready.

## Mark it ready

Only after `verification-before-completion`: each requirement checked against the tree, the proof command green, and checks green on the pull request.

```bash
gh pr checks
gh pr ready
gh pr edit --add-reviewer adamkstinson
```

Then one comment: each requirement with how you checked it, the head SHA, and the check run URL. End with `<!-- coding-agent -->`.

## Failing checks

```bash
gh pr checks --json name,state,bucket,link,workflow
gh run view <run-id> --log-failed
```

The run id is in the check’s link. Reproduce the failure locally with the matching step of the proof command, find the cause (`systematic-debugging`), fix it, push. A check from a provider other than GitHub Actions: put its URL in a comment and leave it.

## Review comments

```bash
gh pr view --json reviews,comments
gh api repos/{owner}/{repo}/pulls/<number>/comments
```

The second call returns inline threads with `path`, `line`, and `id`. Handle them with `receiving-code-review`. Reply in the thread:

```bash
gh api -X POST repos/{owner}/{repo}/pulls/<number>/comments/<id>/replies -f body='<reply> <!-- coding-agent -->'
```

Push the fixes, then one pull request comment that says what changed.
