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

A re-run supersedes the earlier attempt of the same check in the same
workflow. A required context pinned to an app (ruleset integration_id,
classic checks[].app_id) is read from that app's own check runs: a
same-named check or status from another source does not satisfy it.

Verdict (CI_VERDICT= line, then REASON=):
  GREEN         every reported check succeeded, and every required context
                is present and succeeded
  RED           a required context failed, was cancelled or timed out
  INCOMPLETE    anything pending; a required context not reported (by its app,
                when pinned), or reported skipped/neutral (passes the gate,
                proves nothing ran); no checks at all, or none that succeeded;
                a ruleset gate no check name maps to (required workflows, code
                scanning, deployments: confirm in the merge box); a moved head
  RED-ADVISORY  only non-required checks failed and no such ruleset gate
                exists; still not green

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

# A jq failure is an unexpected response shape, never a verdict; without this it exits 5, outside the documented codes.
jq_fail() {
  echo "ERROR: could not evaluate $1 for PR #$PR_NUMBER in $REPO — unexpected response shape." >&2
  exit 1
}

PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid,baseRefName,statusCheckRollup)" || {
  echo "ERROR: could not read PR #$PR_NUMBER in $REPO." >&2
  exit 1
}
BASE="$(jq -r '.baseRefName // empty' <<<"$PR_JSON")" || jq_fail "the base branch"
HEAD_SHA="$(jq -r '.headRefOid // empty' <<<"$PR_JSON")" || jq_fail "the head"
[[ -n "$BASE" ]] || { echo "ERROR: PR #$PR_NUMBER has no base branch in the response." >&2; exit 1; }
# The branch is a path segment: a `#` or `?` in it would cut the URL short and read another branch's rules.
BASE_PATH="$(jq -rn --arg b "$BASE" '$b | @uri | gsub("%2F"; "/")')" || jq_fail "the base branch path"

# Required contexts live in two places; a check either one requires gates the merge.
RULES="$(gh api --paginate "repos/$REPO/rules/branches/$BASE_PATH")" || {
  echo "ERROR: could not read rulesets for $REPO@$BASE — required checks unknown." >&2
  exit 1
}
CLASSIC="$(gh api "repos/$REPO/branches/$BASE_PATH")" || {
  echo "ERROR: could not read branch protection for $REPO@$BASE — required checks unknown." >&2
  exit 1
}
# Each requirement is a context and the app it must come from (null: any source).
REQ_SPECS="$(jq -s --argjson classic "$CLASSIC" '
  ([ (add // [])[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]
     | {context, app: .integration_id} ]
   + [ ($classic.protection.required_status_checks.contexts // [])[] | {context: ., app: null} ]
   + [ ($classic.protection.required_status_checks.checks // [])[] | {context, app: .app_id} ])
  | map(.app = (if (.app | type) == "number" and .app > 0 then .app else null end))
  | unique' <<<"$RULES")" || jq_fail "the required contexts"
# Ruleset rules that gate the merge without naming a status check, so no rollup entry can prove them.
GATES="$(jq -s '[ (add // [])[] | .type
  | select(IN("workflows", "code_scanning", "code_quality", "code_coverage", "license_compliance_scanning", "required_deployments")) ]
  | unique' <<<"$RULES")" || jq_fail "the ruleset gates"

# The rollup does not say which app reported a check, so a pinned context is read from that app's own check runs.
PINNED="[]"
while IFS=$'\t' read -r PIN_CTX PIN_APP; do
  [[ -n "$PIN_CTX" ]] || continue
  [[ -n "$HEAD_SHA" ]] || { echo "ERROR: PR #$PR_NUMBER has no head in the response." >&2; exit 1; }
  PIN_NAME="$(jq -rn --arg c "$PIN_CTX" '$c | @uri')" || jq_fail "a pinned context name"
  PIN_RUNS="$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/check-runs?check_name=$PIN_NAME&app_id=$PIN_APP&per_page=100")" || {
    echo "ERROR: could not read check runs for required '$PIN_CTX' from app $PIN_APP — required checks unknown." >&2
    exit 1
  }
  PINNED="$(jq -s --argjson acc "$PINNED" --arg c "$PIN_CTX" --argjson a "$PIN_APP" '
    $acc + [{context: $c, app: $a, runs: [ .[].check_runs[] | {
      __typename: "CheckRun", name: .name, workflowName: "", startedAt: (.started_at // ""),
      status: ((.status // "") | ascii_upcase), conclusion: ((.conclusion // "") | ascii_upcase) } ]}]' <<<"$PIN_RUNS")" \
    || jq_fail "the check runs for '$PIN_CTX'"
done < <(jq -r '.[] | select(.app != null) | [.context, (.app | tostring)] | @tsv' <<<"$REQ_SPECS")

RESULT="$(jq --argjson specs "$REQ_SPECS" --argjson gates "$GATES" --argjson pinned "$PINNED" \
             --arg want "$WANT_HEAD" --arg pr "$PR_NUMBER" --arg repo "$REPO" '
  # Check names come from workflow files a PR can edit: strip what reorders an agent-read render.
  def scrub(s): ((s // "") | gsub("[\u0000-\u001f\u007f-\u009f]";" ") | gsub("\\p{Cf}|\\p{Default_Ignorable_Code_Point}";" ") | gsub("[\u2028\u2029]";" "));
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
  # A running check carries conclusion "", which `//` keeps, so the status is read explicitly.
  def outcome: if .__typename == "StatusContext" then (.state // "?") elif (.conclusion // "") == "" then (.status // "?") else .conclusion end;
  # An attempt not started yet carries the zero time and is the newest one.
  def started: (.startedAt // "") as $s | if $s == "" or ($s | startswith("0001-")) then "9999" else $s end;
  # Worst-of across same-named entries from different workflows: one failing run of a required name fails it.
  def rank: {"failed":0,"pending":1,"unknown":2,"not_run":3,"success":4}[.];

  ($specs | map(scrub(.context)) | unique) as $req |
  (.headRefOid // "") as $head |
  ($want != "" and (($head | ascii_downcase) | startswith($want | ascii_downcase) | not)) as $moved |
  # A re-run supersedes the attempt before it, so only the latest per check name and workflow counts.
  [ (.statusCheckRollup // [])
    | group_by([.__typename, (.name // .context // ""), (.workflowName // "")])
    | map(if .[0].__typename == "CheckRun" then max_by(started) else .[] end)
    | .[] | {
      name: scrub(.name // .context // "?"),
      workflow: scrub(.workflowName // ""),
      bucket: bucket,
      outcome: outcome
    } | .required = (.name as $n | $req | index($n) != null) ] as $C |
  [ $pinned[] | {name: scrub(.context), app} + (
      if (.runs | length) == 0 then {bucket: "missing", outcome: "not reported by app \(.app)"}
      else (.runs | max_by(started) | {bucket: bucket, outcome: outcome}) end) ] as $P |
  ($P | map(select(.bucket == "failed")))                      as $pinFailed |
  ($P | map(select(.bucket != "failed" and .bucket != "success"))) as $pinOpen |
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
    elif ($failedReq | length) > 0 or ($pinFailed | length) > 0 then
      ["RED", "required check failed: \(($failedReq | map(.name)) + ($pinFailed | map("\(.name) (app \(.app))")) | unique | join(", "))"]
    elif ($C | length) == 0 then
      ["INCOMPLETE", "no checks reported on \($head[0:12])"]
    elif ($pending | length) > 0 or ($missing | length) > 0 or ($reqNotRun | length) > 0 or ($pinOpen | length) > 0 then
      ["INCOMPLETE", ([ (if ($pending | length) > 0 then "\($pending | length) pending" else empty end),
                        (if ($missing | length) > 0 then "required not reported: \($missing | join(", "))" else empty end),
                        (if ($reqNotRun | length) > 0 then "required skipped/neutral: \($reqNotRun | join(", "))" else empty end),
                        ($pinOpen[] | "required \(.name) \(if .bucket == "missing" then .outcome else "from app \(.app): \(.outcome)" end)")
                      ] | join("; "))]
    # A required workflow or code-scanning result names no status check, so a failure under it is not advisory.
    elif ($gates | length) > 0 then
      ["INCOMPLETE", "ruleset also gates on \($gates | join(", ")), which no check name in the rollup maps to — confirm in the merge box\(if ($failed | length) > 0 then "; check failed: \($failed | map(.name) | unique | join(", "))" else "" end)"]
    elif ($ok | length) == 0 and ($failed | length) == 0 then
      ["INCOMPLETE", "no check succeeded: \($notrun | length) skipped/neutral — nothing proves CI ran"]
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
             + (if ($P | length) == 0 then [] else
                 ["", "-- REQUIRED FROM A SPECIFIC APP (\($P | length)) --"]
                 + ($P | map("  [required] \(.name) (app \(.app)): \(.outcome)")) end)
             + (if ($gates | length) == 0 then [] else
                 ["", "-- RULESET GATES WITH NO CHECK NAME (\($gates | length)) --"] + ($gates | map("  " + .)) end)
             + section("SKIPPED / NEUTRAL"; $notrun)
             + section("SUCCEEDED"; $ok)
             + ["", "CI_VERDICT=\($v[0])", "REASON=\($v[1])"]
             | join("\n")) }
' <<<"$PR_JSON")" || jq_fail "the check rollup"

VERDICT="$(jq -r '.verdict' <<<"$RESULT")" || jq_fail "the verdict"
jq -r '.report' <<<"$RESULT"

case "$VERDICT" in
  GREEN) exit 0 ;;
  RED|INCOMPLETE|RED-ADVISORY) exit 3 ;;
  *) echo "ERROR: internal — unrecognised verdict ('$VERDICT')." >&2; exit 1 ;;
esac
