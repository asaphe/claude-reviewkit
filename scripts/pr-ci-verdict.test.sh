#!/usr/bin/env bash
# Pins the CI verdict contract: green only when every check succeeded and every required context reported success.

# -e is deliberately absent: this harness tallies failures and exits on the count.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/pr-ci-verdict.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pcv-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fx"

# Stub gh: serves the canned PR rollup, ruleset pages and branch protection, so the real jq program is what gets exercised.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$FIXTURE_DIR/pr.json"; exit 0 ;;
esac
for a in "$@"; do
  case "$a" in
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

def run(name, conclusion, status="COMPLETED", workflow="CI"):
    return {"__typename": "CheckRun", "name": name, "status": status,
            "conclusion": conclusion, "workflowName": workflow}

def ctx(name, state):
    return {"__typename": "StatusContext", "context": name, "state": state}

def ruleset(*names):
    return {"type": "required_status_checks",
            "parameters": {"required_status_checks": [{"context": n} for n in names]}}

def branch(*names):
    return {"protection": {"required_status_checks": {"contexts": list(names)}}}

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
}

for name, (rollup, rules, br) in scenarios.items():
    d = os.path.join(fx, name)
    os.makedirs(d, exist_ok=True)
    pr = {"headRefOid": HEAD, "baseRefName": "main", "statusCheckRollup": rollup}
    open(os.path.join(d, "pr.json"), "w").write(json.dumps(pr))
    open(os.path.join(d, "rules.json"), "w").write("\n".join(json.dumps(p) for p in rules))
    open(os.path.join(d, "branch.json"), "w").write(json.dumps(br))
open(os.path.join(fx, "rules_fail", "rules.fail"), "w").write("")
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
