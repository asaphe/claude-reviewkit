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

GitHub keeps only the latest attempt of each workflow run in the rollup, so a
re-run replaces its failed attempt there. Same-named entries that remain come
from separate runs (a push run and a pull_request run, say): the worst counts.

A required context pinned to an app (ruleset integration_id, classic
checks[].app_id) counts only from that app: its check runs, or a commit status
whose creator is the app's bot. A status posted with a user's token names the
user, and a private app's bot cannot be looked up, so neither proves its app:
INCOMPLETE.

Classic protection's "Require deployments to succeed" names no check, and only
a repo admin can read it. Without admin access it is treated as possibly set
unless the merge box reads the PR as mergeable.

Verdict (CI_VERDICT= line, then REASON=):
  GREEN         every reported check succeeded, and every required context
                is present and succeeded
  RED           a required context failed, was cancelled or timed out
  INCOMPLETE    anything pending; a required context not reported (by its app,
                when pinned), or reported skipped/neutral (passes the gate,
                proves nothing ran); no checks at all, or none that succeeded;
                a gate no check name maps to (ruleset required workflows, code
                scanning or deployments; classic required deployments, set or
                unreadable while the PR is not mergeable): confirm in the merge
                box; a moved head
  RED-ADVISORY  only non-required checks failed and no such gate exists;
                still not green

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

PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid,baseRefName,statusCheckRollup,mergeStateStatus)" || {
  echo "ERROR: could not read PR #$PR_NUMBER in $REPO." >&2
  exit 1
}
BASE="$(jq -r '.baseRefName // empty' <<<"$PR_JSON")" || jq_fail "the base branch"
HEAD_SHA="$(jq -r '.headRefOid // empty' <<<"$PR_JSON")" || jq_fail "the head"
MERGE_STATE="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$PR_JSON")" || jq_fail "the merge state"
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
  # The API types the pin as an integer: null and -1 mean any source, and any other value is not guessed at.
  def pin: if . == null or . == -1 then null
           elif type == "number" and . > 0 and floor == . then .
           else error("unexpected app id \(tojson)") end;
  ($classic.protection.required_status_checks // {}) as $rsc |
  ([ (add // [])[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]
     | {context, app: (.integration_id | pin)} ]
   + [ ($rsc.checks // [])[] | {context, app: (.app_id | pin)} ]
   # contexts is the legacy mirror of checks[]: a name already there must not add an any-source twin.
   + [ ($rsc.contexts // [])[] | select(IN(($rsc.checks // [])[].context) | not) | {context: ., app: null} ])
  | unique' <<<"$RULES")" || jq_fail "the required contexts"
# Ruleset rules that gate the merge without naming a status check, so no rollup entry can prove them.
GATES="$(jq -s '[ (add // [])[] | .type
  | select(IN("workflows", "code_scanning", "code_quality", "code_coverage", "license_compliance_scanning", "required_deployments")) ]
  | unique' <<<"$RULES")" || jq_fail "the ruleset gates"

# Classic "Require deployments to succeed" is absent from REST; GraphQL shows the rule to repo admins and null to everyone else.
DEPLOY='{"state":"none"}'
CLASSIC_ON="$(jq -r 'if .protected == false or .protection.enabled == false then "off" else "on" end' <<<"$CLASSIC")" || jq_fail "the branch protection"
if [[ "$CLASSIC_ON" == on ]]; then
  # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
  RULE_Q='query($owner:String!,$name:String!,$ref:String!){
    repository(owner:$owner,name:$name){ ref(qualifiedName:$ref){ branchProtectionRule{ requiresDeployments requiredDeploymentEnvironments } } } }'
  RULE_JSON="$(gh api graphql -f owner="${REPO%%/*}" -f name="${REPO##*/}" -f ref="refs/heads/$BASE" -f query="$RULE_Q")" || {
    echo "ERROR: could not read the classic protection rule for $REPO@$BASE — required deployments unknown." >&2
    exit 1
  }
  DEPLOY="$(jq --arg merge "$MERGE_STATE" '
    if (.errors // []) | length > 0 then error("GraphQL errors")
    elif .data.repository.ref == null then error("no such ref")
    else .data.repository.ref.branchProtectionRule as $r
      | if $r == null then
          # Unreadable: only a merge box that reads mergeable proves no required deployment is unmet.
          {state: (if IN($merge; "CLEAN", "HAS_HOOKS", "UNSTABLE") then "unreadable_clear" else "unreadable" end), merge: $merge}
        elif $r.requiresDeployments == true then {state: "required", envs: ($r.requiredDeploymentEnvironments // [])}
        else {state: "none"} end
    end' <<<"$RULE_JSON")" || jq_fail "the classic protection rule"
fi

# The rollup does not say who reported an entry, so a pinned context is read from its app: check runs, then commit statuses.
PINNED="[]"
STATUSES=""
APP_IDS="{}"
while IFS= read -r SPEC; do
  [[ -n "$SPEC" ]] || continue
  [[ -n "$HEAD_SHA" ]] || { echo "ERROR: PR #$PR_NUMBER has no head in the response." >&2; exit 1; }
  PIN_CTX="$(jq -r '.context' <<<"$SPEC")" || jq_fail "a pinned context"
  PIN_APP="$(jq -r '.app' <<<"$SPEC")" || jq_fail "a pinned app"
  PIN_NAME="$(jq -r '.context | @uri' <<<"$SPEC")" || jq_fail "a pinned context name"
  # filter=latest (the default, stated) drops superseded attempts, as the rollup does.
  PIN_RUNS="$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/check-runs?check_name=$PIN_NAME&app_id=$PIN_APP&filter=latest&per_page=100")" || {
    echo "ERROR: could not read check runs for required '$PIN_CTX' from app $PIN_APP — required checks unknown." >&2
    exit 1
  }
  RUNS="$(jq -s '[ .[].check_runs[] | {
      __typename: "CheckRun", status: ((.status // "") | ascii_upcase), conclusion: ((.conclusion // "") | ascii_upcase) } ]' <<<"$PIN_RUNS")" \
    || jq_fail "the check runs for '$PIN_CTX'"
  ST="[]"
  HAS_STATUS="$(jq --argjson s "$SPEC" '[ .statusCheckRollup[]? | select(.__typename == "StatusContext" and .context == $s.context) ] | length > 0' <<<"$PR_JSON")" \
    || jq_fail "the rollup statuses"
  if [[ "$HAS_STATUS" == true ]]; then
    if [[ -z "$STATUSES" ]]; then
      STATUSES="$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/statuses?per_page=100")" || {
        echo "ERROR: could not read commit statuses on $HEAD_SHA — required checks unknown." >&2
        exit 1
      }
      STATUSES="$(jq -s 'add // []' <<<"$STATUSES")" || jq_fail "the commit statuses"
    fi
    # A status names its creator, not its app; an app's bot is <slug>[bot], and the slug resolves to the app ID.
    while IFS= read -r SLUG; do
      [[ -n "$SLUG" ]] || continue
      [[ "$(jq --arg s "$SLUG" 'has($s)' <<<"$APP_IDS")" == false ]] || continue
      # A private app is invisible to this token (404): its statuses stay unattributed, never assumed.
      APP_ID="$(gh api "apps/$SLUG" 2>/dev/null | jq -r '.id // empty' 2>/dev/null)" || APP_ID=""
      [[ "$APP_ID" =~ ^[0-9]+$ ]] || APP_ID="null"
      APP_IDS="$(jq --arg s "$SLUG" --argjson id "$APP_ID" '. + {($s): $id}' <<<"$APP_IDS")" || jq_fail "an app lookup"
    done < <(jq -r --argjson s "$SPEC" '[ .[] | select(.context == $s.context and (.creator.type // "") == "Bot")
      | (.creator.login // "") | select(endswith("[bot]")) | rtrimstr("[bot]") | select(test("^[A-Za-z0-9][A-Za-z0-9-]*$")) ] | unique[]' <<<"$STATUSES")
    ST="$(jq --argjson s "$SPEC" --argjson ids "$APP_IDS" '[ .[] | select(.context == $s.context) | {
        __typename: "StatusContext", state: ((.state // "") | ascii_upcase), login: (.creator.login // ""),
        app: ((.creator.login // "") as $l
              | if (.creator.type // "") == "Bot" and ($l | endswith("[bot]")) then $ids[$l | rtrimstr("[bot]")] else null end) } ]' <<<"$STATUSES")" \
      || jq_fail "the commit statuses for '$PIN_CTX'"
  fi
  PINNED="$(jq -n --argjson acc "$PINNED" --argjson s "$SPEC" --argjson runs "$RUNS" --argjson st "$ST" \
    '$acc + [{context: $s.context, app: $s.app, runs: $runs, statuses: $st}]')" || jq_fail "the pinned contexts"
done < <(jq -c '.[] | select(.app != null)' <<<"$REQ_SPECS")

RESULT="$(jq --argjson specs "$REQ_SPECS" --argjson gates "$GATES" --argjson pinned "$PINNED" --argjson deploy "$DEPLOY" \
             --arg want "$WANT_HEAD" --arg pr "$PR_NUMBER" --arg repo "$REPO" '
  # Check names come from workflow files a PR can edit: strip what reorders an agent-read render.
  def scrub(s): ((s // "") | gsub("[\u0000-\u001f\u007f-\u009f]";" ") | gsub("\\p{Cf}|\\p{Default_Ignorable_Code_Point}";" ") | gsub("[  ]";" "));
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
  # Worst-of across same-named entries: the rollup holds only latest attempts, so each one is a separate run.
  def rank: {"failed":0,"pending":1,"unknown":2,"not_run":3,"success":4}[.];

  ($specs | map(scrub(.context)) | unique) as $allReq |
  # A name required only from a specific app is judged only through that app.
  ($specs | map(select(.app == null) | scrub(.context)) | unique) as $req |
  (.headRefOid // "") as $head |
  ($want != "" and (($head | ascii_downcase) | startswith($want | ascii_downcase) | not)) as $moved |
  [ (.statusCheckRollup // []) | .[] | {
      name: scrub(.name // .context // "?"),
      workflow: scrub(.workflowName // ""),
      bucket: bucket,
      outcome: outcome
    } | .required = (.name as $n | $req | index($n) != null) ] as $C |
  [ $pinned[] | . as $p | {name: scrub(.context), app} + (
      # The app own entries: every check run, plus its latest status (the list is newest first).
      (.runs + ([.statuses[] | select(.app == $p.app)] | .[:1])) as $mine |
      [.statuses[] | select(.app == null) | "@" + scrub(.login)] as $unproven |
      if ($mine | length) > 0 then ($mine | min_by(bucket | rank) | {bucket: bucket, outcome: outcome})
      elif ($unproven | length) > 0 then
        {bucket: "unverified", outcome: "reported as a commit status by \($unproven | unique | join(", ")), which this script cannot attribute to app \(.app) — confirm in the merge box"}
      else
        {bucket: "missing", outcome: "not reported by app \(.app)\(if (.statuses | length) > 0 then " (a commit status from app \([.statuses[].app] | unique | map(tostring) | join(", ")) does not count)" else "" end)"}
      end) ] as $P |
  ($P | map(select(.bucket == "failed")))                      as $pinFailed |
  ($P | map(select(.bucket != "failed" and .bucket != "success"))) as $pinOpen |
  ($C | map(select(.bucket == "failed")))                      as $failed |
  ($C | map(select(.bucket == "pending" or .bucket == "unknown"))) as $pending |
  ($C | map(select(.bucket == "not_run")))                     as $notrun |
  ($C | map(select(.bucket == "success")))                     as $ok |
  ($req | map(. as $n | select([$C[] | select(.name == $n)] | length == 0))) as $missing |
  ($req | map(. as $n | select(([$C[] | select(.name == $n) | .bucket] | min_by(rank)) == "not_run"))) as $reqNotRun |
  ($failed | map(select(.required)))                           as $failedReq |
  ($deploy.envs // [] | map(scrub(.)) | if length == 0 then "environments not listed" else join(", ") end) as $envs |

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
                        ($pinOpen[] | "required \(.name) \(if .bucket == "missing" or .bucket == "unverified" then .outcome else "from app \(.app): \(.outcome)" end)")
                      ] | join("; "))]
    # A required workflow, code-scanning result or deployment names no status check, so a failure under one is not advisory.
    elif ($gates | length) > 0 or IN($deploy.state; "required", "unreadable") then
      ["INCOMPLETE", ([ (if ($gates | length) > 0 then "ruleset also gates on \($gates | join(", ")), which no check name in the rollup maps to" else empty end),
                        (if $deploy.state == "required" then "classic protection requires deployments to \($envs), which no check name maps to" else empty end),
                        (if $deploy.state == "unreadable" then "classic protection is on and only a repo admin can read whether it requires deployments; the merge box reads \($deploy.merge)" else empty end)
                      ] | join("; ")) + " — confirm in the merge box\(if ($failed | length) > 0 then "; check failed: \($failed | map(.name) | unique | join(", "))" else "" end)"]
    elif ($ok | length) == 0 and ($failed | length) == 0 then
      ["INCOMPLETE", "no check succeeded: \($notrun | length) skipped/neutral — nothing proves CI ran"]
    elif ($failed | length) > 0 then
      ["RED-ADVISORY", "non-required check failed: \($failed | map(.name) | unique | join(", "))"]
    else
      ["GREEN", "\($ok | length) succeeded, \($notrun | length) skipped/neutral (none required); all \($allReq | length) required present and succeeded"]
    end ) as $v |

  def row: "  \(if .required then "[required] " else "" end)\(.name)\(if .workflow != "" then " (\(.workflow))" else "" end): \(.outcome)";
  def section(title; xs): ["", "-- \(title) (\(xs | length)) --"] + (if (xs | length) == 0 then ["  (none)"] else (xs | map(row)) end);

  { verdict: $v[0],
    report: ([ "=== PR #\($pr) — \($repo) — CI verdict ===",
               "HEAD=\($head)  BASE-REQUIRED=\($allReq | length)\(if ($allReq | length) > 0 then " (\($allReq | join(", ")))" else "" end)",
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
             + (if $deploy.state == "none" then [] else
                 ["", "-- CLASSIC REQUIRED DEPLOYMENTS --",
                  (if $deploy.state == "required" then "  required: \($envs)"
                   elif $deploy.state == "unreadable" then "  not readable with this token (admin only); merge box: \($deploy.merge), so one may be unmet"
                   else "  not readable with this token (admin only); merge box: \($deploy.merge), so none is unmet" end)] end)
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
