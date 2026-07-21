---
name: finalize
description: >-
  Finalize a PR before merge — clean git history, update the PR body, verify
  docs. Use after code is complete and reviewed.
  Usage - /reviewkit:finalize [PR#]
user-invocable: true
allowed-tools: Bash(gh *), Bash(git *), Read, Glob, Grep, Edit, Write, AskUserQuestion
argument-hint: "[PR-number]"
---

# Finalize PR

Clean up a PR's history and description before merge. This is the last step: `/reviewkit:review` → fix findings → `/reviewkit:finalize`.

## Inputs

If `$ARGUMENTS` is provided, parse it as the PR number. Otherwise detect from the current branch:

```bash
gh pr view --json number,title,body,headRefName --jq '{number, title, body, branch: .headRefName}'
```

## Steps

### 1. Gather current state

- `git fetch origin main`, then `git diff origin/main...HEAD --stat` for the full changed-file list (use `origin/main`, not local `main`, which can lag).
- Read the PR's current body.
- Check CI status: `gh pr checks "$PR_NUMBER" --json name,state,conclusion`. Flag any failed/pending checks but continue — this skill doesn't fix CI.

### 2. Clean git history

Review `git log origin/main..HEAD --oneline`. If it's iteration noise ("fix lint", "address review", repeated fixes to the same files), squash to one logical commit. Keep multiple commits only when each is a genuinely distinct step worth preserving.

Squash protocol:

1. `git fetch origin main` — a stale `origin/main` makes the merge-base wrong and can sweep a sibling PR's commits into the squash.
2. Capture the intended file list BEFORE rewriting: `INTENDED="$(git diff origin/main...HEAD --name-only)"`. Capture the remote branch tip for the force-push lease: `git fetch origin <branch> && LEASE_SHA="$(git rev-parse origin/<branch>)"`.
3. Confirm local HEAD is not behind the remote: `git merge-base --is-ancestor origin/<branch> HEAD` must succeed. If it fails, rebase onto `origin/<branch>` first.
4. Backup: `git branch -f <branch>-backup HEAD`.
5. Reset to the merge-base, NOT `main`: `git reset --soft "$(git merge-base HEAD origin/main)"`.
6. Verify scope before committing: `git diff --cached --name-only` must equal `$INTENDED`. Mismatch → `git reset --hard <branch>-backup` and stop.
7. Commit with one conventional message (`type(scope): description`, describing what and why, not the journey).
8. Verify after: `git diff <branch>-backup HEAD` must be empty (byte-identical tree), and `git diff origin/main...HEAD --name-only` must equal `$INTENDED`. Either failure → do not push, `git reset --hard <branch>-backup`, report the unexpected diff.
9. Push: `git push --force-with-lease="<branch>:$LEASE_SHA" origin <branch>` — pin the lease to the SHA captured in step 2. Never plain `--force`.
10. Delete the backup branch after verifying the push landed.

Only ask the user when commit grouping is genuinely ambiguous (5+ commits spanning mixed concerns). This squash runs without an interactive prompt on your own PR — the compensating controls (backup branch, pre-commit scope gate, post-commit byte-identity check, SHA-pinned lease) replace the human gate. Force-pushing a branch whose PR isn't yours still requires asking first.

### 3. Update the PR body

Rewrite to reflect the **final** state of all changes, not just the last commit:

```
## Summary
- What changed and why

## Changes
- File-by-file or grouped-by-area summary

## Test plan
- [x] Verified items
- [ ] Items still pending
```

`gh pr edit <number> --body "..."`.

### 4. Review open PR comments

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/pr-comment-state.sh" "$PR_NUMBER"
```

Report — do not fix code or resolve threads here:
- How many comments total.
- How many are already addressed by the current diff.
- How many need attention (unaddressed human comments).
- How many are bot noise (candidates for cleanup).

If unaddressed comments exist, flag them and suggest running `/reviewkit:review` again (or fixing directly) before merging. A PR reaching this step with zero prior review comments isn't evidence of correctness — it may mean no one read the diff. Ask the user whether `/reviewkit:review` should run first.

### 5. Verify docs

Check whether the PR adds any new tool, API, config option, or user-facing behavior. If so, verify the relevant docs (README, examples) are updated. Report any gap.

### 6. Report

```text
PR #{pr_number} finalized:
- Git history: N commits (squashed / kept as-is)
- CI status: {summary}
- Comments: {addressed} addressed, {open} need attention, {bot} bot noise
- Doc gaps: {list or "none"}
```
