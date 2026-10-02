#!/usr/bin/env bash
# Tests for comm.sh, wake.sh and install.sh. Each case works in its own
# temporary directory; nothing touches a real log.
#
#   tests/run.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMM="$REPO/channels/scripts/comm.sh"
WAKE="$REPO/channels/scripts/wake.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# check <name> <expression>: the expression is evaluated as one shell
# condition, so `[[ ]]` and `&&` work inside it.
PASS=0 FAIL=0
check() {
  if eval "$2"; then PASS=$((PASS + 1)); echo "ok   $1"
  else FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "     $2"
  fi
}

# A fresh channel directory for one case.
fresh() { export AGENT_COMM_DIR="$WORK/c$RANDOM$RANDOM"; mkdir -p "$AGENT_COMM_DIR"; L="$AGENT_COMM_DIR/statements.log"; }
lines() { if [ -f "$L" ]; then wc -l < "$L" | tr -d ' '; else echo 0; fi; }
seqs() { cut -d' ' -f1 | tr '\n' ' '; }
no_gaps() { awk '$1 != NR { bad = 1 } END { exit bad }' "$L"; }
git_repo() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init; }

# --- join -------------------------------------------------------------------
fresh
line="$("$COMM" join --runtime 11111111-0000-0000-0000-000000000001 sess-a "testing" 2>/dev/null)"
A="$(echo "$line" | cut -d' ' -f3)"
check "join mints an 8-hex ID" '[[ "$A" =~ ^[0-9a-f]{8}$ ]]'
check "join posts 'joined: runtime <uuid>, session ...'" \
  '[[ "$line" == "1 "*" $A joined: runtime 11111111-0000-0000-0000-000000000001, session sess-a, cwd "*", working on testing" ]]'
check "join leaves only the log and its lock" '[ "$(ls "$AGENT_COMM_DIR" | tr "\n" " ")" = "statements.log statements.log.lock " ]'
R="$("$COMM" join --runtime 11111111-0000-0000-0000-000000000001 sess-a "again" 2>/dev/null | cut -d' ' -f3,4)"
check "join --runtime again gives back the same ID" '[ "$R" = "$A rejoined:" ]'
B="$("$COMM" join sess-b "no runtime" 2>/dev/null | cut -d' ' -f3)"
C="$("$COMM" join sess-b "no runtime" 2>/dev/null | cut -d' ' -f3)"
check "joins without --runtime mint different IDs" '[ -n "$B" ] && [ "$B" != "$C" ] && [ "$B" != "$A" ]'
"$COMM" join --runtime "a b" s w >/dev/null 2>&1; rc=$?
check "join refuses a runtime with spaces" '[ "$rc" -ne 0 ]'

# --- say --------------------------------------------------------------------
out="$("$COMM" say "$A" "hello there" 2>/dev/null)"
check "say appends and prints the line" '[[ "$out" == "5 "*" $A hello there" ]]'
n="$(lines)"
"$COMM" say deadbeef "typo" 2>/dev/null; rc=$?
check "say refuses an ID that never joined" '[ "$rc" -ne 0 ] && [ "$(lines)" = "$n" ]'
echo "$((n + 1)) 2026-01-01T00:00:00Z cafef00d wrote without joining" >> "$L"
n="$(lines)"
"$COMM" say cafef00d "again" 2>/dev/null; rc=$?
check "say refuses an author with no joined line" '[ "$rc" -ne 0 ] && [ "$(lines)" = "$n" ]'
"$COMM" say "$B" "$(printf 'one\ntwo')" >/dev/null 2>&1
check "say joins a multi-line statement into one line" '[[ "$(tail -n 1 "$L")" == *" $B one two" ]]'
err="$("$COMM" say "$A" "after others" 2>&1 >/dev/null)"
check "say shows what others posted since your previous statement" '[[ "$err" == *"posted by others"*" one two"* ]]'
D="$("$COMM" join sess-d "minting" 2>/dev/null | cut -d' ' -f3)"
d_lines="$(awk -v d="$D" '$3 == d' "$L" | wc -l | tr -d ' ')"
check "a minted ID is new to the log" '[ -n "$D" ] && [ "$D" != cafef00d ] && [ "$d_lines" = 1 ]'

# --- concurrency ------------------------------------------------------------
fresh
for i in $(seq 1 16); do
  ( id="$("$COMM" join "p$i" "parallel" 2>/dev/null | cut -d' ' -f3)"; "$COMM" say "$id" "from p$i" >/dev/null 2>&1 ) &
done
wait
ids="$(awk '$4 == "joined:" { print $3 }' "$L" | sort -u | wc -l | tr -d ' ')"
check "16 parallel join+say: 32 lines" '[ "$(lines)" = 32 ]'
check "16 parallel join+say: no sequence gaps or repeats" 'no_gaps'
check "16 parallel join+say: unique IDs" '[ "$ids" = 16 ]'

# --- torn lines ---------------------------------------------------------------
fresh
A="$("$COMM" join a "torn" 2>/dev/null | cut -d' ' -f3)"
printf '2 2026-01-01T00:00:00Z %s half-writ' "$A" >> "$L"
out="$("$COMM" read 2>"$WORK/err")"
check "read hides an unfinished last line" '[ "$(echo "$out" | seqs)" = "1 " ]'
check "read warns about an unfinished last line" 'grep -q unfinished "$WORK/err"'
"$COMM" say "$A" "more" >/dev/null 2>&1; rc=$?
check "say refuses to append after an unfinished line" '[ "$rc" -ne 0 ]'

# --- read filters -------------------------------------------------------------
fresh
A="$("$COMM" join a "x" 2>/dev/null | cut -d' ' -f3)"
B="$("$COMM" join b "x" 2>/dev/null | cut -d' ' -f3)"
"$COMM" say "$A" "To ${B:0:4}: can you review?" >/dev/null 2>&1      # 3: for B
"$COMM" say "$A" "To all: heads up." >/dev/null 2>&1                 # 4: for B
"$COMM" say "$A" "To $B: thanks. No reply needed." >/dev/null 2>&1   # 5: not for B
"$COMM" say "$A" "general note" >/dev/null 2>&1                      # 6: not addressed
"$COMM" say "$B" "To all: mine" >/dev/null 2>&1                      # 7: B's own
"$COMM" say "$A" "To ${B:0:3}: too short" >/dev/null 2>&1            # 8: prefix < 4
check "read --for keeps only statements that need the agent" '[ "$("$COMM" read 0 --for "$B" 2>/dev/null | seqs)" = "3 4 " ]'
check "read --not hides an author" '[ "$("$COMM" read 0 --not "$A" 2>/dev/null | seqs)" = "2 7 " ]'
check "read <after> starts after that sequence" '[ "$("$COMM" read 6 2>/dev/null | seqs)" = "7 8 " ]'
echo "8 2026-01-01T00:00:00Z $A duplicate" >> "$L"
"$COMM" read >/dev/null 2>"$WORK/err"
check "read warns about a repeated sequence number" 'grep -q "duplicate, skipped or out of order" "$WORK/err"'

# --- wait ---------------------------------------------------------------------
fresh
A="$("$COMM" join a "x" 2>/dev/null | cut -d' ' -f3)"
( sleep 1; "$COMM" say "$A" "To all: wake up" >/dev/null 2>&1 ) &
out="$("$COMM" wait 1 20 2>/dev/null)"; rc=$?
wait
check "wait returns once something newer exists" '[ "$rc" = 0 ] && [[ "$out" == "2 "*"wake up" ]]'
"$COMM" wait 2 1 >/dev/null 2>&1; rc=$?
check "wait times out with a non-zero exit" '[ "$rc" -ne 0 ]'
unset AGENT_COMM_DIR

# --- locating the log ---------------------------------------------------------
P="$WORK/proj"
git_repo "$P"; mkdir -p "$P/sub/deeper" "$P/.agents/channels/scripts"
cp "$COMM" "$P/.agents/channels/scripts/"
S="$P/.agents/channels/scripts/comm.sh"
check "the log is found from a subdirectory" '[[ "$(cd "$P/sub/deeper" && "$S" dir)" == */proj/.agents/channels ]]'
check "the log is found when called from outside the repo" '[[ "$(cd / && "$S" dir)" == */proj/.agents/channels ]]'
git -C "$P" worktree add -q "$WORK/wt" 2>/dev/null
mkdir -p "$WORK/wt/.agents/channels/scripts" && cp "$COMM" "$WORK/wt/.agents/channels/scripts/"
check "a copy inside a worktree uses the main checkout's log" '[[ "$("$WORK/wt/.agents/channels/scripts/comm.sh" dir)" == */proj/.agents/channels ]]'
N="$WORK/nogit/.agents/channels/scripts"
mkdir -p "$N" && cp "$COMM" "$N/"
check "outside git, the log is the folder above scripts/" '[[ "$("$N/comm.sh" dir)" == */nogit/.agents/channels ]]'
ln -s "$S" "$WORK/linked-comm.sh"
check "a symlink to the script finds the same log" '[ "$("$WORK/linked-comm.sh" dir)" = "$("$S" dir)" ]'

# --- install.sh ---------------------------------------------------------------
I="$WORK/inst"
git_repo "$I"
"$REPO/install.sh" "$I" >/dev/null
check "install writes PROTOCOL.md and both scripts" \
  '[ -f "$I/.agents/channels/PROTOCOL.md" ] && [ -x "$I/.agents/channels/scripts/comm.sh" ] && [ -x "$I/.agents/channels/scripts/wake.sh" ]'
check "install makes git ignore the log" 'git -C "$I" check-ignore -q .agents/channels/statements.log'
check "install leaves PROTOCOL.md committable" '! git -C "$I" check-ignore -q .agents/channels/PROTOCOL.md'
ID="$("$I/.agents/channels/scripts/comm.sh" join inst "after install" 2>/dev/null | cut -d' ' -f3)"
"$REPO/install.sh" "$I" >/dev/null
check "reinstall doesn't duplicate .gitignore lines" '[ "$(grep -c "statements.log$" "$I/.gitignore")" = 1 ]'
check "reinstall keeps the log" '[ -n "$ID" ] && grep -q " $ID joined:" "$I/.agents/channels/statements.log"'
I2="$WORK/inst2"
git_repo "$I2"; git -C "$I2" worktree add -q "$WORK/inst2-wt" 2>/dev/null
"$REPO/install.sh" "$WORK/inst2-wt" >/dev/null
check "install from a worktree writes to the main checkout" '[ -f "$I2/.agents/channels/PROTOCOL.md" ] && [ ! -e "$WORK/inst2-wt/.agents" ]'
O="$WORK/other"
mkdir -p "$O/.agents/channels" && printf -- '---\nname: something-else\ndescription: x\n---\n' > "$O/.agents/channels/PROTOCOL.md"
"$REPO/install.sh" "$O" >/dev/null 2>&1; rc=$?
check "install refuses to replace another protocol" '[ "$rc" -ne 0 ] && grep -q something-else "$O/.agents/channels/PROTOCOL.md"'
"$REPO/install.sh" --force "$O" >/dev/null 2>&1
check "install --force replaces it" 'grep -q "^name: agent-file-communication$" "$O/.agents/channels/PROTOCOL.md"'

# --- wake.sh ------------------------------------------------------------------
fresh
"$COMM" join --runtime 22222222-0000-0000-0000-000000000002 w "x" >/dev/null 2>&1
AGENT_COMM_STATE="$WORK/wake-state" "$WAKE" --once --dry-run 2>/dev/null; rc=$?
check "wake.sh --once --dry-run exits 0 with no Codex threads" '[ "$rc" = 0 ]'
check "wake.sh --dry-run leaves the real state alone" '[ ! -f "$WORK/wake-state/last" ]'
AGENT_COMM_STATE="$WORK/wake-state" "$WAKE" --once 2>/dev/null; rc=$?
check "wake.sh --once records where it stopped" '[ "$rc" = 0 ] && [ "$(cat "$WORK/wake-state/last")" = 1 ]'
unset AGENT_COMM_DIR

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
