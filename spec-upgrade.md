# AI Account Center Upgrade Spec

This document tracks the next large upgrades for AI Account Center.

Primary constraint: keep the app lightweight. Do not migrate to Tauri, Rust,
Electron, or a resident GUI. The shell script remains the main product. Helper
scripts are allowed only when they keep the operational model simple.

## Update Log

### 2026-07-06 — v0.14.0: Claude accounts vs setup-tokens

Verified against `claude` 2.1.x: the CLI only accepts an OAuth login (with a
refresh token) from the keychain (`authMethod: claude.ai`); a setup-token is
rejected there (`authMethod: none`) and authenticates **only** via the
`CLAUDE_CODE_OAUTH_TOKEN` env var (`authMethod: oauth_token`). So a setup-token
cannot be switched globally — that is a Claude Code limitation, not ours.

- **Two Claude credential types, cleanly separated.** `claude_account_kind`
  classifies each stored account as `oauth` (refresh token → globally
  switchable) or `token` (setup-token → session credential).
  - **Switch account → Claude** now lists **OAuth accounts only** (they switch
    globally via the keychain, like Codex).
  - **Open with model → Claude** now lists **setup-tokens** (launched via
    `CLAUDE_CODE_OAUTH_TOKEN`, full first-party Claude for that session only)
    alongside third-party model profiles. `+ Add Claude setup-token` lives here.
  - **Add account → Claude** offers OAuth login / import only; the setup-token
    add path moved to Open-with-model.
- **Clobber guard:** `add_claude_token` refuses to overwrite an existing OAuth
  account (a bare token would strip its refresh token and break global switch)
  and confirms before replacing an existing setup-token.
- **Monitoring unchanged:** setup-token usage is still probed via the Haiku /
  rate-limit-header path and shown (now also in the launcher list).
- Setup-tokens expose no account identity (no `user:profile`), so duplicate
  detection across names is name-based for tokens; OAuth logins expose
  `email`/`orgId` via `claude auth status --json`.

### 2026-07-04 — v0.12.0: Modularization + menu-first CLI

- **Refactor:** the single ~3.9k-line `bin/aic` is now a thin entrypoint that
  sources focused modules under `lib/aic/` (`core`, `codex`, `codex-import`,
  `codex-process`, `claude`, `model`, `usage`, `ui`, `schedule`, `lifecycle`)
  via `lib/aic/_load.sh`. Behavior preserved; the test suite was re-targeted to
  unit-test the modules directly.
- **Menu-first command surface:** removed the one-line verbs (`codex …`,
  `claude …`, `model …`, `schedule …`, `recommend`, `list`, `config`, `debug`).
  The interactive menu (`aic`) is the only human interface. Remaining
  non-interactive commands: `aic`, `aic refresh [codex|claude NAME]`,
  `aic status`, `aic update`, `aic uninstall` (+ `version`/`help`).
- **Login is menu-only.** The `aic codex login NAME --device-auth` CLI form
  (see §3) is removed; browser login runs from *Add Codex account → Login with
  browser*. On a headless machine, import `auth.json` instead (*Add Codex
  account → Import from file or paste*). Any future device-code login would be a
  menu choice, not a CLI flag.
- **Gaps folded into the menu:** model-profile removal (*Open … with model →
  Manage profiles*) and diagnostics (*Help → Diagnostics*, formerly `aic debug`).
- **Fix:** a Claude account at 100% usage now shows `100% + reset` instead of
  `ERR`. The rejected probe (HTTP 429) still returns the
  `anthropic-ratelimit-unified-*` headers, which are now trusted regardless of
  HTTP status.

> The sections below predate this update and still describe the old
> per-command CLI surface; treat them as historical design context. Account
> transfer is now specified in §7 (Account Export / Import), which supersedes
> §2 and §6.

## Working Rules

- Implement one feature per commit.
- Do not batch unrelated upgrades in one commit.
- Update this checklist in the same commit as each completed feature.
- Keep the TUI usable without external TUI dependencies.
- Prefer Bash, `jq`, `curl`, `openssl`, `sqlite3`, and small `node`/`python3`
  helpers only when Bash becomes too fragile.
- Do not introduce a long-running background daemon beyond the existing
  launchd/systemd scheduler.
- Preserve the current data root: `~/.ai-account-center`.
- Preserve the current Codex live auth target: `~/.codex/auth.json`.
- Never call `codex logout` as part of account switching.
- Treat refresh tokens, auth files, and backups as secrets.
- Every feature must have tests or at least deterministic shell-level checks.

## Current Baseline

- Bash TUI account switcher.
- Stores Codex accounts as JSON files under
  `~/.ai-account-center/accounts/codex`.
- Stores Claude tokens under `~/.ai-account-center/accounts/claude`.
- Switches Codex by atomically replacing `~/.codex/auth.json`.
- Refreshes Codex usage through Codex app-server `account/rateLimits/read`.
- Refreshes Claude usage through Claude usage endpoint or one-token fallback.
- Supports launchd/systemd scheduler.
- TUI supports arrow navigation and scrollable bilingual help.
- Import supports long pasted Codex `auth.json`.
- TUI switch warns about running Codex processes and force-closes their process
  trees after a successful account switch.
- Installs from GitHub into `~/.local/share/ai-account-center` and supports
  `aic update`.

## Upgrade Checklist

- [x] 0. Distribution installer/update.
- [x] 1. Robust force-close process tree.
- [ ] 2. Slim Codex export/import.
- [x] 3. Built-in Codex OAuth login with browser PKCE.
- [ ] 4. Codex account metadata: plan and subscription expiry.
- [ ] 5. Privacy mask mode.
- [ ] 6. Full encrypted backup/export.

## 0. Distribution Installer/Update

### Goal

Make AI Account Center installable by non-dev users without sending a binary or
requiring a cloned repository at a fixed path. Keep the product lightweight:
Bash source copied to a stable app directory, no GUI bundle or resident runtime.

### Current State

Implemented in v0.9.0.

`install.sh` supports:

- Copy install to `~/.local/share/ai-account-center`.
- Symlink command to `~/.local/bin/aic`.
- `--dev` mode for local checkout symlink development.
- Remote install from GitHub archive when the installer is run through `curl`.
- `GITHUB_TOKEN` for private repository downloads.

`aic update [REF]` calls the installed `install.sh` in remote mode and
reinstalls app files from GitHub. Account data remains in
`~/.ai-account-center`.

### Requirements

- Do not move or mutate stored accounts, usage cache, backups, or config.
- Do not require users to manually edit PATH beyond adding `~/.local/bin` once.
- Keep install/update compatible with macOS and Linux shell environments.
- Do not add a compiled binary or package-manager dependency.

### Verification

- Local install: `./install.sh --dev`.
- Copy install with isolated dirs:
  `AIC_APP_DIR=/tmp/aic-app AIC_INSTALL_DIR=/tmp/aic-bin ./install.sh`.
- Remote update path: `aic update` after copy install.

## 1. Robust Force-Close Process Tree

### Goal

When switching accounts, all currently running Codex sessions should be closed
cleanly so newly opened CLI or VS Code sessions reload the new account from
`~/.codex/auth.json`.

### Current State

Implemented in v0.8.14. The app detects Codex root processes, expands their
child process trees from `ps pid,ppid,command`, sends `TERM` to child processes
before parents, waits briefly, then sends `KILL` to processes that are still
alive.

### Requirements

- Detect all Codex-related processes:
  - Codex CLI wrapper, for example `node /opt/homebrew/bin/codex`.
  - Native Codex binary under npm package vendor directory.
  - VS Code extension app-server:
    `~/.vscode/extensions/openai.chatgpt-*/bin/*/codex app-server`.
- Build a process tree from detected roots.
- Include child processes recursively.
- Exclude the current `aic` process.
- Exclude test helper commands.
- In TUI switch:
  - Show the processes that will be closed.
  - Ask for confirmation once.
  - Switch account only after confirmation.
  - Close processes after `~/.codex/auth.json` is successfully replaced.
- In CLI switch:
  - Warn clearly.
  - Continue without interactive confirmation unless stdin is a TTY and we
    intentionally decide otherwise.
- Use graceful shutdown first:
  - Send `TERM`.
  - Wait briefly, for example 1 second.
  - If still alive, send `KILL`.
- Print what was closed and what could not be closed.

### Non-Goals

- Do not kill arbitrary `node` processes.
- Do not kill unrelated VS Code extension host processes.
- Do not delete session files.
- Do not call `codex logout`.

### Acceptance Tests

- Fake `pgrep` and `ps` fixtures can simulate parent/child process trees.
- Switching with no process still works.
- Switching with Codex CLI processes prints a warning and closes simulated PIDs.
- Switching with VS Code app-server prints a VS Code-specific warning.
- If auth write fails, no process is killed.
- If process is already gone, app prints a warning but does not fail switch.

### Commit Scope

Commit only:

- `bin/aic`
- `tests/test.sh`
- `spec-upgrade.md`

Suggested commit message:

```text
Harden Codex process cleanup on account switch
```

## 2. Slim Codex Export/Import

> **Superseded by §7 (Account Export / Import).** The slim/re-mint approach was
> dropped in favor of transferring full account data. Kept for historical context.

### Goal

Allow account migration using a shorter string based on the Codex refresh token
instead of pasting the full `auth.json`.

### Why

The current pasted `auth.json` flow works, but JWT strings are long and awkward.
The refresh token is enough to mint fresh short-lived tokens during import.

### Proposed Commands

```bash
aic codex export-slim ACCOUNT
aic codex import-slim [NAME]
```

TUI entries:

```text
Export Codex slim token
Import Codex slim token
```

### Proposed Slim Format

Use a versioned format that can evolve:

```text
aic1.codex.<base64url-json>
```

Payload:

```json
{
  "version": 1,
  "provider": "codex",
  "name_hint": "personal",
  "account_id": "optional",
  "refresh_token": "rt....",
  "created_at": "2026-06-16T00:00:00Z"
}
```

### Import Flow

- Parse slim token.
- Exchange `refresh_token` with the OpenAI OAuth token endpoint.
- Receive fresh `id_token`, `access_token`, and possibly a new
  `refresh_token`.
- Construct a valid Codex `auth.json`:

```json
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "...",
    "access_token": "...",
    "refresh_token": "...",
    "account_id": "..."
  },
  "last_refresh": "..."
}
```

### Questions To Resolve

- Exact OAuth `client_id` and required headers used by current Codex.
- Whether refresh token rotation returns a new refresh token every time.
- Whether OpenAI requires additional params beyond `grant_type=refresh_token`.
- How to recover `account_id` if it is only present in `id_token`.

### Security

- Treat slim token as secret.
- Do not print slim token unless user explicitly exports.
- Optional `--copy` can be considered later, but not required.
- Never write slim token into logs.

### Acceptance Tests

- Export refuses accounts without `tokens.refresh_token`.
- Export output starts with `aic1.codex.`.
- Import rejects malformed slim token.
- Import uses a mocked token endpoint in tests.
- Import stores a valid account file.
- Duplicate account detection still works.

### Commit Scope

Commit only:

- `bin/aic`
- `tests/test.sh`
- `README.md`
- `spec-upgrade.md`

Suggested commit message:

```text
Add slim Codex account export and import
```

## 3. Built-In Codex OAuth Login With Browser PKCE

### Goal

Add Codex accounts directly from AIC without overwriting the user's active
`~/.codex/auth.json` and without pasting `auth.json`.

### Why

This is the largest UX improvement. User flow becomes:

```text
Add Codex with browser
→ browser opens
→ user logs in
→ Codex CLI receives localhost callback in a temporary CODEX_HOME
→ AIC saves account
```

### Commands

```bash
aic codex login NAME
aic codex login NAME --device-auth
```

TUI entry:

```text
Login Codex with browser
```

### Implemented Flow

Implemented in v0.10.0.

- Create a short-lived temporary `CODEX_HOME` under AIC runtime dir.
- Run `CODEX_HOME=<temp> codex login ...`.
- Let the installed Codex CLI handle browser PKCE, localhost callback,
  workspace selection, token exchange, and future endpoint/client changes.
- Validate `<temp>/auth.json` with existing `validate_codex_auth`.
- Save account as a standard Codex account JSON under AIC's account pool.
- Remove the temporary `CODEX_HOME`.
- Do not switch the active account automatically.

### Rationale

Reimplementing Codex OAuth would require tracking private/unstable details such
as current client id, redirect URI, endpoint parameters, and workspace behavior.
Delegating OAuth to the installed Codex CLI keeps AIC lightweight while still
solving the one-computer login problem.

### Rejected Direct OAuth Flow

- Generate PKCE verifier and challenge.
- Start a short-lived localhost callback server.
- Open browser to OpenAI/Codex authorization URL.
- Receive `code` on localhost callback.
- Exchange `code` for tokens.
- Decode `id_token` to get email/account metadata.
- Save account as standard Codex account JSON.
- Stop callback server.

### Remaining Questions

- Whether all Codex CLI versions support the same `codex login` arguments.
- Whether some workspace-restricted accounts require `--device-auth`.

### Risks

- If Codex CLI changes `auth.json` format, validation/import may need updates.
- If Codex CLI changes login flags, pass-through args may need documentation.
- Workspace device-auth policy may block some accounts.
- Browser login can be harder to test fully offline.

### Acceptance Tests

- Mock `codex login` writes auth.json into temporary `CODEX_HOME`.
- Saved account validates with existing `validate_codex_auth`.
- Failed login leaves no partial account file.

### Commit Scope

Commit only:

- `bin/aic`
- optional helper under `lib/`
- `tests/test.sh`
- `README.md`
- `spec-upgrade.md`

Suggested commit message:

```text
Add browser OAuth login for Codex accounts
```

## 4. Codex Account Metadata: Plan And Subscription Expiry

### Goal

Display useful account metadata beyond rate-limit utilization.

### Candidate Fields

- Email.
- Account id.
- ChatGPT user id.
- Plan type, for example Plus, Pro, Team, Enterprise.
- Subscription active start.
- Subscription active until.
- Last checked time.
- Organization/workspace title when available.
- Credit/overage status if available.

### Current Available Source

The Codex `id_token` already contains some useful fields under:

```text
https://api.openai.com/auth
```

Known fields observed:

- `chatgpt_account_id`
- `chatgpt_plan_type`
- `chatgpt_subscription_active_start`
- `chatgpt_subscription_active_until`
- `chatgpt_subscription_last_checked`
- `chatgpt_user_id`
- `organizations`

### Proposed Dashboard Display

Keep the main table readable:

```text
CODEX >personal   Plus until Jul 05   [5h ...] [7d ...]
```

Detailed metadata can go under:

```bash
aic codex info ACCOUNT
```

### Requirements

- Decode JWT safely without verifying signature for display-only metadata.
- Never trust decoded JWT for authorization decisions.
- Store metadata in account file or separate metadata file.
- Refresh metadata when tokens refresh.
- Display Bangkok timezone by default.

### Acceptance Tests

- Decode fixture `id_token` and extract plan/expiry.
- Missing fields do not break dashboard.
- Expired/unknown subscription displays gracefully.
- `aic codex info ACCOUNT` redacts sensitive tokens.

### Commit Scope

Commit only:

- `bin/aic`
- `tests/test.sh`
- `README.md`
- `spec-upgrade.md`

Suggested commit message:

```text
Show Codex account plan and subscription metadata
```

## 5. Privacy Mask Mode

### Goal

Allow the dashboard to be safely shown on screen or shared in screenshots
without exposing full emails or account ids.

### Proposed Config

```json
{
  "display": {
    "privacy_mask": false,
    "mask_account_names": false,
    "timezone": "Asia/Bangkok"
  }
}
```

### Proposed Commands

```bash
aic privacy on
aic privacy off
aic privacy status
```

TUI entry:

```text
Privacy mask
```

### Masking Rules

- Email: `sikiinta@gmail.com` -> `sik***@gmail.com`.
- Account name: optional, only if `mask_account_names=true`.
- Account id: show first 6 and last 4 only.
- Tokens: never show, regardless of privacy mode.

### Requirements

- Dashboard respects privacy mode.
- `list` respects privacy mode unless `--raw` is added later.
- Help text documents the mode.
- Config changes are atomic.

### Acceptance Tests

- Email masking works for common email formats.
- Short names do not break masking.
- Dashboard hides email/account id when enabled.
- Privacy off restores normal display.

### Commit Scope

Commit only:

- `bin/aic`
- `tests/test.sh`
- `README.md`
- `spec-upgrade.md`

Suggested commit message:

```text
Add privacy mask mode for account display
```

## 6. Full Encrypted Backup/Export

> **Superseded by §7 (Account Export / Import).** §7 is the current design for
> account transfer (accounts only, app-encrypted, self-expiring). Kept for
> historical context.

### Goal

Export all AIC account data for backup or migration, optionally encrypted with a
user-provided passphrase.

### Proposed Commands

```bash
aic backup export PATH
aic backup export --encrypted PATH
aic backup import PATH
```

TUI entries:

```text
Export backup
Import backup
```

### Data Included

- `accounts/codex/*.json`
- `accounts/claude/*.json`
- `state.json`
- selected non-sensitive config fields
- optionally usage cache, but default should exclude usage

### Data Excluded

- runtime files
- logs
- scheduler logs
- lock directory
- live `~/.codex/auth.json`
- Codex session history

### Encryption

Preferred lightweight approach:

```bash
openssl enc -aes-256-gcm -pbkdf2 -salt
```

If AES-GCM support is inconsistent across macOS OpenSSL/LibreSSL, use:

```bash
openssl enc -aes-256-cbc -pbkdf2 -salt -md sha256
```

Tradeoff:

- AES-GCM is better.
- AES-CBC is more portable but lacks authenticated encryption.

Decision must be verified on the target macOS.

### Requirements

- Ask passphrase twice for encrypted export.
- Never echo passphrase.
- Import creates timestamped backup before overwriting.
- Import validates JSON before replacing existing data.
- File permissions remain `0700` directories and `0600` secrets.

### Acceptance Tests

- Plain export/import round trip.
- Encrypted export/import round trip if OpenSSL supports chosen mode.
- Wrong passphrase fails without modifying existing data.
- Import rejects malformed archive.
- Existing data is backed up before import.

### Commit Scope

Commit only:

- `bin/aic`
- `tests/test.sh`
- `README.md`
- `spec-upgrade.md`

Suggested commit message:

```text
Add encrypted backup export and import
```

## 7. Account Export / Import (encrypted transfer)

Groomed 2026-07-04. Supersedes §2 (slim) and §6 (backup): decided to move the
**full** account data (no token re-minting) via an app-encrypted, self-expiring
file or copy-string. Primary use case: move accounts to a new machine without
re-login / 2FA.

### Locked Decisions

- **Full account data**, not slim. Import writes the stored account file back and
  relies on the existing switch/refresh path to renew tokens on first use — no
  provider OAuth re-mint (the slim approach's re-mint was unverified and risky).
- **Accounts only** — Codex + Claude account files. Model profiles and config are
  out of scope (a separate third-party model manager will own profiles later).
- **App-managed encryption, no user passphrase.** aic encrypts and decrypts with
  an embedded key. This is *obfuscation, not confidentiality* (see Threat Model).
- **Fixed 3-day expiry** (policy — not user-configurable).
- **Two transports only:** a file, or a copy-string. No QR, no link, no PIN.
- **Duplicate handling:** detect by identity and by name; ask replace/skip;
  default skip.

### Threat Model (explicit)

The exported string/file is protected against: humans reading it, secret-scanners
(no `sk-` / decodable-JWT shape), and accidental leakage into chats/logs. It is
**not** protected against anyone who runs aic — the tool is open source and holds
the key. The fixed 3-day expiry limits the window in which a leaked blob is
usable. This trade-off is accepted deliberately.

### Envelope Format

```text
AIC1.<base64url( [fmt_ver:1][key_ver:1][salt:16] + AES-256-CBC(pbkdf2)( gzip(payload) ) )>
```

- `AIC` magic + `fmt_ver` → unknown version imports as a clean
  "made by a newer aic, please update" error, never garbage.
- `key_ver` selects the embedded app key, so a future build can rotate the key
  without breaking old blobs.
- Random per-export `salt` → identical exports produce different blobs.
- `gzip` before encrypt (correct order). Compression mainly shrinks JSON
  structure / multi-account repetition; refresh tokens are high-entropy and do
  not compress.
- Encryption via `openssl enc -aes-256-cbc -pbkdf2 -salt` (present on
  macOS + Linux; already an allowed dependency). CBC chosen for portability over
  GCM per §6; authenticity is not a goal here (obfuscation only).

### Payload Schema

```json
{
  "v": 1,
  "created_at": 1751630400,
  "ttl": 259200,
  "accounts": [
    { "provider": "codex",  "name": "siki", "account_id": "acc_…", "data": { "auth_mode": "chatgpt", "tokens": { "…": "…" } } },
    { "provider": "claude", "name": "work", "org": "org_…",        "data": { "claudeAiOauth": { "…": "…" } } }
  ]
}
```

- `data` is the exact stored account-file content (full `auth.json` / OAuth blob).
- `account_id` (codex) / `org` (claude) are duplicated at the top for identity
  dedup without decrypting deeply / decoding JWTs.
- `name` preserves the origin's account name.

### Export Flow  (Manage accounts → Export accounts)

1. Multi-select accounts to include (`Space` toggles `[x]`, `a` = all).
2. Choose transport:
   - **File** — folder picker (macOS: `osascript -e 'choose folder'`; else typed
     path, default `~/`). Writes `aic-transfer-<UTC>.aicx`, mode `0600`.
   - **String** — print the `AIC1.…` blob; `c` copies it
     (`pbcopy` / `xclip` / `wl-copy`; else "copy manually").
3. Remind: expires in 3 days; send it to yourself (AirDrop / chat / upload);
   delete after importing.

### Import Flow  (Manage accounts → `i`)

1. Source: **paste string** or **read file** (path / drag / clipboard) — reuses
   the existing paste/import engine.
2. Decode → decrypt → check expiry. Any failure (bad magic, wrong version,
   corrupt, expired) aborts cleanly with **no changes**.
3. Preview the accounts found in the bundle.
4. Multi-select which to import; resolve per account:
   - **same identity already present** (by `account_id`/`org`, reusing existing
     duplicate detection) → *Replace / Skip*.
   - **name taken by a different account** → *Rename / Overwrite / Skip*.
   - default **Skip**.
5. Write files `0600`; timestamp-backup anything overwritten first; validate JSON
   (`validate_codex_auth` / Claude blob shape) before writing; reconcile the
   active pointer if needed.

### Security / Rules

- Never write the blob or any token to logs or stdout except the explicit export.
- Files `0600`, directories `0700`.
- Expiry is checked against the local clock (note: wrong clock can mis-expire).
- Corrupt/expired/foreign blob must fail without touching existing data.

### Acceptance Tests

- Round-trip: export N accounts → import into a clean data dir → files valid and
  identical; identity dedup intact.
- Expired blob (`created_at` older than 3d) is refused, no changes.
- Corrupt / truncated / wrong-magic / wrong-version blob refused with a clear
  message, no changes.
- Duplicate by identity → both Replace and Skip paths verified.
- Name collision with a different identity → Rename / Overwrite / Skip verified.
- Malformed account `data` rejected before writing.
- Both transports (file and string) round-trip; clipboard copy is best-effort.
- Blob/tokens never appear in logs.

### Commit Scope

- New module `lib/aic/transfer.sh` (envelope encode/decode + export/import flows).
- Wire `Export accounts` / `Import accounts` into the account-management menu
  (`lib/aic/ui.sh` → `manage_account_menu`).
- `tests/test.sh`, `README.md`, `spec-upgrade.md`. One feature per commit.

Suggested commit message:

```text
Add encrypted account export/import transfer
```

## Suggested Implementation Order

1. Robust force-close process tree.
2. ~~Slim Codex export/import~~ — superseded by §7.
3. Built-in Codex OAuth login with browser PKCE.
4. Codex account metadata.
5. Privacy mask mode.
6. ~~Full encrypted backup/export~~ — superseded by §7.
7. Account export/import (§7) — encrypted transfer, accounts only, self-expiring.

Reasoning:

- Process cleanup protects the current switch workflow.
- Slim export/import reduces migration friction immediately.
- Browser OAuth is a bigger feature and should be done after token refresh logic
  is understood.
- Metadata and privacy are UI polish after auth flows are stable.
- Full backup/export should wait until account formats are closer to final.

## Open Research Notes

- Confirm current Codex OAuth client id and scopes from installed binary or
  network capture.
- Confirm refresh-token grant parameters.
- Confirm whether refresh token rotation happens on every refresh.
- Confirm whether browser OAuth handles workspace-restricted accounts.
- Confirm OpenSSL mode available on target macOS.
- Confirm safest cross-platform process-tree kill strategy for macOS and Linux.

## Session Handoff Instructions

For future sessions:

1. Open this file first.
2. Pick exactly one unchecked feature.
3. Implement only that feature.
4. Run tests.
5. Update the checkbox and notes.
6. Commit that feature by itself.
7. Do not start the next feature in the same commit.
