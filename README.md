# AI Account Center

A small Bash TUI for switching Codex subscription accounts and monitoring Codex
and Claude subscription limits from one place.

## Requirements

- Bash 3.2+
- `jq`
- Codex CLI
- `curl`
- Claude CLI, only for creating Claude subscription tokens
- A terminal with ANSI color and arrow-key support

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

The built-in TUI uses `Up`/`Down` or `j`/`k` to move, `Enter` to select, and
`Esc` or `q` to cancel. No TUI dependency such as `fzf` is required.
The main menu uses terminal-native Unicode symbols such as `◆`, `◇`, `↻`,
and `⏱` when a UTF-8 locale is available, with ASCII fallback otherwise.

The `Help / คู่มือ` menu contains a scrollable user guide in English and Thai.
Use `Up`/`Down`, `PageUp`/`PageDown`, `Home`/`End`, and `Esc` or `q`.

Reset times are displayed in `Asia/Bangkok` by default. The timezone can be
changed in `~/.ai-account-center/config.json` under `display.timezone`.

The app stores private data under `~/.ai-account-center` with restrictive file
permissions. It does not duplicate Codex plugins, skills, configuration, or
session history.

## Add Codex accounts

Save the account currently logged into Codex:

```bash
aic codex add personal
```

Import auth from another computer:

```bash
aic codex import company ~/Downloads/company-auth.json
```

In the TUI, `⇢ Import another Codex auth.json` accepts pasted multi-line JSON
and starts the import automatically when the JSON object is complete. It reads
in raw character mode so long JWT/token lines can be pasted. Cancel with
`Ctrl-C`, `Ctrl-D`, `q`, `:q`, `quit`, or `exit`; clear the current paste with
`Ctrl-U`. For very large auth files, importing by path is still the most
reliable option.

Switch or run:

```bash
aic codex use personal
aic codex run company
aic codex run personal -- exec "Review this repository"
aic codex remove company
```

Account switching only replaces `~/.codex/auth.json`. Before switching, the
current file is synchronized back to its stored account so refreshed tokens are
not lost. A timestamped backup is also created.

Do not switch while another Codex CLI process is running. AI Account Center does
not call `codex logout` or `codex login`; add another account by importing an
auth.json copied from a computer/user where that account is already logged in.

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
aic claude remove personal
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
