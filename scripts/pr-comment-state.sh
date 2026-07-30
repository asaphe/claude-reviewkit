#!/usr/bin/env bash
# Complete 3-bucket PR comment-state sweep — `gh pr view --json comments` misses inline threads + review bodies.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: pr-comment-state.sh <PR_NUMBER>

Read-only sweep of every place PR feedback lives, fully paginated:
  (a) conversation comments     — pullRequest.comments
  (b) review-submission bodies  — pullRequest.reviews (state + isMinimized)
  (c) inline review threads     — pullRequest.reviewThreads (isResolved + isOutdated)

Repo: $GH_REPO (owner/name) if set, else `gh repo view`.
Fails loud on any API error — never prints "none" on a failed query.

Exit codes:
  0  clean — no unaddressed feedback
  1  hard error (API failure, PR not found, repo unresolved)
  2  usage error
  3  unaddressed feedback remains (see UNADDRESSED=N line) — includes reviews
     dismissed but not yet minimized: dismiss clears blocking state but does
     NOT hide the comment body, so it counts as unaddressed until minimized too
EOF
  exit 2
}

PR_NUMBER="${1:-}"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || usage

# Repo derivation is detached-worktree safe — NEVER hardcode owner/name.
REPO="${GH_REPO:-}"
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner')" || {
    echo "ERROR: could not determine repo — set GH_REPO=owner/name or run inside a gh-resolvable repo." >&2
    exit 1
  }
fi
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# fetch_bucket <connection> <query> — paginates, fails loud on GraphQL errors / missing PR, emits the nodes array.
fetch_bucket() {
  local conn="$1" query="$2" raw
  raw="$(gh api graphql --paginate -F pr="$PR_NUMBER" -f owner="$OWNER" -f name="$NAME" -f query="$query")" || {
    echo "ERROR: GraphQL request failed for PR #$PR_NUMBER in $REPO ($conn)." >&2
    exit 1
  }
  if [[ -n "$(jq -s 'map(.errors // empty) | add // [] | .[]' <<<"$raw")" ]]; then
    echo "ERROR: GraphQL returned errors for PR #$PR_NUMBER ($conn):" >&2
    jq -s 'map(.errors // empty) | add' <<<"$raw" >&2
    exit 1
  fi
  if [[ "$(jq -s 'first | .data.repository.pullRequest // "null"' <<<"$raw")" == '"null"' ]]; then
    echo "ERROR: PR #$PR_NUMBER not found in $REPO (or no access)." >&2
    exit 1
  fi
  jq -s "[ .[].data.repository.pullRequest.${conn}.nodes[] ]" <<<"$raw"
}

# shellcheck disable=SC2016  # $owner/$name/$pr/$endCursor are GraphQL variables, not shell expansions
THREADS_Q='query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$pr){
      reviewThreads(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{
          id isResolved isOutdated path line
          comments(first:1){ totalCount nodes{ id author{login __typename} body url } }
        }
      }
    }
  }
}'

# shellcheck disable=SC2016  # GraphQL variables, not shell expansions
REVIEWS_Q='query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$pr){
      reviews(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{ id author{login __typename} state body isMinimized url }
      }
    }
  }
}'

# shellcheck disable=SC2016  # GraphQL variables, not shell expansions
CONV_Q='query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$pr){
      comments(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{ id author{login __typename} body url isMinimized }
      }
    }
  }
}'

THREADS_RAW="$(fetch_bucket reviewThreads "$THREADS_Q")"
REVIEWS_RAW="$(fetch_bucket reviews "$REVIEWS_Q")"
CONV_RAW="$(fetch_bucket comments "$CONV_Q")"

# UNADDRESSED counts only the buckets whose addressed-state is machine-determinable (unresolved threads + actionable review bodies).
RESULT="$(jq -n \
  --argjson threads "$THREADS_RAW" \
  --argjson reviews "$REVIEWS_RAW" \
  --argjson conv "$CONV_RAW" \
  --arg pr "$PR_NUMBER" \
  --arg repo "$REPO" '
  def isbot(a): a as $x
    | (($x.__typename // "User") == "Bot")
    or (($x.login // "") | endswith("[bot]"));
  def who(b): if b then "[bot]  " else "[human]" end;
  def snip(s): ((s // "") | gsub("\\s+";" ")
                | if (length > 200) then (.[0:197] + "...") else . end);

  ($threads | map({
     tid: .id,
     cid: ((.comments.nodes[0].id) // ""),
     isResolved, isOutdated,
     path, line: (.line // "?"),
     total: (.comments.totalCount // 0),
     author: ((.comments.nodes[0].author.login) // "unknown"),
     isBot: isbot(.comments.nodes[0].author // {}),
     body: ((.comments.nodes[0].body) // ""),
     url: ((.comments.nodes[0].url) // "")
   })) as $T |
  ($reviews | map({
     rid: .id,
     author: ((.author.login) // "unknown"),
     isBot: isbot(.author // {}),
     state, isMinimized, body: (.body // ""), url
   }
   | .has_content = ((.body | gsub("\\s";"") | length) > 0)
   | .actionable = ((.state == "CHANGES_REQUESTED")
                    or (.state == "COMMENTED" and .has_content and (.isMinimized == false)))
   | .needs_minimize = ((.actionable | not) and (.state == "DISMISSED")
                        and .has_content and (.isMinimized == false)))) as $R |
  ($conv | map({
     cid: .id,
     author: ((.author.login) // "unknown"),
     isBot: isbot(.author // {}),
     body: (.body // ""), url, isMinimized
   })) as $C |

  ($T | map(select(.isResolved | not)))                            as $unresolved |
  ($T | map(select(.isResolved and .isOutdated)))                  as $resOutdated |
  ($T | map(select(.isResolved and (.isOutdated | not))))          as $resClean |
  ($R | map(select(.actionable))) as $actReviews |
  ($R | map(select(.needs_minimize))) as $needsMinReviews |
  ($C | map(select(.isMinimized | not))) as $activeConv |
  ($C | map(select(.isMinimized)))       as $minimizedConv |

  (($unresolved | length) + ($actReviews | length) + ($needsMinReviews | length)) as $unaddressed |

  ([ "=== PR #\($pr) — \($repo) — comment-state sweep ===",
     "" ,
     "INLINE REVIEW THREADS: \($T|length) total  (\($unresolved|length) unresolved, \($resOutdated|length) resolved-outdated, \($resClean|length) resolved)",
     "" ,
     "-- UNRESOLVED (\($unresolved|length)) --"
   ]
   + ( if ($unresolved|length)==0 then ["  (none)"]
       else ($unresolved | map(
         "  \(who(.isBot)) @\(.author)  \(.path):\(.line)\(if .isOutdated then "  [outdated]" else "" end)\(if .total>1 then "  (+\(.total-1) replies)" else "" end)\n      \(snip(.body))\n      \(.url)\n      resolve: thread=\(.tid) comment=\(.cid)"))
       end )
   + [ "" , "-- RESOLVED-OUTDATED (\($resOutdated|length)) --" ]
   + ( if ($resOutdated|length)==0 then ["  (none)"]
       else ($resOutdated | map("  \(who(.isBot)) @\(.author)  \(.path):\(.line)  thread=\(.tid)")) end )
   + [ "" , "-- RESOLVED (\($resClean|length)) --" ]
   + ( if ($resClean|length)==0 then ["  (none)"]
       else ($resClean | map("  \(who(.isBot)) @\(.author)  \(.path):\(.line)  thread=\(.tid)")) end )

   + [ "" , "REVIEW-SUBMISSION BODIES: \($R|length) total" ,
     "" , "-- ACTIONABLE (changes-requested until dismissed, or non-minimized commented) (\($actReviews|length)) --" ]
   + ( if ($actReviews|length)==0 then ["  (none)"]
       else ($actReviews | map(
         "  \(who(.isBot)) @\(.author)  [\(.state)]\n      \(snip(.body))\n      \(.url)\n      \(if .state=="CHANGES_REQUESTED" then "address findings, then dismiss — minimize alone leaves blocking state" else "address findings first, then minimize" end): review=\(.rid)")) end )
   + [ "" , "-- DISMISSED BUT NOT MINIMIZED (\($needsMinReviews|length)) -- dismiss only clears blocking state; the comment stays fully visible until minimized too" ]
   + ( if ($needsMinReviews|length)==0 then ["  (none)"]
       else ($needsMinReviews | map("  \(who(.isBot)) @\(.author)  [\(.state)]\n      \(snip(.body))\n      \(.url)\n      \(if .isBot then "minimize to close the loop" else "read before minimizing — a dismissed human review may still hold an open question" end): review=\(.rid)")) end )
   + [ "" , "-- OTHER REVIEW BODIES (approved / dismissed+minimized / commented+minimized / no body) --" ]
   + ( ($R | map(select((.actionable or .needs_minimize) | not))) as $other
       | if ($other|length)==0 then ["  (none)"]
         else ($other | map("  \(who(.isBot)) @\(.author)  [\(.state)]\(if .isMinimized then " (minimized)" else "" end)\(if (.has_content|not) then " (no body)" else "" end)  review=\(.rid)")) end )

   + [ "" , "CONVERSATION COMMENTS: \($C|length) total (\($activeConv|length) active, \($minimizedConv|length) minimized)  (no isResolved field — judge each from content: stale/superseded bot comment or unambiguously-addressed human comment -> minimize, open human ask -> flag, never minimize on judgment alone)" ]
   + ( if ($activeConv|length)==0 then ["  (none)"]
       else ($activeConv | map("  \(who(.isBot)) @\(.author)\n      \(snip(.body))\n      \(.url)\n      " + (if .isBot then "possible minimize candidate (verify staleness): comment=\(.cid)" else "minimize if unambiguously addressed, else flag if open: comment=\(.cid)" end))) end )
   + [ "" , "-- MINIMIZED (\($minimizedConv|length)) --" ]
   + ( if ($minimizedConv|length)==0 then ["  (none)"]
       else ($minimizedConv | map("  \(who(.isBot)) @\(.author)  comment=\(.cid)")) end )
   | join("\n")) as $report |

  { report: $report,
    unaddressed: $unaddressed,
    unresolved_threads: ($unresolved|length),
    actionable_reviews: ($actReviews|length),
    needs_minimize_reviews: ($needsMinReviews|length),
    conversation_comments: ($C|length) }
')"

UNADDRESSED="$(jq -r '.unaddressed' <<<"$RESULT")"
jq -r '.report' <<<"$RESULT"
echo ""
echo "UNADDRESSED=$UNADDRESSED"

# Guard the gate: a non-numeric/empty count must error, never read as a false clean.
[[ "$UNADDRESSED" =~ ^[0-9]+$ ]] || { echo "ERROR: internal — non-numeric UNADDRESSED ('$UNADDRESSED')." >&2; exit 1; }
[[ "$UNADDRESSED" -eq 0 ]] && exit 0 || exit 3
