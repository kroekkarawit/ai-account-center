# AI Account Center

A small Bash TUI for switching Codex and Claude subscription accounts, launching
either CLI against an alternate model provider, and monitoring Codex and Claude
subscription limits — all from one interactive menu.

Everything is driven from the menu. There is no long list of subcommands to
remember: run `aic` and pick what you want to do.

## Requirements

- Bash 3.2+
- `jq`
- Codex CLI
- `curl`
- Claude CLI (only for Claude subscription login / setup-token)
- A terminal with ANSI color and arrow-key support

## Install

Install from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/kroekkarawit/ai-account-center/main/install.sh | bash
```

For a private repository, use a GitHub token that can read the repo:

```bash
export GITHUB_TOKEN=ghp_xxx
curl -fsSL \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/kroekkarawit/ai-account-center/main/install.sh | bash
```

The installer copies app files to `~/.local/share/ai-account-center` (the `aic`
launcher plus its `lib/aic` modules) and links `~/.local/bin/aic`. Account data
lives in `~/.ai-account-center`, so updates never overwrite stored tokens or
cached usage.

For local development, symlink the checkout instead of copying:

```bash
cd /path/to/ai-account-center
chmod +x bin/aic install.sh
./install.sh --dev
```

## Commands

The interactive menu is the interface. Only a handful of non-interactive
commands exist, for scripting and the background scheduler:

```bash
aic                          # open the interactive menu (does everything)
aic refresh                  # refresh cached usage for all accounts
aic refresh codex NAME       # refresh a single account
aic refresh claude NAME
aic status                   # print cached usage for all accounts
aic update [REF]             # update from GitHub
aic uninstall                # remove the install, keep account data
aic uninstall --purge-data   # also delete ~/.ai-account-center (tokens included)
aic version
```

Switching, adding accounts, model launches, scheduling, renaming, removing, and
diagnostics all live inside the menu.

## Using the menu

Run:

```bash
aic
```

Navigate with `Up`/`Down` or `j`/`k`, press number keys `1`–`9` to jump, `Enter`
to select, and `Esc` or `q` to cancel. No TUI dependency such as `fzf` is
required. The menu uses Unicode symbols (`◆`, `◇`, `↻`, `⏱`) when a UTF-8 locale
is available, with an ASCII fallback otherwise.

The dashboard at the top shows each stored account with a usage badge:

```text
[5h ██░░░░░░░░  22% -> 18:49]
[7d █████████░  94% -> Jun 16, 16:50]
```

The percentage is usage **consumed**, not remaining. Green is low, yellow is
≥70% used, red is ≥90% used. Reset times use `Asia/Bangkok` unless changed in
Settings.

### Switch account

**Switch account → Codex account / Claude account.** For Codex, the live
`~/.codex/auth.json` is replaced atomically; the previous file is synced back to
its stored account first (so refreshed tokens are not lost) and a timestamped
backup is written. Do not switch while another Codex CLI process is running —
the menu warns you and offers to close running sessions.

### Add a Codex account

**Add Codex account →**

- **Login with browser** — runs `codex login` in a temporary `CODEX_HOME` and
  saves the result, leaving your active `~/.codex/auth.json` untouched.
- **Save current session** — stores the account currently in `~/.codex/auth.json`.
- **Import from file or paste** — paste multi-line JSON, type/drag a file path,
  or press `P` to import from the clipboard. Pasting reads in raw character mode
  so long JWT/token lines survive; clear with `Ctrl-U`, cancel with `Ctrl-C`,
  `Ctrl-D`, or `q`. For very large auth files, importing by path is most
  reliable.

### Add a Claude account

**Add Claude account →**

- **Login with OAuth** — full Claude subscription OAuth (needed for usage
  monitoring), imported automatically.
- **Import current login** — imports an existing Claude Code login.
- **Add token manually** — stores a `setup-token` or OAuth token with hidden
  input. A `setup-token` is inference-only; see Monitoring below.

### Launch with a model profile

**Open Codex with model / Open Claude with model** launch the respective CLI
against an alternate provider/model (for example DeepSeek). From the same
picker you can **+ Add new profile** or **Manage profiles** (remove). Profiles
store a base URL, API key, and per-tier model names, and are applied via
environment variables at launch.

### Manage accounts

**Manage accounts** picks a single account and offers: switch, refresh, rename,
re-login, re-import (Codex), update token (Claude), and remove. Removing an
active Codex profile does **not** delete the live `~/.codex/auth.json` and does
not log the account out — it only removes Account Center's saved copy.

### Move accounts to another machine (export / import)

**Manage accounts → Export accounts** bundles the accounts you pick (Space to
multi-select) into a single encrypted, self-expiring transfer — either **saved
to a file** (folder picker) or shown as a **copy-paste string**. On the other
machine, **Manage accounts → Import accounts** reads the file or pasted string,
previews what's inside, lets you pick which to import, and resolves any
duplicates (replace / rename / skip). Because the full account is transferred,
the new machine works without a fresh browser login or 2FA.

The transfer is encrypted by aic and **expires after 3 days**. Note this is
*obfuscation, not secrecy*: aic is open source, so anyone who runs aic could
decode the blob — it protects against accidental leaks and secret-scanners, not
a determined attacker. Send it to yourself over a channel you trust, import it,
then delete it. (Model profiles and config are not included.)

### Settings

**Settings** edits `~/.ai-account-center/config.json`: display timezone, the
Codex/Claude monitor toggles and timeouts, the Claude probe model, and the
background refresh schedule.

## Monitoring

**Refresh all usage** (or `aic refresh`) updates every stored account:

- **Codex** — calls the CLI app-server's `account/rateLimits/read` method. No
  inference prompt is sent and no model tokens are consumed.
- **Claude (full OAuth)** — calls the usage endpoint used by Claude Code.
- **Claude (inference-only setup-token)** — sends a one-output-token Haiku
  request and reads 5-hour / 7-day utilization from the response headers.

These provider details are implementation-dependent and may need updates when
either CLI changes.

## Background schedule

In **Settings**, set a refresh interval (15m, 30m, 1h, 2h, 4h, 6h) or turn it
off. On macOS this installs a user `launchd` agent; on Linux with systemd it
installs a user timer (both run `aic refresh --scheduled`). No terminal needs to
stay open, but the machine must be awake and online when the refresh runs.

## Diagnostics

If Codex auth or rate-limit checks fail, open **Help → Diagnostics**. It prints:

- OS, shell, and every directory in `PATH`
- `codex`, `node`, and `jq` paths and versions (or `NOT FOUND`)
- location of the rate-limit helper script
- live `~/.codex/auth.json` inspection: `auth_mode`, field names, `account_id`,
  and whether the access token is valid or expired (token values are never shown)
- per stored account: the same auth inspection plus a live 20-second run of the
  rate-limit helper with full `stdout`/`stderr`

| Symptom | Likely cause |
|---------|--------------|
| `codex: NOT FOUND` | Codex CLI not in `$PATH` (`~/.local/bin` may be missing) |
| `node: NOT FOUND` | Node.js not installed or not in `$PATH` |
| `access_token: EXPIRED` | Token expired; re-login the account from the menu |
| `Stdout: (empty)` | Codex version does not support `app-server --stdio` |
| Stderr shows network error | Proxy or firewall blocking the OpenAI auth endpoint |
| `validate: FAILED` | Auth file missing required fields; re-import it |

## Data layout

```text
~/.ai-account-center/
├── accounts/
│   ├── codex/
│   └── claude/
├── model-profiles/
├── backups/
├── runtime/
├── usage/
├── config.json
└── state.json
```

## Project layout

The launcher is a thin entrypoint; all logic lives in focused modules that it
sources at startup (and that the test suite unit-tests directly):

```text
bin/aic                 # entrypoint: locate modules, dispatch the 4 commands
lib/aic/_load.sh        # sources the modules below (core first)
lib/aic/core.sh         # globals, colors, state, path/time helpers
lib/aic/codex.sh        # Codex accounts, JWT/auth parsing, switch
lib/aic/codex-import.sh # paste/file/clipboard auth import
lib/aic/codex-process.sh# running-Codex detection & force-close on switch
lib/aic/claude.sh       # Claude accounts, keychain, switch
lib/aic/model.sh        # model profiles + launch
lib/aic/usage.sh        # refresh, rate-limit parsing, scoring
lib/aic/ui.sh           # TUI primitives, dashboard, menus, help, settings
lib/aic/schedule.sh     # scheduled refresh (launchd/systemd)
lib/aic/lifecycle.sh    # self update/uninstall + diagnostics
lib/aic/transfer.sh     # encrypted account export/import between machines
lib/codex-rate-limits.mjs
```

Run the tests with:

```bash
bash tests/test.sh
```

## Security notes

- Account and token files use mode `0600`.
- The data directory uses mode `0700`.
- Tokens are stored locally in files, not in the macOS Keychain.
- Never commit `~/.ai-account-center` or its contents.
- Removing the data directory removes stored copies but does not revoke tokens.
