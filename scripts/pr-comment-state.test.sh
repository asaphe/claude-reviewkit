#!/usr/bin/env bash
# Pins the sweep contract: bodies are untrusted, so they truncate and lose invisible characters before display.

# -e is deliberately absent: this harness tallies failures and exits on the count.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/pr-comment-state.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pcs-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fx"

# Stub gh: serves a canned GraphQL page per connection, so the real jq program is what gets exercised.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *"reviewThreads(first:"*) cat "$FIXTURE_DIR/threads.json"; exit 0 ;;
    *"reviews(first:"*)       cat "$FIXTURE_DIR/reviews.json";  exit 0 ;;
    *"comments(first:100"*)   cat "$FIXTURE_DIR/comments.json"; exit 0 ;;
  esac
done
echo "stub gh: unrecognized invocation: $*" >&2
exit 1
STUB
chmod +x "$WORK/bin/gh"

export PATH="$WORK/bin:$PATH"
export GH_REPO="example-org/example-repo"
export FIXTURE_DIR="$WORK/fx"

python3 - "$WORK/fx" <<'PYGEN'
import json, os, sys
fx = sys.argv[1]

# The sentinel sits past the 200-char snip cap, so its absence proves truncation still fires.
LONG = "Scan results. " + ("finding detail padding. " * 20) + "TAILSENTINELMUSTNOTAPPEAR"

# Every class scrub() must neutralise: zero-width, bidi override, BOM, line/para separator, C0 and C1 controls.
INVISIBLES = (
    "zwsp​X rlo‮X bom﻿X lsep X psep X "
    "esc\x1b[31mX c1csi[31mX del\x7fX"
)

# A body of nothing but invisibles must not read as content, or it inflates the gate count.
INVISIBLE_ONLY = "​‮﻿ "

def page(conn, nodes):
    return json.dumps({"data": {"repository": {"pullRequest": {conn: {"nodes": nodes}}}}})

def conv(cid, login, body, typename="Bot", minimized=False):
    return {"id": cid, "author": {"login": login, "__typename": typename},
            "body": body, "url": "https://example.invalid/c/" + cid, "isMinimized": minimized}

def review(rid, login, state, body, typename="Bot", minimized=False):
    return {"id": rid, "author": {"login": login, "__typename": typename}, "state": state,
            "body": body, "isMinimized": minimized, "url": "https://example.invalid/r/" + rid}

def thread(tid, resolved, body, login="someone", typename="User"):
    return {"id": tid, "isResolved": resolved, "isOutdated": False,
            "path": "src/x.py", "line": 7,
            "comments": {"totalCount": 1, "nodes": [
                {"id": tid + "c", "author": {"login": login, "__typename": typename},
                 "body": body, "url": "https://example.invalid/t/" + tid}]}}

scenarios = {
    # Long body from a bot, plus a human thread: exercises truncation and both author labels at once.
    "long": {
        "comments": [conv("IC_long", "github-actions[bot]", LONG)],
        "reviews": [],
        "threads": [thread("PRRT_h", False, "please rename this")],
    },
    # Invisible and control characters arriving through all three buckets.
    "invisible": {
        "comments": [conv("IC_inv", "github-actions[bot]", INVISIBLES)],
        "reviews": [review("PRR_inv", "reviewer", "COMMENTED", INVISIBLES, "User")],
        "threads": [thread("PRRT_inv", False, INVISIBLES)],
    },
    # A review body made only of invisibles: must not count as content, so nothing is unaddressed.
    "invisible_only": {
        "comments": [],
        "reviews": [review("PRR_io", "reviewer", "COMMENTED", INVISIBLE_ONLY, "User")],
        "threads": [],
    },
    # Nothing outstanding anywhere: the clean exit path.
    "clean": {
        "comments": [],
        "reviews": [review("PRR_a", "reviewer", "APPROVED", "", "User")],
        "threads": [thread("PRRT_r", True, "done")],
    },
    # One unresolved thread: the unaddressed exit path.
    "dirty": {
        "comments": [],
        "reviews": [],
        "threads": [thread("PRRT_u", False, "still broken")],
    },
}

for name, s in scenarios.items():
    d = os.path.join(fx, name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "comments.json"), "w").write(page("comments", s["comments"]))
    open(os.path.join(d, "reviews.json"), "w").write(page("reviews", s["reviews"]))
    open(os.path.join(d, "threads.json"), "w").write(page("reviewThreads", s["threads"]))
PYGEN

PASS=0
FAIL=0

run() { # run <scenario> — emits the sweep output, preserving the exit code in $RUN_RC
  FIXTURE_DIR="$WORK/fx/$1" "$SUT" 9999
  RUN_RC=$?
}

want() { # want <name> <scenario> <substring>
  local name="$1" out
  out=$(run "$2")
  case "$out" in
    *"$3"*) PASS=$((PASS + 1)); printf 'ok   %s\n' "$name" ;;
    *) FAIL=$((FAIL + 1)); printf 'FAIL %s: output missing %s\n%s\n' "$name" "$3" "$out" ;;
  esac
}

want_not() { # want_not <name> <scenario> <substring>
  local name="$1" out
  out=$(run "$2")
  case "$out" in
    *"$3"*) FAIL=$((FAIL + 1)); printf 'FAIL %s: output should not contain %s\n%s\n' "$name" "$3" "$out" ;;
    *) PASS=$((PASS + 1)); printf 'ok   %s\n' "$name" ;;
  esac
}

want_exit() { # want_exit <name> <scenario> <code>
  local name="$1"
  run "$2" >/dev/null
  if [ "$RUN_RC" -eq "$3" ]; then
    PASS=$((PASS + 1)); printf 'ok   %s (exit %s)\n' "$name" "$RUN_RC"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s: want exit %s, got %s\n' "$name" "$3" "$RUN_RC"
  fi
}

# want_absent_bytes <name> <scenario> <python-escape> — byte-level, because a capture cannot hold a NUL.
want_absent_bytes() {
  local name="$1" scen="$2" esc="$3" out hits
  out=$(run "$scen")
  hits=$(printf '%s' "$out" | python3 -c 'import sys; print(sys.stdin.buffer.read().count('"$esc"'))')
  if [ "$hits" -eq 0 ]; then
    PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s: %s occurrences of %s survived\n' "$name" "$hits" "$esc"
  fi
}

# Truncation still fires, and both author labels render.
want 'long body is truncated'            long '...'
want_not 'long body tail is cut'         long 'TAILSENTINELMUSTNOTAPPEAR'
want 'bot author labelled'               long '[bot]'
want 'human author labelled'             long '[human]'

# Every invisible class is neutralised in every bucket that prints a body.
want_absent_bytes 'zero-width space stripped'   invisible "b'\\xe2\\x80\\x8b'"
want_absent_bytes 'bidi override stripped'      invisible "b'\\xe2\\x80\\xae'"
want_absent_bytes 'BOM stripped'                invisible "b'\\xef\\xbb\\xbf'"
want_absent_bytes 'line separator stripped'     invisible "b'\\xe2\\x80\\xa8'"
want_absent_bytes 'para separator stripped'     invisible "b'\\xe2\\x80\\xa9'"
want_absent_bytes 'C0 escape stripped'          invisible "b'\\x1b'"
want_absent_bytes 'C1 CSI stripped'             invisible "b'\\xc2\\x9b'"
want_absent_bytes 'DEL stripped'                invisible "b'\\x7f'"

# The surrounding text must survive: stripping is not blanking.
want 'visible text survives scrubbing'   invisible 'zwsp'

# A body of only invisibles is not content, so it must not raise the gate count.
want 'invisible-only body is not content' invisible_only 'UNADDRESSED=0'
want_exit 'invisible-only body exits clean' invisible_only 0

# Exit contract.
want_exit 'clean tree exits 0'           clean 0
want_exit 'unresolved thread exits 3'    dirty 3
want 'unresolved thread is counted'      dirty 'UNADDRESSED=1'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
