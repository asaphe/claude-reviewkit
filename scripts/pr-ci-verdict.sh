#!/usr/bin/env bash
# CI verdict for one PR head from statusCheckRollup — `gh pr checks` lists only reported checks, so a partial run reads green.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: pr-ci-verdict.sh <PR_NUMBER> [--head <SHA>]

Read-only CI verdict for the PR's current head: every check run and commit
status in statusCheckRollup (gh paginates it), checked against the base
branch's required contexts from both rulesets and classic branch protection.

  --head <SHA>  the head you reviewed (7+ hex chars). If the PR has moved past
                it, the checks shown belong to another commit: INCOMPLETE.

Repo: $GH_REPO (owner/name) if set, else `gh repo view`.
Fails loud on any API error — never prints a verdict from a failed query.

Verdict (CI_VERDICT= line, then REASON=):
  GREEN         every reported check succeeded, and every required context
                is present and succeeded
  RED           a required context failed, was cancelled or timed out
  INCOMPLETE    anything pending; a required context not reported, or reported
                skipped/neutral (passes the gate, proves nothing ran); no checks
                at all; or a moved head
  RED-ADVISORY  only non-required checks failed; still not green

Exit codes:
  0  GREEN
  1  hard error (API failure, PR not found, repo unresolved)
  2  usage error
  3  RED, INCOMPLETE or RED-ADVISORY (stdout is valid — read CI_VERDICT)
EOF
  exit 2
}

PR_NUMBER="${1:-}"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || usage
shift
WANT_HEAD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --head) [[ $# -ge 2 && "$2" =~ ^[0-9a-fA-F]{7,40}$ ]] || usage; WANT_HEAD="$2"; shift 2 ;;
    *) usage ;;
  esac
done

# Repo derivation is detached-worktree safe — NEVER hardcode owner/name.
REPO="${GH_REPO:-}"
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner')" || {
    echo "ERROR: could not determine repo — set GH_REPO=owner/name or run inside a gh-resolvable repo." >&2
    exit 1
  }
fi

PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid,baseRefName,statusCheckRollup)" || {
  echo "ERROR: could not read PR #$PR_NUMBER in $REPO." >&2
  exit 1
}
BASE="$(jq -r '.baseRefName // empty' <<<"$PR_JSON")"
[[ -n "$BASE" ]] || { echo "ERROR: PR #$PR_NUMBER has no base branch in the response." >&2; exit 1; }

# Required contexts live in two places; a check either one requires gates the merge.
RULES="$(gh api --paginate "repos/$REPO/rules/branches/$BASE")" || {
  echo "ERROR: could not read rulesets for $REPO@$BASE — required checks unknown." >&2
  exit 1
}
CLASSIC="$(gh api "repos/$REPO/branches/$BASE")" || {
  echo "ERROR: could not read branch protection for $REPO@$BASE — required checks unknown." >&2
  exit 1
}
REQUIRED="$(jq -s --argjson classic "$CLASSIC" '
  ([ (add // [])[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context ]
   + ($classic.protection.required_status_checks.contexts // []))
  | unique' <<<"$RULES")"

RESULT="$(jq --argjson req "$REQUIRED" --arg want "$WANT_HEAD" --arg pr "$PR_NUMBER" --arg repo "$REPO" '
  # Check names come from workflow files a PR can edit: strip what reorders an agent-read render.
  def scrub(s): ((s // "") | gsub("[\u0000-\u001f\u007f-\u009f]";" ") | gsub("\\p{Cf}";" ") | gsub("[\u2028\u2029]";" "));
  def bucket:
    if .__typename == "StatusContext" then
      ({"SUCCESS":"success","FAILURE":"failed","ERROR":"failed","PENDING":"pending","EXPECTED":"pending"}
        [(.state // "") | ascii_upcase] // "unknown")
    # A check run carries a conclusion only once completed; "" and null both mean still running.
    elif (.conclusion // "") == "" then "pending"
    else
      ({"SUCCESS":"success","NEUTRAL":"not_run","SKIPPED":"not_run","CANCELLED":"failed",
        "FAILURE":"failed","TIMED_OUT":"failed","STARTUP_FAILURE":"failed",
        "ACTION_REQUIRED":"failed","STALE":"failed"}
        [(.conclusion // "") | ascii_upcase] // "unknown")
    end;
  def outcome: if .__typename == "StatusContext" then (.state // "?") else (.conclusion // .status // "?") end;
  # Worst-of across same-named entries: one failing run of a required name fails it.
  def rank: {"failed":0,"pending":1,"unknown":2,"not_run":3,"success":4}[.];

  ($req | map(scrub(.))) as $req |
  (.headRefOid // "") as $head |
  ($want != "" and (($head | ascii_downcase) | startswith($want | ascii_downcase) | not)) as $moved |
  [ .statusCheckRollup[] | {
      name: scrub(.name // .context // "?"),
      workflow: scrub(.workflowName // ""),
      bucket: bucket,
      outcome: outcome
    } | .required = (.name as $n | $req | index($n) != null) ] as $C |
  ($C | map(select(.bucket == "failed")))                      as $failed |
  ($C | map(select(.bucket == "pending" or .bucket == "unknown"))) as $pending |
  ($C | map(select(.bucket == "not_run")))                     as $notrun |
  ($C | map(select(.bucket == "success")))                     as $ok |
  ($req | map(. as $n | select([$C[] | select(.name == $n)] | length == 0))) as $missing |
  ($req | map(. as $n | select(([$C[] | select(.name == $n) | .bucket] | min_by(rank)) == "not_run"))) as $reqNotRun |
  ($failed | map(select(.required)))                           as $failedReq |

  # A moved head outranks everything: the rollup then describes a commit nobody reviewed.
  ( if $moved then
      ["INCOMPLETE", "head moved: reviewed \($want), PR is now at \($head[0:12]) — re-run against the new head"]
    elif ($failedReq | length) > 0 then
      ["RED", "required check failed: \($failedReq | map(.name) | unique | join(", "))"]
    elif ($C | length) == 0 then
      ["INCOMPLETE", "no checks reported on \($head[0:12])"]
    elif ($pending | length) > 0 or ($missing | length) > 0 or ($reqNotRun | length) > 0 then
      ["INCOMPLETE", ([ (if ($pending | length) > 0 then "\($pending | length) pending" else empty end),
                        (if ($missing | length) > 0 then "required not reported: \($missing | join(", "))" else empty end),
                        (if ($reqNotRun | length) > 0 then "required skipped/neutral: \($reqNotRun | join(", "))" else empty end)
                      ] | join("; "))]
    elif ($failed | length) > 0 then
      ["RED-ADVISORY", "non-required check failed: \($failed | map(.name) | unique | join(", "))"]
    else
      ["GREEN", "\($ok | length) succeeded, \($notrun | length) skipped/neutral (none required); all \($req | length) required present and succeeded"]
    end ) as $v |

  def row: "  \(if .required then "[required] " else "" end)\(.name)\(if .workflow != "" then " (\(.workflow))" else "" end): \(.outcome)";
  def section(title; xs): ["", "-- \(title) (\(xs | length)) --"] + (if (xs | length) == 0 then ["  (none)"] else (xs | map(row)) end);

  { verdict: $v[0],
    report: ([ "=== PR #\($pr) — \($repo) — CI verdict ===",
               "HEAD=\($head)  BASE-REQUIRED=\($req | length)\(if ($req | length) > 0 then " (\($req | join(", ")))" else "" end)",
               "ROLLUP: \($C | length) total — \($ok | length) succeeded, \($failed | length) failed/cancelled, \($pending | length) pending, \($notrun | length) skipped/neutral" ]
             + section("FAILED / CANCELLED"; $failed)
             + section("PENDING"; $pending)
             + ["", "-- REQUIRED BUT NOT REPORTED (\($missing | length)) --"]
             + (if ($missing | length) == 0 then ["  (none)"] else ($missing | map("  [required] " + .)) end)
             + section("SKIPPED / NEUTRAL"; $notrun)
             + section("SUCCEEDED"; $ok)
             + ["", "CI_VERDICT=\($v[0])", "REASON=\($v[1])"]
             | join("\n")) }
' <<<"$PR_JSON")"

VERDICT="$(jq -r '.verdict' <<<"$RESULT")"
jq -r '.report' <<<"$RESULT"

case "$VERDICT" in
  GREEN) exit 0 ;;
  RED|INCOMPLETE|RED-ADVISORY) exit 3 ;;
  *) echo "ERROR: internal — unrecognised verdict ('$VERDICT')." >&2; exit 1 ;;
esac
