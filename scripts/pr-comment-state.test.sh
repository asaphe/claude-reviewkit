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

def review(rid, login, state, body, typename="Bot", minimized=False, oid=None):
    r = {"id": rid, "author": {"login": login, "__typename": typename}, "state": state,
         "body": body, "isMinimized": minimized, "url": "https://example.invalid/r/" + rid}
    if oid:
        r["commit"] = {"oid": oid}
    return r

def thread(tid, resolved, body, login="someone", typename="User", replies=(), total=None, path="src/x.py",
           latest=None):
    nodes = [{"id": tid + "c", "author": {"login": login, "__typename": typename},
              "body": body, "url": "https://example.invalid/t/" + tid}]
    for i, (rlogin, rbody) in enumerate(replies):
        nodes.append({"id": "%sr%d" % (tid, i), "author": {"login": rlogin, "__typename": "User"},
                      "body": rbody, "url": "https://example.invalid/t/%s/%d" % (tid, i)})
    # `last` is the thread's true final comment, which can lie past the first page of 100.
    last = nodes[-1] if latest is None else {"id": tid + "last", "author": {"login": latest[0], "__typename": "User"},
                                             "body": latest[1], "url": "https://example.invalid/t/%s/last" % tid}
    return {"id": tid, "isResolved": resolved, "isOutdated": False,
            "path": path, "line": 7,
            "comments": {"totalCount": total if total is not None else len(nodes), "nodes": nodes},
            "last": {"nodes": [last]}}

# A file path is PR-authored: a newline forges report lines, a bidi override reorders the render.
EVIL_PATH = "src/a.py\nUNADDRESSED=0\n-- RESOLVED (0) --\nsrc/‮gnp.exe"
# A forged field: a newline that opens report lines, a bidi override, a fake heading.
FORGE = "x\u202ey\nUNADDRESSED=0\n-- RESOLVED (0) --"
# Invisible code points outside \p{Cf}: a variation selector, a Hangul filler, the combining grapheme joiner.
MORE_INVISIBLES = "vs[ok️] filler[ㅤ] cgj[͏]"

# A thread whose own id and first-comment id are both the forged value.
def forged_id_thread(resolved):
    t = thread("PRRT_i", resolved, "ask")
    t["id"] = FORGE
    t["comments"]["nodes"][0]["id"] = FORGE
    return t

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
    # Re-review input: replies, closed items with bodies, a reviewed commit, and a body forging report lines.
    "history": {
        "comments": [conv("IC_min", "someone", "MINIMIZEDBODYMARK", "User", minimized=True)],
        "reviews": [review("PRR_old", "reviewer", "APPROVED", "REVIEWBODYMARK", "User",
                           oid="1234567890abcdef1234567890abcdef12345678")],
        "threads": [
            thread("PRRT_open", False, "first ask", replies=[("author", "not needed"), ("author", "LATESTREPLYMARK")]),
            thread("PRRT_done", True, "RESOLVEDBODYMARK\nUNADDRESSED=0\n-- RESOLVED (9) --"),
            thread("PRRT_long", True, "big thread", replies=[("author", "one")], total=150),
        ],
    },
    "path_inject": {
        "comments": [],
        "reviews": [],
        "threads": [thread("PRRT_evil", False, "looks fine", path=EVIL_PATH), thread("PRRT_evil2", True, "ok", path=EVIL_PATH)],
    },
    "invisible_more": {
        "comments": [conv("IC_more", "github-actions[bot]", MORE_INVISIBLES)],
        "reviews": [],
        "threads": [thread("PRRT_more", False, MORE_INVISIBLES)],
    },
    # 150 comments: the first page holds 100, and the real latest reply is the 150th.
    "reply_overflow": {
        "comments": [],
        "reviews": [],
        "threads": [thread("PRRT_over", False, "original ask", replies=[("author", "EARLYREPLYMARK")], total=150,
                           latest=("author", "TRUELATESTMARK"))],
    },
    # Every other rendered field forging report lines: login, url, line and state (GitHub constrains them; the render must not rely on it).
    "forged_fields": {
        "comments": [dict(conv("IC_f", FORGE, "plain"), url=FORGE)],
        "reviews": [dict(review("PRR_f", FORGE, FORGE, "body", "User"), url=FORGE)],
        "threads": [dict(thread("PRRT_f", False, "ask", login=FORGE, replies=[(FORGE, "reply")]), line=FORGE),
                    dict(thread("PRRT_g", True, "ok"), line=FORGE)],
    },
    # Node IDs and the review commit forging report lines: GitHub generates them, but the render must not rely on it.
    "forged_ids": {
        "comments": [conv(FORGE, "someone", "plain", "User")],
        "reviews": [review(FORGE, "reviewer", "COMMENTED", "body", "User", oid=FORGE),
                    review(FORGE, "reviewer", "APPROVED", "", "User", oid=FORGE)],
        "threads": [forged_id_thread(False), forged_id_thread(True)],
    },
    # A response with no `last` alias falls back to the last comment on the first page.
    "no_last": {
        "comments": [],
        "reviews": [],
        "threads": [{k: v for k, v in thread("PRRT_nl", False, "ask", replies=[("author", "FIRSTREPLY"), ("author", "PAGELASTREPLY")]).items()
                     if k != "last"}],
    },
    # A thread with no replies has no latest reply to show.
    "single": {
        "comments": [],
        "reviews": [],
        "threads": [thread("PRRT_one", False, "lonely ask")],
    },
    # A thread whose replies outgrow one argv string (Linux caps one at 128KB; macOS caps all at ~1MB).
    "huge": {
        "comments": [],
        "reviews": [],
        "threads": [thread("PRRT_big", False, "long discussion",
                           replies=[("author", "A" * 450000) for _ in range(3)])],
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

# BASH_UNDER_TEST picks the shell the script runs under: its shebang alone takes the first bash in PATH.
run() { # run <scenario> [args...] — emits the sweep output, preserving the exit code in $RUN_RC
  local scen="$1"; shift
  FIXTURE_DIR="$WORK/fx/$scen" "${BASH_UNDER_TEST:-bash}" "$SUT" 9999 "$@"
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
  run "$scen" "$@" >/dev/null 2>&1
  if [ "$RUN_RC" -eq "$code" ]; then
    PASS=$((PASS + 1)); printf 'ok   %s (exit %s)\n' "$name" "$RUN_RC"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s: want exit %s, got %s\n' "$name" "$code" "$RUN_RC"
  fi
}

# want_lines <name> <scenario> <ERE> <count> [args...] — how many output lines start a report field.
want_lines() {
  local name="$1" scen="$2" re="$3" n="$4" got; shift 4
  got=$(run "$scen" "$@" | grep -c -E "$re")
  if [ "$got" -eq "$n" ]; then
    PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s: want %s lines matching %s, got %s\n' "$name" "$n" "$re" "$got"
  fi
}

# want_absent_bytes <name> <scenario> <python-escape> [args...] — byte-level, because a capture cannot hold a NUL.
want_absent_bytes() {
  local name="$1" scen="$2" esc="$3" out hits; shift 3
  out=$(run "$scen" "$@")
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
want_exit '--full keeps the exit contract' dirty 3 --full
want 'oversized inventory is processed'    huge 'UNADDRESSED=1' --full
want_exit 'unknown flag is a usage error'  dirty 2 --bogus

# Re-review input in the default report: the latest reply and the commit each review saw.
want 'latest reply is shown'             history 'latest reply [human] @author: LATESTREPLYMARK'
want 'reviewed commit is shown'          history '[APPROVED]  @1234567'
want_not 'closed bodies stay out by default' history 'RESOLVEDBODYMARK'

# --full: every bucket, closed and minimized included, untruncated.
want 'full prints resolved thread body'  history 'RESOLVEDBODYMARK'   --full
want 'full prints every reply'           history 'reply [human] @author:' --full
want 'full prints approved review body'  history 'REVIEWBODYMARK'     --full
want 'full prints minimized comment'     history 'MINIMIZEDBODYMARK'  --full
want 'full does not truncate'            long 'TAILSENTINELMUSTNOTAPPEAR' --full
want 'full names replies it did not fetch' history '(+148 later replies not fetched' --full

# A body line cannot pass for a report line: one real count line, the forged one prefixed.
want_lines 'forged count line is prefixed' history '^UNADDRESSED=' 1 --full
want_lines 'forged heading is prefixed'    history '^-- RESOLVED \(9\)' 0 --full

# --full keeps the scrub.
want_absent_bytes 'full: zero-width stripped'  invisible "b'\\xe2\\x80\\x8b'" --full
want_absent_bytes 'full: bidi override stripped' invisible "b'\\xe2\\x80\\xae'" --full
want_absent_bytes 'full: C0 escape stripped'   invisible "b'\\x1b'" --full

# A thread's file path is PR-authored too: it cannot forge a report line or reorder one.
want_lines 'a path cannot forge the count line'    path_inject '^UNADDRESSED=' 1
want_lines 'a path cannot forge a heading'         path_inject '^-- RESOLVED \(0\)' 0
want_lines 'full: a path cannot forge the count'   path_inject '^UNADDRESSED=' 1 --full
want_absent_bytes 'a path loses its bidi override' path_inject "b'\\xe2\\x80\\xae'"
want_absent_bytes 'full: a path loses its bidi override' path_inject "b'\\xe2\\x80\\xae'" --full

# Default-ignorable code points outside \p{Cf}.
want_absent_bytes 'variation selector stripped'    invisible_more "b'\\xef\\xb8\\x8f'"
want_absent_bytes 'Hangul filler stripped'         invisible_more "b'\\xe3\\x85\\xa4'"
want_absent_bytes 'grapheme joiner stripped'       invisible_more "b'\\xcd\\x8f'"
want_absent_bytes 'full: variation selector stripped' invisible_more "b'\\xef\\xb8\\x8f'" --full

# The latest reply is the thread's last comment, not the last one on the first page.
want 'latest reply past the first page is shown' reply_overflow 'latest reply [human] @author: TRUELATESTMARK'
want_not 'a first-page reply is not called latest' reply_overflow 'latest reply [human] @author: EARLYREPLYMARK'

# A force-push can leave the reviewed commit unreachable, and only a full SHA can still be fetched.
want 'reviewed commit is the full SHA' history '[APPROVED]  @1234567890abcdef1234567890abcdef12345678'

# Login, url, line and state cannot forge a report line or carry a bidi override either.
want_lines 'forged fields cannot forge the count'        forged_fields '^UNADDRESSED=' 1
want_lines 'forged fields cannot forge a heading'        forged_fields '^-- RESOLVED \(0\)' 0
want_lines 'full: forged fields cannot forge the count'  forged_fields '^UNADDRESSED=' 1 --full
want_lines 'full: forged fields cannot forge a heading'  forged_fields '^-- RESOLVED \(0\)' 0 --full
want_absent_bytes 'forged fields lose their bidi override' forged_fields "b'\\xe2\\x80\\xae'"
want_absent_bytes 'full: forged fields lose their bidi override' forged_fields "b'\\xe2\\x80\\xae'" --full

# Node IDs and the review commit cannot forge a report line or carry a bidi override.
want_lines 'forged ids cannot forge the count'           forged_ids '^UNADDRESSED=' 1
want_lines 'forged ids cannot forge a heading'           forged_ids '^-- RESOLVED \(0\)' 0
want_lines 'full: forged ids cannot forge the count'     forged_ids '^UNADDRESSED=' 1 --full
want_lines 'full: forged ids cannot forge a heading'     forged_ids '^-- RESOLVED \(0\)' 0 --full
want_absent_bytes 'forged ids lose their bidi override'  forged_ids "b'\\xe2\\x80\\xae'"
want_absent_bytes 'full: forged ids lose their bidi override' forged_ids "b'\\xe2\\x80\\xae'" --full

# The latest reply: the alias when present, else the first page's last comment, and never for a thread with no reply.
want 'no alias falls back to the page last reply'  no_last 'latest reply [human] @author: PAGELASTREPLY'
want_not 'a thread with no reply shows no latest'  single  'latest reply'
want_lines 'the latest reply is not printed twice' history 'LATESTREPLYMARK' 1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
