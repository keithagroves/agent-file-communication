#!/usr/bin/env bash
# Installs the agent-file-communication protocol into a project's
# .agents/channels/ (Agent Channels), or updates an earlier install.
#
#   ./install.sh [--force] [project-dir]       from a clone of this repo
#   curl -fsSL https://raw.githubusercontent.com/keithagroves/agent-file-communication/main/install.sh \
#     | bash -s -- [--force] [project-dir]
#
# project-dir defaults to the current directory. In a git repo the files go to
# the MAIN checkout, where every worktree's agents share one log. It writes
# PROTOCOL.md, scripts/comm.sh and scripts/wake.sh, never statements.log, and
# adds the log to .gitignore unless git already ignores it. A project has one
# protocol: an existing PROTOCOL.md with another name is replaced only with
# --force.
set -euo pipefail

NAME="agent-file-communication"
TARBALL="https://github.com/keithagroves/agent-file-communication/archive/refs/heads/main.tar.gz"

FORCE="" TARGET="."
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed '$d'; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done

# Source files: this clone's channels/, or a fresh download when piped from curl.
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/channels/PROTOCOL.md" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/channels"
else
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$TARBALL" | tar -xz -C "$tmp"
  SRC="$(echo "$tmp"/*/channels)"
fi

[ -d "$TARGET" ] || { echo "install.sh: no such directory: $TARGET" >&2; exit 1; }
if common="$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  ROOT="$(dirname "$common")"
else
  ROOT="$(cd "$TARGET" && pwd)"
fi
DEST="$ROOT/.agents/channels"

if [ -f "$DEST/PROTOCOL.md" ]; then
  existing="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } /^name:/ { sub(/^name:[ \t]*/, ""); print; exit }' "$DEST/PROTOCOL.md")"
  if [ "$existing" != "$NAME" ] && [ -z "$FORCE" ]; then
    echo "install.sh: $DEST/PROTOCOL.md already defines protocol '${existing:-unnamed}'." >&2
    echo "A project has one protocol; rerun with --force to replace it with $NAME." >&2
    exit 1
  fi
  verb="Updated"
else
  verb="Installed"
fi

mkdir -p "$DEST/scripts"
cp "$SRC/PROTOCOL.md" "$DEST/PROTOCOL.md"
cp "$SRC/scripts/comm.sh" "$SRC/scripts/wake.sh" "$DEST/scripts/"
chmod +x "$DEST/scripts/comm.sh" "$DEST/scripts/wake.sh"

if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 &&
   ! git -C "$ROOT" check-ignore -q .agents/channels/statements.log; then
  gi="$ROOT/.gitignore"
  { [ ! -s "$gi" ] || [ -z "$(tail -c 1 "$gi")" ] || echo
    echo "# Agent Channels: the shared log is local state"
    echo ".agents/channels/statements.log"
    echo ".agents/channels/statements.log.lock"
  } >> "$gi"
  echo "Added the log to .gitignore."
fi

echo "$verb $NAME in $DEST"
cat <<EOF

Next:
  - Commit .agents/channels/PROTOCOL.md and .agents/channels/scripts/ so every
    clone and worktree has them.
  - Point agents at it, e.g. in AGENTS.md or CLAUDE.md:
      To coordinate with other agents, follow .agents/channels/PROTOCOL.md.
EOF
