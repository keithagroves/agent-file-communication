---
name: agent-file-communication
description: Coordinate with the other agents working in this project through an append-only statement log, using only the scripts in this folder.
---

# Agent File Communication

This is this project's [Agent Channels](https://github.com/keithagroves/agentchannels) protocol, at `.agents/channels/PROTOCOL.md`. It comes from [agent-file-communication](https://github.com/keithagroves/agent-file-communication). Agents here talk through one append-only log, `statements.log` in this folder. It isn't committed.

## Requires: the scripts in this folder

Read and write the log only with `scripts/comm.sh`; `scripts/wake.sh` wakes agents that can't wake themselves. Both come with this folder and need bash, git, and `lockf` (macOS) or `flock` (Linux). If you can't run them, tell the user. Don't write the log any other way, and don't use another copy of the helper.

**Other agents are probably already here.** Often they are sessions the user started in parallel, sometimes with the same request. The log is the team: read it and work with them before starting anything of your own.

## Core protocol

These rules are the whole protocol. Everything after this section is convention.

**Identity and joining.** Your ID is 8 hex characters, minted for you by `comm.sh join`, which also posts your first statement (`joined: runtime <uuid>, session <name>, cwd <path>, working on <x>`); the ID is its third field. Pass `--runtime <uuid>` with your runtime's top-level session or task UUID. After a resume, the same `join --runtime` finds that UUID in the log and gives back your old ID (`rejoined:`), so identity survives with no state outside the log. Only that runtime field is compared, never the text after it. IDs are never reissued. An ID has joined if it wrote a `joined:` or `rejoined:` line; the log is the only record, and it says nothing about who is still alive. `say` refuses any other ID, so a typo can't mint a new identity.

**One helper, one log.** Read and write only through `comm.sh`, never a helper of your own: different lock schemes (`flock`, `lockf`, `mkdir`) don't exclude each other. The helper is `scripts/comm.sh` in this folder. Every worktree of the repo shares the one log in the **main checkout**, and the script finds it from its own location, so it works from any directory. If `.agents/` isn't committed, a worktree has no copy of the script: run the main checkout's by its absolute path, as below, which works in both cases.

```bash
S="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.agents/channels/scripts/comm.sh"
                                      # from the main checkout or any worktree

ID=$($S join --runtime <uuid> <session-name> "<what you're working on>" | awk '{print $3}')
$S say  <id> "..."                    # prints your line, then what others posted since your previous one
$S read [after] [--not <id>]          # warns if sequence numbers repeat, skip or run backwards
$S wait <after> [secs] [--not <id>] [--for <id>]
                                      # returns as soon as anything newer exists;
                                      # --for: only statements that need <id> to act
```

Point `AGENT_COMM_DIR` at a temporary directory for tests, never at the live log.

**Statements.** One line each: `<sequence> <timestamp> <agent-id> <statement>`. The sequence number is the only order; timestamps are informational. The log is one continuous sequence and append-only: never edit, delete or reset it. Correct a statement by posting `Correction to <n>: ...`. If `say` refuses because the log ends mid-line, stop and tell the user; don't repair history yourself.

A line counts once it ends in a newline: `read` and `wait` never return a half-written last line, and warn if one is there. Read before you act, and check what `say` shows you after posting, in case it changes what you just said. Keep your read position privately; never write it into the log.

## Team conventions

**Join, don't duplicate.** Read the whole log before planning, spawning subagents or creating worktrees. If someone is active, work with them. If someone coordinates, work under them rather than posting a competing plan. Spawn subagents only if the user asked *and* nobody on the log covers that work. If all the work is taken, offer what's still needed: review, tests, a check in the running app. Ask other agents through the log, never through the user.

**Claims.** Say what you'll do before doing it: `(B) claim: tick volume. Worktree player-tick-keys; touching src/player.` Re-read the log afterwards. The lowest-numbered open claim since the last `round closed` wins. Coordinating is a claim like any other (`claim: coordinator`). An owner going quiet doesn't free its claim; ask them, or ask the user.

**While you work.** Post before touching a file outside your claim. Start a statement with `To <id>:` to address someone (a prefix of at least 4 characters works; one shared by two agents addresses both, and `To all:` addresses everyone). Everyone still reads everything. Relay the user's decisions as `User decision: ...`, because other sessions can't see your conversation.

**Finishing.** `done:` says how to verify the work: branch, commits, tests run with counts, and what was *not* checked. Post `released: <why>` if you stop without finishing. The coordinator merges unless the log says otherwise; other agents commit only to their own branch. When every claim is done or released, the coordinator posts `round closed: <summary>`. That line is the boundary for the next round's claims.

**Waking.** An idle agent is woken only by a statement that needs it to act: one addressed to it (its ID or a prefix of at least 4 characters, or `all`, in the `To …:` header), not its own, and not marked `No reply needed`. That's exactly what `--for <id>` selects. A wake means *notified*, not *read*. Agents that can wake themselves keep a `wait --for` watcher running (adapter notes below). For those that can't, the user runs `scripts/wake.sh` from inside the project: it watches the log and starts one turn per actionable statement, at most one wake per agent at a time. A statement counts as handled only when its turn succeeds; a failed wake is reported and retried, up to 3 attempts, and a successful one is never repeated. Without a watcher or a bridge, a message waits until the recipient's next turn; say so rather than assume it was seen.

**No loops.** Only a question or a request expects a reply. Acknowledgements, FYIs and `done` statements get none, and never acknowledge an acknowledgement. End a statement that needs no answer with `No reply needed.` Wake another agent only for a statement it must act on, once per request. Watch the log only while you hold an open claim or are waiting for an answer. After about three exchanges with the same agent without progress, stop and ask the user.

## Adapter note: Claude Code

- **Joining:** a top-level session runs `join --runtime "$CLAUDE_CODE_SESSION_ID"`. **A subagent joins without `--runtime`.** It inherits its parent's session ID, so passing it would hand the subagent its parent's identity. A spawner gives each subagent the `comm.sh` path; the subagent joins as `subagent of <parent-id>` and keeps the minted ID for its lifetime.
- **Your session name**, for `join`, is shown by `ListAgents` where that tool exists; otherwise use any short label.
- **Waking yourself:** run `comm.sh wait <last-seq> 600 --for <your-id>` as a background Bash command. Its completion starts a turn even when the session is idle. Re-arm it after each firing while you hold a claim or await an answer.
- **Doorbell:** where `SendMessage` can reach the peer's session, send it after posting in the log, and send only `New statement <n> for <id> in the log`. The log stays the record; the message only wakes them.

## Adapter note: Codex

- **Joining:** use your thread ID as `--runtime`; it is the UUID in your rollout file name under `~/.codex/sessions`.
- **Writing the log:** `workspace-write` keeps `.agents/` read-only, like `.git`. Posting needs the log directory added as a writable root: `-c 'sandbox_workspace_write.writable_roots=["<main checkout>/.agents/channels"]'`, or an approval.
- **Being woken:** a Codex thread can't wake itself when idle. `wake.sh` wakes it with a headless `codex exec resume <thread>` turn, which is sandboxed to the workspace plus the log directory. That turn runs as a separate process on the same thread: a Codex window showing the thread only displays it after reopening. Don't run the bridge against a thread someone is typing into.
