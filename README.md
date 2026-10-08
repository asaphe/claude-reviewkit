# claude-reviewkit

Portable, evidence-based PR review for any repo — a Claude Code plugin. Two-pass scan-then-verify methodology, calibrated severity, mandatory adversarial pass, and a dedicated security lens — no ticket-system integration, no assumed CODEOWNERS structure, no cloud-provider-specific coupling.

## Install

```
/plugin marketplace add asaphe/claude-reviewkit
/plugin install reviewkit@claude-reviewkit
```

## Usage

- `/reviewkit:review [PR#]` — two-pass review. Dispatches two bundled reviewer personas in parallel (`security-lens`, `systemic-patterns-lens`), verifies every finding with an Evidence block before it's presented, runs a mandatory adversarial pass, and optionally posts to the PR. On a re-review it re-checks each earlier finding at the new head and scopes the new pass to what changed since.
- `/reviewkit:finalize [PR#]` — squash noisy history, rewrite the PR body to reflect final state, sweep and report on open comments, check for doc gaps.

## Re-reviews, feedback and CI

- **Re-review continuity.** Each earlier review shows the commit it was submitted against. A re-review diffs from that commit to the new head and gives every earlier finding one status: fixed, still open, regressed or disproved. The status comes from re-running the check, never from the author's reply. Only a new head earns a re-review; CI finishing or an edited description does not.
- **Full feedback inventory.** `scripts/pr-comment-state.sh` sweeps conversation comments, review bodies and inline threads (replies included), fully paginated. Bot and human authors are labelled, and comment bodies and every other rendered field are scrubbed of invisible and bidi characters. `--full` prints every item untruncated, resolved, dismissed and minimized ones included, so a claim is judged on its whole text.
- **CI verdict.** `scripts/pr-ci-verdict.sh` reads the head's `statusCheckRollup` and checks it against the required contexts from rulesets and classic branch protection. It returns GREEN, RED, INCOMPLETE or RED-ADVISORY. A pending check, an unreported required check, or a required check that was skipped is never green, and neither is a run where every check skipped, a head that moved after review, a required check pinned to an app whose latest status another source holds (a user's token or another app; GitHub refuses the merge then) or a source the script cannot attribute (a private app's bot, a deleted account), or a base whose ruleset requires workflows, code scanning, code quality, code coverage, license compliance or deployments, or whose classic protection requires deployments, none of which names a check. Only a repo admin can read the classic deployment setting; without that access it counts as possibly set unless the merge box reports the PR as mergeable. GitHub keeps only the latest attempt of each workflow run in the rollup, so a re-run replaces its failed attempt; same-named entries from separate runs count worst-of.
- **Review the solution.** Each reviewer returns a result for four dimensions: correctness and security, naming and organization, simplicity and efficiency, reuse and conventions. A dimension with no result counts as not covered, not as clean.

## Why this exists

Evidence-based PR review — findings that must survive an independent verification pass, calibrated severity, a mandatory adversarial "what did I miss" pass — works as a standalone methodology with zero repo-specific coupling: no ticket-system integration, no assumed CODEOWNERS structure, no cloud-provider-specific checks baked into the reviewer personas. It should behave the same in any repo.

## Reviewer personas

- **`security-lens`** — supply chain / dependency-audit gaps, CI script injection, cross-language application security (SQL/command injection, SSRF, path traversal, insecure deserialization, hardcoded credentials), auth/authz gaps, and secret/redaction-specific concerns (test-fixture credential scanning, boundary-condition coverage in pattern-matching logic).
- **`systemic-patterns-lens`** — 10 language-agnostic bug shapes that look idiomatic at a glance: shell stream redirection order, the same risky pattern repeated across files, division-by-zero on unguarded input, null-unsafe datetime parsing, producer/consumer regex mismatch, idempotency gaps, `sys.exit(string)`-family traps, redundant work in hot paths, a test-coverage gap on a file whose tested siblings handle similarly risky data, and handler output written to a channel the host discards.

Both run on every review, always in parallel, each independently verifying its own findings before either is trusted.

## Review state and finding grades

The review state is a merge authorization, not a tone. `APPROVE` means you would accept the change merging exactly as-is; anything you want done is `REQUEST_CHANGES`, or `COMMENT` where the point is informational. "Approve with comments" is not a forge state, and mapping it to approve-plus-a-body is how a review that wants changes clears the gate.

Findings are graded on six internal categories — BLOCKING, ISSUE, GAP, WARNING, SUGGESTION, NIT — and posted as three. `GAP` (work the change implies but did not do) and `WARNING` (an operational consequence with nothing to fix) exist because without them, missing work falls to NIT, reads as cosmetic, and gets skipped.

## Optional: `intent-router` integration

If you already have an `intent-router`-style plugin installed that supports configurable skill routing, you can point it at this plugin's skills instead of leaving it to guess. For example, add to `~/.claude/intent-router.config.json`:

```json
{
  "pr_review_skill": "reviewkit:review",
  "pr_finalize_skill": "reviewkit:finalize"
}
```

This is entirely optional and one-directional — `reviewkit` has no dependency on `intent-router` and works identically with or without it installed.

## Contributing

Validate the manifest locally before pushing:

```
claude plugin validate .
```
