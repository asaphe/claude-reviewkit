#!/usr/bin/env bash
# Pins the CI verdict contract: green only when every check succeeded and every required context reported success.

# -e is deliberately absent: this harness tallies failures and exits on the count.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/pr-ci-verdict.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pcv-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fx"

# Stub gh: serves the canned PR rollup, ruleset pages, branch protection and per-app check runs, so the real jq program is what gets exercised.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$FIXTURE_DIR/pr.json"; exit 0 ;;
esac
for a in "$@"; do
  case "$a" in
    *'#'*) echo "stub gh: unencoded # in $a" >&2; exit 1 ;;
    */check-runs\?*)
      [ -e "$FIXTURE_DIR/checkruns.fail" ] && { echo "HTTP 502" >&2; exit 1; }
      q=${a#*\?}
      name=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^check_name=//p')
      app=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^app_id=//p')
      jq -c --arg n "$name" --arg a "$app" \
        '[.[] | select((.name | @uri) == $n and (.app.id | tostring) == $a)] | {total_count: length, check_runs: .}' \
        "$FIXTURE_DIR/checkruns.json"
      exit 0 ;;
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

def run(name, conclusion, status="COMPLETED", workflow="CI", started=None):
    r = {"__typename": "CheckRun", "name": name, "status": status,
         "conclusion": conclusion, "workflowName": workflow}
    if started:
        r["startedAt"] = started
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

def branch(*names, checks=()):
    rsc = {"contexts": list(names)}
    if checks:
        rsc["checks"] = [{"context": c, "app_id": a} for c, a in checks]
    return {"protection": {"required_status_checks": rsc}}

# A check run as the REST check-runs endpoint returns it: lowercase, and carrying its app.
def app_run(name, app, conclusion, status="completed", started="2026-10-01T10:00:00Z"):
    return {"name": name, "app": {"id": app}, "status": status, "conclusion": conclusion, "started_at": started}

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
    # A re-run: the older attempt failed, the newer one passed, in the same workflow.
    "rerun_passed":     ([run("build", "FAILURE", started="2026-10-01T10:00:00Z"),
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
}
bases = {"base_hash": "release#1"}

for name, (rollup, rules, br) in scenarios.items():
    d = os.path.join(fx, name)
    os.makedirs(d, exist_ok=True)
    pr = {"headRefOid": HEAD, "baseRefName": bases.get(name, "main"), "statusCheckRollup": rollup}
    open(os.path.join(d, "pr.json"), "w").write(json.dumps(pr))
    open(os.path.join(d, "rules.json"), "w").write("\n".join(json.dumps(p) for p in rules))
    open(os.path.join(d, "branch.json"), "w").write(json.dumps(br))
    open(os.path.join(d, "checkruns.json"), "w").write(json.dumps(check_runs.get(name, [])))
open(os.path.join(fx, "rules_fail", "rules.fail"), "w").write("")
open(os.path.join(fx, "pin_fail_api", "checkruns.fail"), "w").write("")
PYGEN

PASS=0
FAIL=0

run() { # run <scenario> [args...] — emits the verdict output, preserving the exit code in $RUN_RC
  local scen="$1"; shift
  FIXTURE_DIR="$WORK/fx/$scen" "$SUT" 9999 "$@" 2>&1
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

# A re-run supersedes its earlier attempt in the same workflow.
want      'a passing re-run clears the failed attempt' rerun_passed   'CI_VERDICT=GREEN'
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

# The base branch is a path segment: a # in it must be encoded.
want      'a base with # is encoded'                 base_hash        'CI_VERDICT=GREEN'

# Malformed responses.
want      'no rollup at all is INCOMPLETE'           null_rollup      'no checks reported'
want_exit 'a malformed rollup exits 1'               bad_rollup       1
want_not  'a malformed rollup prints no verdict'     bad_rollup       'CI_VERDICT='

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
