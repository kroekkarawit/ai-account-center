# AI Account Center

A small Bash TUI for switching Codex subscription accounts and monitoring Codex
and Claude subscription limits from one place.

## Requirements

- Bash 3.2+
- `jq`
- Codex CLI
- `curl`
- Claude CLI, only for creating Claude subscription tokens
- Optional: `fzf` for a searchable selector

## Install

```bash
cd "/Users/macbookair/Desktop/Miscellaneous/ai-account-center"
chmod +x bin/aic install.sh
./install.sh
```

Run:

```bash
aic
```

The app stores private data under `~/.ai-account-center` with restrictive file
permissions. It does not duplicate Codex plugins, skills, configuration, or
session history.

## Add Codex accounts

Save the account currently logged into Codex:

```bash
aic codex add personal
```

Login and save another account:

```bash
aic codex login company
```

Switch or run:

```bash
aic codex use personal
aic codex run company
aic codex run personal -- exec "Review this repository"
```

Account switching only replaces `~/.codex/auth.json`. Before switching, the
current file is synchronized back to its stored account so refreshed tokens are
not lost. A timestamped backup is also created.

Do not switch while another Codex CLI process is running.

## Add Claude

For limit monitoring, login with full Claude subscription OAuth:

```bash
aic claude login personal
```

If Claude is already logged in normally:

```bash
aic claude import personal
```

`claude setup-token` creates an inference-only token. It cannot call Claude's
usage endpoint, so AI Account Center falls back to a one-output-token Haiku
request and reads the 5-hour and 7-day utilization from the response headers.

A token can still be added manually with hidden input:

```bash
aic claude add personal
```

## Monitor limits

```bash
aic refresh
aic status
```

Codex monitoring calls the CLI app-server's `account/rateLimits/read` method for
each stored account. It does not send an inference prompt or consume model
tokens. Claude monitoring first calls the usage endpoint used by Claude Code.
For inference-only tokens it sends a one-output-token Haiku request and reads
the rate-limit response headers. These provider details are implementation-
dependent and may require updates when either CLI changes.

## Schedule

Fixed intervals are supported:

```bash
aic schedule set 15m
aic schedule set 30m
aic schedule set 1h
aic schedule set 2h
aic schedule off
aic schedule status
```

On macOS this installs a user `launchd` agent. On Linux with systemd it installs
a user timer. No terminal needs to remain open, but the machine must be awake
and online.

Configuration is stored at:

```text
~/.ai-account-center/config.json
```

## Data layout

```text
~/.ai-account-center/
├── accounts/
│   ├── codex/
│   └── claude/
├── backups/
├── runtime/
├── usage/
├── config.json
└── state.json
```

## Security notes

- Account and token files use mode `0600`.
- The data directory uses mode `0700`.
- Tokens are stored locally in files, not in macOS Keychain.
- Never commit `~/.ai-account-center` or its contents.
- Removing the data directory removes stored copies but does not revoke tokens.
