#!/usr/bin/env bash
# Pins the CI verdict contract: green only when every check succeeded and every required context reported success.

# -e is deliberately absent: this harness tallies failures and exits on the count.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/pr-ci-verdict.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pcv-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fx"

# Stub gh: serves the canned PR, rulesets, protection, classic rule, per-app check runs, statuses and apps, so the real jq program is what gets exercised.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$FIXTURE_DIR/pr.json"; exit 0 ;;
  "api graphql")
    [ -e "$FIXTURE_DIR/graphql.fail" ] && { echo "HTTP 502" >&2; exit 1; }
    cat "$FIXTURE_DIR/classic_rule.json"; exit 0 ;;
esac
for a in "$@"; do
  case "$a" in
    *'#'*) echo "stub gh: unencoded # in $a" >&2; exit 1 ;;
    */check-runs\?*)
      [ -e "$FIXTURE_DIR/checkruns.fail" ] && { echo "HTTP 502" >&2; exit 1; }
      q=${a#*\?}
      name=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^check_name=//p')
      app=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^app_id=//p')
      # checkruns.paged: one run per page, the way gh --paginate prints a multi-page answer.
      if [ -e "$FIXTURE_DIR/checkruns.paged" ]; then
        jq -c --arg n "$name" --arg a "$app" \
          '[.[] | select((.name | @uri) == $n and (.app.id | tostring) == $a)] | length as $t | .[] | {total_count: $t, check_runs: [.]}' \
          "$FIXTURE_DIR/checkruns.json"
      else
        jq -c --arg n "$name" --arg a "$app" \
          '[.[] | select((.name | @uri) == $n and (.app.id | tostring) == $a)] | {total_count: length, check_runs: .}' \
          "$FIXTURE_DIR/checkruns.json"
      fi
      exit 0 ;;
    */statuses\?*)
      [ -e "$FIXTURE_DIR/statuses.fail" ] && { echo "HTTP 502" >&2; exit 1; }
      cat "$FIXTURE_DIR/statuses.json"; exit 0 ;;
    apps/*)
      id=$(jq -r --arg s "${a#apps/}" '.[$s] // empty' "$FIXTURE_DIR/apps.json")
      [ -n "$id" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      printf '{"id": %s}\n' "$id"; exit 0 ;;
    */rules/branches/*)
      [ -e "$FIXTURE_DIR/rules.fail" ] && { echo "HTTP 403" >&2; exit 1; }
      cat "$FIXTURE_DIR/rules.json"; exit 0 ;;
    */branches/*) cat "$FIXTURE_DIR/branch.json"; exit 0 ;;
  esac
done
echo "stub gh: unrecognized invocation: $*" >&2
exit 1
STUB
chmod +x "$WORK/bin/gh"

export PATH="$WORK/bin:$PATH"
export GH_REPO="example-org/example-repo"

python3 - "$WORK/fx" <<'PYGEN'
import json, os, sys
fx = sys.argv[1]
HEAD = "abcdef1234567890abcdef1234567890abcdef12"

def run(name, conclusion, status="COMPLETED", workflow="CI", started=None, run_id=None, job=1):
    r = {"__typename": "CheckRun", "name": name, "status": status,
         "conclusion": conclusion, "workflowName": workflow}
    if started:
        r["startedAt"] = started
    if run_id:
        r["detailsUrl"] = "https://github.com/example-org/example-repo/actions/runs/%d/job/%d" % (run_id, job)
    return r

def ctx(name, state):
    return {"__typename": "StatusContext", "context": name, "state": state}

def ruleset(*names, app=None):
    checks = [{"context": n} for n in names]
    if app is not None:
        for c in checks:
            c["integration_id"] = app
    return {"type": "required_status_checks", "parameters": {"required_status_checks": checks}}

def gate(kind):
    return {"type": kind, "parameters": {}}

# As the branches endpoint returns it: contexts mirrors checks[], and enabled is false when only rulesets protect the branch.
def branch(*names, checks=(), enabled=None):
    rsc = {"contexts": list(names) + [c for c, _ in checks]}
    if checks:
        rsc["checks"] = [{"context": c, "app_id": a} for c, a in checks]
    if enabled is None:
        enabled = bool(names or checks)
    return {"protected": True, "protection": {"enabled": enabled, "required_status_checks": rsc}}

# A check run as the REST check-runs endpoint returns it: lowercase, and carrying its app.
def app_run(name, app, conclusion, status="completed", started="2026-10-01T10:00:00Z"):
    return {"name": name, "app": {"id": app}, "status": status, "conclusion": conclusion, "started_at": started}

# A commit status as the REST statuses endpoint returns it: newest first, carrying its creator.
def status(context, state, login, kind="Bot"):
    return {"context": context, "state": state, "creator": {"login": login, "type": kind}}

# The classic rule as GraphQL returns it; None is what a token without admin access gets back.
def classic_rule(rule):
    return {"data": {"repository": {"ref": {"name": "main", "branchProtectionRule": rule}}}}

NO_DEPLOY = {"requiresDeployments": False, "requiredDeploymentEnvironments": []}
UNSTARTED = "0001-01-01T00:00:00Z"

# rules is a list of pages: gh --paginate prints one JSON array per page.
scenarios = {
    "green":          ([run("build", "SUCCESS"), run("lint", "SUCCESS")],  [[ruleset("build")]], branch()),
    "green_neutral":  ([run("build", "SUCCESS"), run("CodeQL", "NEUTRAL", workflow="")], [[ruleset("build")]], branch()),
    "req_failed":     ([run("build", "FAILURE"), run("lint", "SUCCESS")],  [[ruleset("build")]], branch()),
    "req_cancelled":  ([run("build", "CANCELLED")],                       [[ruleset("build")]], branch()),
    "advisory":       ([run("build", "SUCCESS"), run("lint", "FAILURE")],  [[ruleset("build")]], branch()),
    # conclusion is "" while a run is in flight: a `//` default never fires on it.
    "in_progress":    ([run("build", "", status="IN_PROGRESS")],           [[ruleset("build")]], branch()),
    "queued_null":    ([run("build", None, status="QUEUED")],              [[ruleset("build")]], branch()),
    "req_missing":    ([run("lint", "SUCCESS")],                           [[ruleset("build")]], branch()),
    "req_skipped":    ([run("build", "SKIPPED"), run("lint", "SUCCESS")],  [[ruleset("build")]], branch()),
    "empty":          ([],                                                 [[]],                branch()),
    "status_error":   ([ctx("ci/legacy", "ERROR")],                        [[]],                branch("ci/legacy")),
    "status_pending": ([ctx("ci/legacy", "PENDING")],                      [[]],                branch("ci/legacy")),
    # One failing run of a required name fails it, whatever its twin says.
    "dup_name":       ([run("build", "SUCCESS"), run("build", "FAILURE", workflow="Other")], [[ruleset("build")]], branch()),
    "dup_skipped":    ([run("build", "SUCCESS"), run("build", "SKIPPED", workflow="Other")], [[ruleset("build")]], branch()),
    # Required set is the union of every ruleset page and classic protection.
    "paged_union":    ([run("a", "SUCCESS"), run("c", "SUCCESS")],         [[ruleset("a")], [ruleset("b")]], branch("c")),
    "unknown":        ([run("build", "SOMETHING_NEW")],                    [[ruleset("build")]], branch()),
    "invisible_name": ([run("bu\u200bild\u202e\u2028", "FAILURE")],        [[]],                branch()),
    "rules_fail":     ([run("build", "SUCCESS")],                          [[ruleset("build")]], branch()),
    # Ruleset gates a rollup cannot map to a check name: a required workflow, code scanning results.
    "workflows_gate":   ([run("build", "SUCCESS")],                        [[ruleset("build"), gate("workflows")]], branch()),
    "workflows_failed": ([run("build", "SUCCESS"), run("secscan", "FAILURE", workflow="security")],
                         [[ruleset("build"), gate("workflows")]], branch()),
    "scanning_gate":    ([run("build", "SUCCESS")],                        [[ruleset("build"), gate("code_scanning")]], branch()),
    # Nothing succeeded and nothing failed: every check skipped or neutral proves nothing ran.
    "all_skipped":      ([run("build", "SKIPPED"), run("lint", "NEUTRAL")], [[]],               branch()),
    # GitHub keeps only a run's latest attempt in the rollup, so same-named entries are separate runs: push and pull_request, say.
    "two_runs_failed":  ([run("build", "FAILURE", started="2026-10-01T10:00:00Z", run_id=111),
                          run("build", "SUCCESS", started="2026-10-01T10:01:00Z", run_id=222)], [[ruleset("build")]], branch()),
    "two_runs_advisory": ([run("build", "FAILURE", started="2026-10-01T10:00:00Z", run_id=111),
                           run("build", "SUCCESS", started="2026-10-01T10:01:00Z", run_id=222)], [[]], branch()),
    # Two same-named jobs in one run share its run ID; a passing one must not hide a failing one.
    "one_run_two_jobs": ([run("build", "FAILURE", started="2026-10-01T10:00:00Z", run_id=111, job=1),
                          run("build", "SUCCESS", started="2026-10-01T10:01:00Z", run_id=111, job=2)], [[ruleset("build")]], branch()),
    # The same shape with no Actions URL at all (an external CI).
    "two_runs_no_url":  ([run("build", "FAILURE", started="2026-10-01T10:00:00Z"),
                          run("build", "SUCCESS", started="2026-10-01T10:30:00Z")], [[ruleset("build")]], branch()),
    # A re-queue: the older attempt passed and the newer one has not started.
    "requeued":         ([run("build", "SUCCESS", started="2026-10-01T10:00:00Z"),
                          run("build", None, status="QUEUED", started=UNSTARTED)], [[ruleset("build")]], branch()),
    # Classic protection can list a requirement only under checks[].
    "classic_checks":   ([run("lint", "SUCCESS")],                         [[]], branch(checks=[("build", None)])),
    # Pinned to an app: a same-named status from another source must not satisfy it.
    "pin_other_source": ([ctx("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    "pin_ok":           ([run("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    "pin_failed":       ([ctx("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    "pin_classic":      ([run("build", "SUCCESS")],                        [[]], branch(checks=[("build", 15368)])),
    "pin_fail_api":     ([run("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    # The pinned app's own runs from two workflow runs: the earlier failing one still counts.
    "pin_two_runs":     ([run("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    # The pinned app's runs span two pages of the check-runs answer.
    "pin_paged":        ([run("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    # The pinned app reports through a commit status: its bot is the creator.
    "pin_status_app":   ([ctx("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    "pin_status_app_failed": ([ctx("ext-ci", "FAILURE")],                  [[ruleset("ext-ci", app=12345)]], branch()),
    # A status posted with a user's token names the user, so no app can be proven.
    "pin_status_user":  ([ctx("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    # A bot whose app this token cannot look up (a private app).
    "pin_status_private": ([ctx("ext-ci", "SUCCESS")],                     [[ruleset("ext-ci", app=12345)]], branch()),
    # Newest first: a user's later success does not hide the app's own failure.
    "pin_status_mixed": ([ctx("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    # The app's status is on the second page of statuses.
    "pin_status_paged": ([ctx("ext-ci", "SUCCESS")],                       [[ruleset("ext-ci", app=12345)]], branch()),
    "pin_status_fail_api": ([ctx("ext-ci", "SUCCESS")],                    [[ruleset("ext-ci", app=12345)]], branch()),
    # A same-named failure from a source the pin excludes does not fail the requirement, in rulesets or classic.
    "pin_other_fails":  ([run("ext-ci", "SUCCESS", workflow=""), ctx("ext-ci", "FAILURE")],
                         [[ruleset("ext-ci", app=12345)]], branch()),
    "pin_classic_other_fails": ([run("build", "SUCCESS"), ctx("build", "FAILURE")], [[]], branch(checks=[("build", 15368)])),
    # A pinned name carrying a tab or a backslash must reach the API unchanged.
    "pin_tab_name":     ([run("ext\tci", "SUCCESS")],                      [[ruleset("ext\tci", app=12345)]], branch()),
    "pin_backslash_name": ([run("ext\\ci", "SUCCESS")],                    [[ruleset("ext\\ci", app=12345)]], branch()),
    # The source pin is an integer or null; -1 means any source, and anything else is outside the API contract.
    "app_any":          ([run("build", "SUCCESS")],                        [[ruleset("build", app=-1)]], branch()),
    "app_zero":         ([run("build", "SUCCESS")],                        [[ruleset("build", app=0)]], branch()),
    "app_string":       ([run("build", "SUCCESS")],                        [[ruleset("build", app="12345")]], branch()),
    "app_classic_null": ([run("build", "SUCCESS")],                        [[]], branch(checks=[("build", None)])),
    # Classic "Require deployments to succeed": set, unset, unreadable, unread.
    "classic_deploy":   ([run("build", "SUCCESS")],                        [[]], branch("build")),
    "classic_no_deploy": ([run("build", "SUCCESS")],                       [[]], branch("build")),
    "classic_unreadable_blocked": ([run("build", "SUCCESS")],              [[]], branch("build")),
    "classic_unreadable_clean":   ([run("build", "SUCCESS")],              [[]], branch("build")),
    "classic_graphql_fail": ([run("build", "SUCCESS")],                    [[]], branch("build")),
    # Protected by rulesets alone: classic protection is off, so its rule is never asked for.
    "rulesets_only":    ([run("build", "SUCCESS")],                        [[ruleset("build")]], branch(enabled=False)),
    # A base branch whose name a URL would cut short.
    "base_hash":        ([run("build", "SUCCESS")],                        [[ruleset("build")]], branch()),
    # gh can return no rollup at all, or something that is not a list.
    "null_rollup":      (None,                                             [[]],                branch()),
    "bad_rollup":       ("not-a-list",                                     [[]],                branch()),
}

check_runs = {
    "pin_ok":       [app_run("ext-ci", 12345, "success")],
    "pin_failed":   [app_run("ext-ci", 12345, "failure")],
    "pin_classic":  [app_run("build", 15368, "success")],
    "pin_fail_api": [app_run("ext-ci", 12345, "success")],
    "pin_two_runs": [app_run("ext-ci", 12345, "failure", started="2026-10-01T10:00:00Z"),
                     app_run("ext-ci", 12345, "success", started="2026-10-01T10:01:00Z")],
    "pin_paged":    [app_run("ext-ci", 12345, "success"), app_run("ext-ci", 12345, "failure")],
    "pin_other_fails": [app_run("ext-ci", 12345, "success")],
    "pin_classic_other_fails": [app_run("build", 15368, "success")],
    "pin_tab_name": [app_run("ext\tci", 12345, "success")],
    "pin_backslash_name": [app_run("ext\\ci", 12345, "success")],
}
# Pages of the statuses endpoint, newest first.
statuses = {
    "pin_other_source":      [[status("ext-ci", "success", "other-ci[bot]")]],
    "pin_failed":            [[status("ext-ci", "success", "other-ci[bot]")]],
    "pin_status_app":        [[status("ext-ci", "success", "ext-ci-app[bot]")]],
    "pin_status_app_failed": [[status("ext-ci", "failure", "ext-ci-app[bot]")]],
    "pin_status_user":       [[status("ext-ci", "success", "someone", kind="User")]],
    "pin_status_private":    [[status("ext-ci", "success", "private-ci[bot]")]],
    "pin_status_mixed":      [[status("ext-ci", "success", "someone", kind="User"),
                               status("ext-ci", "failure", "ext-ci-app[bot]"),
                               status("ext-ci", "pending", "ext-ci-app[bot]")]],
    "pin_status_paged":      [[status("other", "success", "other-ci[bot]")],
                              [status("ext-ci", "success", "ext-ci-app[bot]")]],
    "pin_status_fail_api":   [[status("ext-ci", "success", "ext-ci-app[bot]")]],
    "pin_other_fails":       [[status("ext-ci", "failure", "someone", kind="User")]],
    "pin_classic_other_fails": [[status("build", "failure", "other-ci[bot]")]],
}
apps = {"ext-ci-app": 12345, "other-ci": 999}
classic_rules = {
    "classic_deploy": {"requiresDeployments": True, "requiredDeploymentEnvironments": ["staging"]},
    "classic_unreadable_blocked": None,
    "classic_unreadable_clean": None,
    # Proves the rule is not consulted when classic protection is off.
    "rulesets_only": {"requiresDeployments": True, "requiredDeploymentEnvironments": ["staging"]},
}
merge_states = {"classic_unreadable_blocked": "BLOCKED"}
bases = {"base_hash": "release#1"}

for name, (rollup, rules, br) in scenarios.items():
    d = os.path.join(fx, name)
    os.makedirs(d, exist_ok=True)
    pr = {"headRefOid": HEAD, "baseRefName": bases.get(name, "main"), "statusCheckRollup": rollup,
          "mergeStateStatus": merge_states.get(name, "CLEAN")}
    open(os.path.join(d, "pr.json"), "w").write(json.dumps(pr))
    open(os.path.join(d, "rules.json"), "w").write("\n".join(json.dumps(p) for p in rules))
    open(os.path.join(d, "branch.json"), "w").write(json.dumps(br))
    open(os.path.join(d, "checkruns.json"), "w").write(json.dumps(check_runs.get(name, [])))
    open(os.path.join(d, "statuses.json"), "w").write("\n".join(json.dumps(p) for p in statuses.get(name, [[]])))
    open(os.path.join(d, "apps.json"), "w").write(json.dumps(apps))
    open(os.path.join(d, "classic_rule.json"), "w").write(json.dumps(classic_rule(classic_rules.get(name, NO_DEPLOY))))
open(os.path.join(fx, "rules_fail", "rules.fail"), "w").write("")
open(os.path.join(fx, "pin_fail_api", "checkruns.fail"), "w").write("")
open(os.path.join(fx, "pin_paged", "checkruns.paged"), "w").write("")
open(os.path.join(fx, "pin_status_fail_api", "statuses.fail"), "w").write("")
open(os.path.join(fx, "classic_graphql_fail", "graphql.fail"), "w").write("")
PYGEN

PASS=0
FAIL=0

# BASH_UNDER_TEST picks the shell the script runs under: its shebang alone takes the first bash in PATH.
run() { # run <scenario> [args...] — emits the verdict output, preserving the exit code in $RUN_RC
  local scen="$1"; shift
  FIXTURE_DIR="$WORK/fx/$scen" "${BASH_UNDER_TEST:-bash}" "$SUT" 9999 "$@" 2>&1
  RUN_RC=$?
}

want() { # want <name> <scenario> <substring> [args...]
  local name="$1" scen="$2" sub="$3" out; shift 3
  out=$(run "$scen" "$@")
  case "$out" in
    *"$sub"*) PASS=$((PASS + 1)); printf 'ok   %s\n' "$name" ;;
    *) FAIL=$((FAIL + 1)); printf 'FAIL %s: output missing %s\n%s\n' "$name" "$sub" "$out" ;;
  esac
}

want_not() { # want_not <name> <scenario> <substring> [args...]
  local name="$1" scen="$2" sub="$3" out; shift 3
  out=$(run "$scen" "$@")
  case "$out" in
    *"$sub"*) FAIL=$((FAIL + 1)); printf 'FAIL %s: output should not contain %s\n%s\n' "$name" "$sub" "$out" ;;
    *) PASS=$((PASS + 1)); printf 'ok   %s\n' "$name" ;;
  esac
}

want_exit() { # want_exit <name> <scenario> <code> [args...]
  local name="$1" scen="$2" code="$3"; shift 3
  run "$scen" "$@" >/dev/null
  if [ "$RUN_RC" -eq "$code" ]; then
    PASS=$((PASS + 1)); printf 'ok   %s (exit %s)\n' "$name" "$RUN_RC"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s: want exit %s, got %s\n' "$name" "$code" "$RUN_RC"
  fi
}

# Green, and only green, exits 0.
want      'all succeeded is GREEN'                 green          'CI_VERDICT=GREEN'
want_exit 'GREEN exits 0'                          green          0
want      'non-required neutral stays GREEN'       green_neutral  'CI_VERDICT=GREEN'
want      'neutral is listed, not hidden'          green_neutral  'CodeQL: NEUTRAL'

# Failures.
want      'required failure is RED'                req_failed     'CI_VERDICT=RED'
want      'RED names the failed check'             req_failed     'required check failed: build'
want_exit 'RED exits 3'                            req_failed     3
want      'required cancelled is RED'              req_cancelled  'CI_VERDICT=RED'
want      'non-required failure is RED-ADVISORY'   advisory       'CI_VERDICT=RED-ADVISORY'
want_exit 'RED-ADVISORY exits 3'                   advisory       3
want      'one failing twin fails a required name' dup_name       'CI_VERDICT=RED'
want      'a skipped twin leaves a required name unproven' dup_skipped 'required skipped/neutral: build'

# Nothing that did not finish successfully reads as green.
want      'in-progress run is INCOMPLETE'          in_progress    'CI_VERDICT=INCOMPLETE'
want      'queued run is INCOMPLETE'               queued_null    'CI_VERDICT=INCOMPLETE'
want      'unreported required is INCOMPLETE'      req_missing    'required not reported: build'
want      'skipped required is INCOMPLETE'         req_skipped    'required skipped/neutral: build'
want      'no checks at all is INCOMPLETE'         empty          'no checks reported'
want_exit 'INCOMPLETE exits 3'                     empty          3
want      'unknown conclusion is not green'        unknown        'CI_VERDICT=INCOMPLETE'

# Commit statuses, not just check runs.
want      'required status ERROR is RED'           status_error   'CI_VERDICT=RED'
want      'required status PENDING is INCOMPLETE'  status_pending 'CI_VERDICT=INCOMPLETE'

# Required set: every ruleset page plus classic protection.
want      'second ruleset page is read'            paged_union    'required not reported: b'
want      'classic-protection context counts'      paged_union    '[required] c (CI): SUCCESS'

# Head binding: the verdict is about the head you reviewed.
want      'matching head prefix is accepted'       green          'CI_VERDICT=GREEN'      --head abcdef1
want      'moved head is INCOMPLETE'               green          'head moved'            --head 1234567
want      'moved head outranks a red rollup'       req_failed     'CI_VERDICT=INCOMPLETE' --head 1234567

# Check names are PR-editable: invisibles never reach the render.
want_not  'zero-width stripped from names'         invisible_name "$(printf '\342\200\213')"
want_not  'bidi override stripped from names'      invisible_name "$(printf '\342\200\256')"
want_not  'line separator stripped from names'     invisible_name "$(printf '\342\200\250')"

# Failed lookups fail loud, never a verdict.
want_exit 'unreadable rulesets exit 1'             rules_fail     1
want_not  'unreadable rulesets print no verdict'   rules_fail     'CI_VERDICT='
want_exit 'bad --head is a usage error'            green          2  --head nothex

# Ruleset gates that are not a named status check: never GREEN, and a failure under one is not advisory.
want      'a required-workflows gate is INCOMPLETE'  workflows_gate   'CI_VERDICT=INCOMPLETE'
want      'the gate is named'                        workflows_gate   'also gates on workflows'
want      'a failure under a workflows gate is not advisory' workflows_failed 'CI_VERDICT=INCOMPLETE'
want      'a code-scanning gate is INCOMPLETE'       scanning_gate    'also gates on code_scanning'

# Nothing ran is not green.
want      'all skipped or neutral is INCOMPLETE'     all_skipped      'CI_VERDICT=INCOMPLETE'

# Same-named entries are separate runs: the worst one counts, and none is hidden.
want      'a failing push run is not hidden by a passing PR run' two_runs_failed 'CI_VERDICT=RED'
want      'the failing run stays in the report'      two_runs_failed  'build (CI): FAILURE'
want      'a non-required failing run is RED-ADVISORY' two_runs_advisory 'CI_VERDICT=RED-ADVISORY'
want      'a same-named failing job in one run counts' one_run_two_jobs 'CI_VERDICT=RED'
want      'a later pass does not supersede an earlier failure' two_runs_no_url 'CI_VERDICT=RED'
want      'a re-queued run is pending again'         requeued         'CI_VERDICT=INCOMPLETE'
want      'a pending row shows its status'           requeued         'build (CI): QUEUED'
want      'an in-progress row shows its status'      in_progress      'build (CI): IN_PROGRESS'

# Classic checks[] and source pins.
want      'classic checks[] is required too'         classic_checks   'required not reported: build'
want      'a pinned check from another source is not reported' pin_other_source 'not reported by app 12345'
want_not  'a pinned check from another source is not GREEN' pin_other_source 'CI_VERDICT=GREEN'
want      'a pinned check from its app counts'       pin_ok           'CI_VERDICT=GREEN'
want      'the pinned app failing is RED'            pin_failed       'CI_VERDICT=RED'
want      'a classic app_id pin is checked'          pin_classic      'CI_VERDICT=GREEN'
want_exit 'an unreadable pinned lookup exits 1'      pin_fail_api     1
want_not  'an unreadable pinned lookup prints no verdict' pin_fail_api 'CI_VERDICT='
want      'a status from another app names that app' pin_other_source 'a commit status from app 999 does not count'
want      'the pinned app failing in one run is RED' pin_two_runs     'CI_VERDICT=RED'
want      'every page of pinned runs is read'        pin_paged        'CI_VERDICT=RED'

# A pinned app can report through commit statuses; only its own bot proves the source.
want      'a status from the pinned app counts'      pin_status_app   'CI_VERDICT=GREEN'
want      'a failing status from the pinned app is RED' pin_status_app_failed 'CI_VERDICT=RED'
want      'a status under a user token is unproven'  pin_status_user  'which this script cannot attribute to app 12345'
want_not  'a status under a user token is not GREEN' pin_status_user  'CI_VERDICT=GREEN'
want_not  'a status under a user token is not called unreported' pin_status_user 'not reported by app 12345'
want      'a bot with no visible app is unproven'    pin_status_private 'by @private-ci[bot], which this script cannot attribute'
want      'the app latest status counts, not a user one' pin_status_mixed 'CI_VERDICT=RED'
want      'every page of statuses is read'           pin_status_paged 'CI_VERDICT=GREEN'
want_exit 'an unreadable statuses lookup exits 1'    pin_status_fail_api 1
want_not  'an unreadable statuses lookup prints no verdict' pin_status_fail_api 'CI_VERDICT='

# A failure the pin excludes is a non-required failure, not a failed requirement.
want      'an excluded source failing is advisory'   pin_other_fails  'CI_VERDICT=RED-ADVISORY'
want      'an excluded source failing is advisory (classic)' pin_classic_other_fails 'CI_VERDICT=RED-ADVISORY'

# Pinned names reach the API byte for byte.
want      'a tab in a pinned name survives'          pin_tab_name     'CI_VERDICT=GREEN'
want      'a backslash in a pinned name survives'    pin_backslash_name 'CI_VERDICT=GREEN'

# Source pin values.
want      'app id -1 accepts any source'             app_any          'CI_VERDICT=GREEN'
want      'a null classic app id accepts any source' app_classic_null 'CI_VERDICT=GREEN'
want_exit 'app id 0 is outside the contract'         app_zero         1
want_exit 'a string app id is outside the contract'  app_string       1
want_not  'a string app id prints no verdict'        app_string       'CI_VERDICT='

# Classic required deployments name no check.
want      'classic required deployments are INCOMPLETE' classic_deploy 'CI_VERDICT=INCOMPLETE'
want      'the required environment is named'        classic_deploy   'requires deployments to staging'
want      'classic protection without deployments is GREEN' classic_no_deploy 'CI_VERDICT=GREEN'
want      'an unreadable rule on a blocked PR is INCOMPLETE' classic_unreadable_blocked 'CI_VERDICT=INCOMPLETE'
want      'the unreadable rule is explained'         classic_unreadable_blocked 'only a repo admin can read whether it requires deployments'
want      'an unreadable rule on a clean PR is GREEN' classic_unreadable_clean 'CI_VERDICT=GREEN'
want      'the clean merge box is the stated reason' classic_unreadable_clean 'merge box: CLEAN, so none is unmet'
want_exit 'an unreadable classic rule lookup exits 1' classic_graphql_fail 1
want      'a rulesets-only branch never asks for the classic rule' rulesets_only 'CI_VERDICT=GREEN'

# The base branch is a path segment: a # in it must be encoded.
want      'a base with # is encoded'                 base_hash        'CI_VERDICT=GREEN'

# Malformed responses.
want      'no rollup at all is INCOMPLETE'           null_rollup      'no checks reported'
want_exit 'a malformed rollup exits 1'               bad_rollup       1
want_not  'a malformed rollup prints no verdict'     bad_rollup       'CI_VERDICT='

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
