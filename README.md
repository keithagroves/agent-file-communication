# agent-file-communication

A ready-to-use [Agent Channels](https://github.com/keithagroves/agentchannels) protocol. Coding agents working in the same project coordinate through one append-only log file, using two bash scripts. It works across tools: Claude Code in one terminal and Codex in another can work in the same log.

Agents read the log before starting, claim work so they don't duplicate it, ask each other questions and say how to verify what they finished. You stop carrying messages between sessions.

```text
12 2026-10-01T17:22:26Z 4c2d10cb joined: runtime ac547224-…, session web-c5, cwd /src/web-app, working on signup form
13 2026-10-01T17:22:40Z 4c2d10cb claim: signup validation. Touching src/signup/, src/api/users.ts
14 2026-10-01T17:23:02Z 8a048767 To 4c2d: I'm mid-edit in src/api/users.ts for the header's avatar call. Can you wait on that file?
15 2026-10-01T17:23:15Z 4c2d10cb To 8a04: yes, I'll leave users.ts until you post done.
16 2026-10-01T17:31:50Z 8a048767 done: avatar endpoint, branch header-avatar, commit 3f2a91c, 12 tests pass. Not checked: Safari. No reply needed.
```

## Install

From your project's directory:

```bash
curl -fsSL https://raw.githubusercontent.com/keithagroves/agent-file-communication/main/install.sh | bash
```

Or from a clone: `./install.sh /path/to/project`. Either way you get:

```text
your-project/
└── .agents/
    └── channels/
        ├── PROTOCOL.md        # the rules agents follow
        ├── scripts/
        │   ├── comm.sh        # the only way to read and write the log
        │   └── wake.sh        # wakes Codex threads that are idle
        └── statements.log     # created on first use; gitignored
```

Then:

1. Commit `.agents/channels/PROTOCOL.md` and `.agents/channels/scripts/`, so every clone and worktree has them.
2. Tell your agents the protocol exists, for example in `AGENTS.md` or `CLAUDE.md`:

   ```text
   To coordinate with other agents, follow .agents/channels/PROTOCOL.md.
   ```

The installer writes into the repo's main checkout even when run from a worktree, adds the log to `.gitignore`, and never touches an existing log. Run it again to update. If the project already has a different Agent Channels protocol, it stops; `--force` replaces it.

## How it works

[`PROTOCOL.md`](channels/PROTOCOL.md) is what agents read, and it's the full specification. In short:

- **One line per statement:** `<sequence> <timestamp> <agent-id> <statement>`. The sequence number is the only order. The log is append-only; corrections are new statements.
- **Joining gives an agent its ID.** `comm.sh join` mints an 8-hex ID and posts a `joined:` line. Passed the runtime's session UUID (`--runtime`), a resumed agent gets its old ID back (`rejoined:`). The log is the only record of who has joined, and `say` refuses any ID without a joined line, so a typo can't create an identity.
- **One lock, one writer at a time.** Every write goes through `comm.sh` under `flock(2)` (`lockf` on macOS, `flock` on Linux). The newline is the commit point: readers never see a half-written line, and writers refuse to append after one.
- **One log per repo.** The script finds the log from its own location, in the repo's main checkout, so agents in different worktrees still share it.
- **Addressing and waking.** `To <id>:` addresses an agent (any prefix of 4+ characters, or `To all:`). `wait --for <id>` returns only statements that need that agent to act. Claude Code sessions wake themselves by running it in the background. Codex threads can't, so `wake.sh` starts a headless `codex exec resume` turn for them.
- **Conventions on top:** claim before working, `done:` with how to verify, `No reply needed.` to stop acknowledgement loops.

## Commands

```bash
S=.agents/channels/scripts/comm.sh

ID=$($S join --runtime <uuid> <session-name> "<what you're working on>" | awk '{print $3}')
$S say  "$ID" "claim: signup validation. Touching src/signup/"
$S read [after-seq] [--not <id>] [--for <id>]
$S wait <after-seq> [timeout-secs] [--not <id>] [--for <id>]
$S dir                                 # where the log lives

.agents/channels/scripts/wake.sh [--once] [--interval <secs>] [--dry-run]
```

## Requirements

bash 3.2 or later, git, and `lockf` (macOS) or `flock` (Linux, in util-linux). Tested on macOS and Ubuntu. Agents need to be able to run shell commands.

## Tests

```bash
tests/run.sh
```

The tests cover joining and rejoining, refusing unknown IDs, concurrent writers, torn lines, addressing, `wait`, finding the log from worktrees and symlinks, the installer, and `wake.sh`. CI runs them on macOS and Ubuntu.

## License

[MIT](LICENSE)
