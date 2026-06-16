# AI Account Center Upgrade Spec

This document tracks the next large upgrades for AI Account Center.

Primary constraint: keep the app lightweight. Do not migrate to Tauri, Rust,
Electron, or a resident GUI. The shell script remains the main product. Helper
scripts are allowed only when they keep the operational model simple.

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

## Upgrade Checklist

- [x] 1. Robust force-close process tree.
- [ ] 2. Slim Codex export/import.
- [ ] 3. Built-in Codex OAuth login with browser PKCE.
- [ ] 4. Codex account metadata: plan and subscription expiry.
- [ ] 5. Privacy mask mode.
- [ ] 6. Full encrypted backup/export.

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

Add Codex accounts directly from AIC without running `codex login` and without
pasting `auth.json`.

### Why

This is the largest UX improvement. User flow becomes:

```text
Add Codex with browser
→ browser opens
→ user logs in
→ AIC receives localhost callback
→ AIC saves account
```

### Proposed Commands

```bash
aic codex login-browser NAME
```

TUI entry:

```text
Login Codex with browser
```

### Proposed Flow

- Generate PKCE verifier and challenge.
- Start a short-lived localhost callback server.
- Open browser to OpenAI/Codex authorization URL.
- Receive `code` on localhost callback.
- Exchange `code` for tokens.
- Decode `id_token` to get email/account metadata.
- Save account as standard Codex account JSON.
- Stop callback server.

### Implementation Options

Preferred lightweight options:

- Bash orchestration plus small `python3` callback helper.
- Or a small `node` helper if token exchange and HTTP server are simpler there.

Avoid:

- Tauri.
- Electron.
- Long-running local server.

### Questions To Resolve

- Current Codex OAuth client id.
- Current authorize URL and token URL.
- Required scopes.
- Exact redirect URI accepted by OpenAI for Codex.
- Whether workspace/org selection is supported in this direct flow.
- Whether device auth must remain as fallback for restricted workspaces.

### Risks

- OAuth endpoints and params may change.
- Workspace device-auth policy may block some accounts.
- Browser login can be harder to test fully offline.

### Acceptance Tests

- PKCE verifier/challenge generation is deterministic under test mode.
- Callback parser handles success and error callback.
- Token exchange can be tested with a local mocked server.
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

## Suggested Implementation Order

1. Robust force-close process tree.
2. Slim Codex export/import.
3. Built-in Codex OAuth login with browser PKCE.
4. Codex account metadata.
5. Privacy mask mode.
6. Full encrypted backup/export.

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
