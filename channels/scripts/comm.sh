#!/usr/bin/env bash
# The one way to touch the shared statement log. Every agent must use this
# script: two lock schemes (flock vs lockf vs mkdir) do not exclude each other,
# so a private helper silently reintroduces duplicate sequence numbers.
#
#   comm.sh join [--runtime <uuid>] <session-name> <what...>
#                                                mint your ID (or recover it) and
#                                                post the joined line; $3 is the ID
#   comm.sh say  <id> <statement...>             append one statement
#   comm.sh read [after-seq] [--not <id>] [--for <id>]
#                                                statements after after-seq
#   comm.sh wait <after-seq> [timeout] [--not <id>] [--for <id>]
#                                                block until one exists
#   comm.sh dir                                  print the channel directory
#
# IDs are 8 hex characters, minted by `join`; the log is the only record of
# them, and an ID already in it is never reissued. A joined line starts
# `joined: runtime <uuid>, session ...` (`runtime -` when none was given), and
# `join --runtime` reuses the ID of an earlier line with exactly that runtime
# (posting `rejoined:`), so a resumed agent keeps its identity with no state
# beyond the log. The lookup, the minting and the joined line happen under one
# lock, so two joins for the same runtime can't both mint.
#
# The newline is the commit point. Writers append whole lines under the lock
# and refuse a log whose last line is unfinished; readers work from a snapshot
# holding complete lines only, so a half-written line is never returned and a
# reader's cursor can't move past it.
#
# `say` refuses an ID with no joined line, so a typo can't mint one, and
# after writing it prints what others posted since your previous statement --
# anything you may have answered without reading. `--not <id>` hides that
# agent's own lines, so a watcher doesn't wake on its own posts. `--for <id>`
# keeps only statements that need <id> to act: addressed to it ("To <id>:",
# a prefix of it at least 4 characters long, or "To all:"), not its own, and
# not marked "No reply needed" -- what an idle agent's watcher, or wake.sh,
# should wake on. `read` warns on stderr if sequence numbers repeat, skip or
# run backwards.
#
# The log is found from this script's own location, not the caller's working
# directory: .agents/channels in the MAIN checkout of the git repo the script
# sits in (through git's common dir, so a copy inside a worktree still reaches
# the one shared log), or the folder above scripts/ outside a git repo.
# AGENT_COMM_DIR overrides it (use that for tests).
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
HERE="$(cd "$(dirname "$(readlink -f "$SELF" 2>/dev/null || echo "$SELF")")" && pwd)"

if [ -n "${AGENT_COMM_DIR:-}" ]; then
  DIR="$AGENT_COMM_DIR"
elif common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  DIR="$(dirname "$common")/.agents/channels"
else
  DIR="$(dirname "$HERE")"
fi
LOG="$DIR/statements.log"

valid_id() {
  [[ "$1" =~ ^[A-Za-z0-9-]+$ ]] || { echo "comm.sh: invalid id '$1' (letters, digits and '-' only)" >&2; exit 2; }
}

ends_mid_line() {
  [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -c | tr -d ' ')" != '\n' ]
}

# Run this script's internal command "$@" under the exclusive lock. lockf on
# macOS, flock on Linux; both take flock(2) on the same file, so they exclude
# each other. Internal commands never take the lock again.
locked() {
  mkdir -p "$DIR"
  touch "$LOG"
  if command -v lockf >/dev/null; then lockf -k "$LOG.lock" bash "$SELF" "$@"
  elif command -v flock >/dev/null; then flock "$LOG.lock" bash "$SELF" "$@"
  else echo "comm.sh: need lockf or flock" >&2; exit 1
  fi
}

# --- Under the lock --------------------------------------------------------

# Append "<seq> <ts> <id> <msg>" and print it. Printing from inside the lock
# means a concurrent writer can never be reported as your line.
write_line() {
  local id="$1" msg="$2" last line
  if ends_mid_line "$LOG"; then
    echo "comm.sh: log ends mid-line; refusing to append. Last line:" >&2
    tail -n 1 "$LOG" >&2; echo >&2
    exit 1
  fi
  last="$(tail -n 1 "$LOG" | cut -d' ' -f1)"
  line="$(( ${last:-0} + 1 )) $(date -u +%Y-%m-%dT%H:%M:%SZ) $id $msg"
  printf '%s\n' "$line" >> "$LOG"
  printf '%s\n' "$line"
}

# The ID an earlier joined line recorded for runtime $1, if any. Only the
# runtime field itself is compared, never the free text after it.
id_for_runtime() {
  awk -v rt="$1" '
    ($4 == "joined:" || $4 == "rejoined:") && $5 == "runtime" && $6 == rt "," { print $3; exit }
  ' "$LOG"
}

# Whether $1 wrote any line, joined or not.
has_posted() {
  awk -v id="$1" '$3 == id { f = 1; exit } END { exit !f }' "$LOG"
}

# Whether $1 wrote a joined or rejoined line: the log's only record of who has
# joined.
has_joined() {
  awk -v id="$1" '$3 == id && ($4 == "joined:" || $4 == "rejoined:") { f = 1; exit } END { exit !f }' "$LOG"
}

# A fresh 8-hex ID that never wrote a line, so none is ever reissued. Minting
# runs under the lock, so two joins can't both take it.
mint_id() {
  local id
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    id="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    has_posted "$id" || { echo "$id"; return; }
  done
  echo "comm.sh: could not mint a free ID" >&2; exit 1
}

# --- Readers ---------------------------------------------------------------

# SNAP: a private copy of the log holding complete lines only. TORN: set when
# the live log ended in an unfinished line, which the copy leaves out.
SNAP="" TORN=""
cleanup() { [ -z "$SNAP" ] || rm -f "$SNAP"; }
trap cleanup EXIT
snapshot() {
  [ -n "$SNAP" ] || SNAP="$(mktemp)"
  TORN=""
  if [ -f "$LOG" ]; then cat "$LOG" > "$SNAP"; else : > "$SNAP"; fi
  if ends_mid_line "$SNAP"; then
    TORN=1
    # wc -l counts newlines, i.e. complete lines.
    head -n "$(wc -l < "$SNAP")" "$SNAP" > "$SNAP.c"; mv "$SNAP.c" "$SNAP"
  fi
}

warn_torn() {
  [ -z "$TORN" ] || echo "comm.sh: WARNING the log's last line is unfinished (a write in progress, or a writer died); it is not shown" >&2
}

select_after() {
  awk -v a="$1" -v not="$2" -v for_id="$FOR" -f <(actionable_awk) "$SNAP"
}

# Statements after `a`, minus author `not`; with `for_id`, only those that
# need that agent to act. A word of the "To ...:" header addresses the agent
# when it is "all", or a prefix of its ID at least 4 characters long. A prefix
# shared by two agents addresses both.
actionable_awk() {
  cat <<'AWK'
  $1 <= a || $3 == not { next }
  for_id == "" { print; next }
  $3 == for_id || index($0, "No reply needed") { next }
  {
    text = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", text)
    if (text !~ /^To [^:]*:/) next
    n = split(substr(text, 4, index(text, ":") - 4), word, /[ ,]+/)
    for (i = 1; i <= n; i++) {
      w = word[i]; gsub(/^[^A-Za-z0-9-]+|[^A-Za-z0-9-]+$/, "", w)
      if (w == "all" || (length(w) >= 4 && index(for_id, w) == 1)) { print; next }
    }
  }
AWK
}

check_sequence() {
  awk '
    $1 != NR { printf "comm.sh: WARNING line %d has sequence %s; duplicate, skipped or out of order\n", NR, $1 }
  ' "$SNAP" >&2
}

# What others posted between $1's previous statement and its latest one.
since_previous() {
  snapshot
  awk -v me="$1" '
    { line[NR] = $0; who[NR] = $3 }
    $3 == me { prev = cur; cur = NR }
    END {
      if (!prev) exit
      for (i = prev + 1; i < cur; i++) if (who[i] != me) { if (!h++) print "-- posted by others since your previous statement:"; print line[i] }
    }
  ' "$SNAP" >&2
}

# Pull `--not <id>` and `--for <id>` out of the arguments; the rest land in ARGS.
NOT=""; FOR=""; ARGS=()
parse_filters() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --not) NOT="${2:?--not needs an id}"; shift 2 ;;
      --for) FOR="${2:?--for needs an id}"; shift 2 ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done
}

cmd="${1:-}"; shift || true
case "$cmd" in
  # Internal: run by `locked`, already holding the lock.
  _say)
    has_joined "$1" || { echo "comm.sh: '$1' has not joined; run 'comm.sh join' first (typo?)" >&2; exit 1; }
    write_line "$1" "$2"
    ;;
  _join)
    runtime="$1" name="$2" what="$3" id="" verb="joined:"
    [ "$runtime" = "-" ] || id="$(id_for_runtime "$runtime")"
    if [ -n "$id" ]; then verb="rejoined:"; else id="$(mint_id)"; fi
    write_line "$id" "$verb runtime $runtime, session $name, cwd $PWD, working on $what"
    ;;

  join)
    runtime="-"
    if [ "${1:-}" = "--runtime" ]; then runtime="${2:?--runtime needs a uuid}"; shift 2; valid_id "$runtime"; fi
    [ $# -ge 2 ] || { echo "usage: comm.sh join [--runtime <uuid>] <session-name> <what...>" >&2; exit 2; }
    name="$(printf '%s' "$1" | tr '\n' ' ')"; shift
    what="$(printf '%s' "$*" | tr '\n' ' ')"
    line="$(locked _join "$runtime" "$name" "$what")"
    printf '%s\n' "$line"
    since_previous "$(echo "$line" | cut -d' ' -f3)"
    ;;
  say)
    [ $# -ge 2 ] || { echo "usage: comm.sh say <id> <statement...>" >&2; exit 2; }
    id="$1"; shift
    valid_id "$id"
    locked _say "$id" "$(printf '%s' "$*" | tr '\n' ' ')"
    since_previous "$id"
    ;;
  read)
    parse_filters "$@"
    snapshot
    check_sequence
    warn_torn
    select_after "${ARGS[0]:-0}" "$NOT"
    ;;
  wait)
    parse_filters "$@"
    after="${ARGS[0]:?usage: comm.sh wait <after-seq> [timeout] [--not <id>] [--for <id>]}"
    timeout="${ARGS[1]:-300}"
    end=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$end" ]; do
      snapshot
      out="$(select_after "$after" "$NOT")"
      if [ -n "$out" ]; then printf '%s\n' "$out"; exit 0; fi
      sleep 3
    done
    echo "comm.sh: nothing after $after in ${timeout}s" >&2; exit 1
    ;;
  dir) echo "$DIR" ;;
  *) sed -n '2,/^set -euo/p' "$SELF" | sed '$d'; exit 2 ;;
esac
