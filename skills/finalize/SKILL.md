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
- Check CI status via the check-runs rollup, not `gh pr checks` — that command renders only the checks that have *reported*, so a job still queued is absent from the table rather than listed as pending, and a partial run reads as a complete green one:

  ```bash
  gh pr view "$PR_NUMBER" --repo "$REPO" --json statusCheckRollup \
    --jq '.statusCheckRollup[] | "\(.name // .context): \(.status // "COMPLETED")/\(if (.conclusion // .state // "") == "" then "PENDING" else (.conclusion // .state) end)"'
  ```

  Classify every row into one of six buckets — success, failure, cancelled, skipped, pending, and *not reported at all* — and confirm each required context by name against branch protection (`gh api "repos/$REPO/branches/main/protection" --jq '.required_status_checks.contexts[]'`). A required context missing from the rollup is pending, never passing. Flag failures and pending checks but continue — this skill doesn't fix CI.

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
10. Verify the push landed before cleaning up: `git ls-remote origin <branch>` must equal local `HEAD`. Never infer success from the command's own output — a rejected push still prints to the remote's URL, and a trailing `&& echo pushed` in a compound command reports success the push never had.
11. Delete the backup branch only after that check passes.

If the push is rejected, **stop — do not escalate to `--force`.** The lease already permits the rewrite, so a rejection means something other than staleness refused it, and forcing past an unknown refusal on a shared branch is precisely what the lease exists to prevent. Distinguish the two cases:

- **`stale info` / lease mismatch** — someone else pushed. Re-fetch, rebase onto the new tip, and restart the protocol from step 2. Never re-run with a refreshed lease without first reading what landed.
- **`non-fast-forward` while the lease SHA still matches the remote** — the client was willing (confirm with `git push --dry-run`, which reports `forced update`) and the remote refused anyway. Check for a ruleset carrying `non_fast_forward` (`gh api repos/{owner}/{repo}/rules/branches/{branch}`), a `pre-receive` hook, or org-inherited rules (`?includes_parents=true`). If nothing explains it, **abandon the squash** — restore with `git reset --hard <branch>-backup`, confirm local now equals the remote, and report the anomaly. A tidy history is not worth an unexplained divergence between local and remote.

Squashing is a convenience, not a merge requirement. A branch that keeps two honest commits is a fine outcome; a branch whose local and remote disagree is not.

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
