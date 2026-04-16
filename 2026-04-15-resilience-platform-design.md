# CSuite Resilience Platform

**Date:** 2026-04-15
**Status:** Draft → Reviewed → Updated
**Author:** AR + Claude

## Problem

When Anthropic's API goes down, all AI-assisted development stops. There is no fallback, no notification, and no automatic recovery. The current setup is 100% dependent on a single provider.

## Goal

Deliver trust: the team always has a working AI coding assistant available, switches automatically when a provider fails, switches back when it recovers, and does all of this with negligible resource overhead.

## Audience

This is a team-shared deliverable, not personal tooling. Any engineer on the team should be able to:
- Clone the repo and run `fallback.sh status` to see what's ready
- Follow a tool's `setup.md` to onboard in minutes
- Get the same guardrails regardless of which tool they primarily use
- Use the system on macOS or Windows without modification

## Requirements

### Priority
1. **API outages (80%)** — Anthropic goes down, development continues uninterrupted
2. **Rate limiting (10%)** — Usage caps or throttling don't block work
3. **Vendor lock-in (5%)** — Ability to switch providers if terms change

### Non-negotiable constraints
- Phase 3 (proactive background daemon with auto-failover and auto-recovery) is the deliverable, not a future phase
- Resource footprint must be lighter than the problem it solves — no memory leaks, no CPU waste, no burden greater than a manual switch
- Cross-platform: Windows (Git Bash) and macOS
- Single source of truth for guardrails — one canonical file, generated into each tool's native format
- Outcome parity across tools, not feature parity — same guardrails and quality standards, not same CSuite skill machinery
- Configs maintained in lockstep: changes to Claude setup are copied to all tool configs as part of the same workflow
- Pure bash + curl — no Python, Node, or YAML parser dependencies. `sqlite3` is optional (see Metrics).

## Architecture

### Tiered Fallback Chain

| Tier | Tool | Model | What works | What doesn't |
|------|------|-------|------------|--------------|
| 0 | Claude Code | Claude Opus/Sonnet | Full CSuite — skills, personas, hooks, MCP, metrics | N/A |
| 1 | Codex CLI | GPT-4o / o3 | Guardrails, file ops, git, terminal workflow | CSuite skills/personas, MCP, hooks |
| 2a | Aider | GPT-4o (OpenAI) | Guardrails, file ops, git, multi-file edits | No agent framework, simpler UX |
| 2b | Aider | Gemini 2.5 Pro (Google) | Same as 2a | Same as 2a |
| 3 | Aider + Ollama | Local model (configurable, see resilience.conf) | Basic coding assistance, guardrails as conventions | Slow, smaller context, no cloud models |
| Sidecar | Cursor | Configurable | GUI, multi-file visual diff, guardrails via .mdc | Different workflow, not terminal-based, chosen deliberately not as fallback |

Adding a tool = adding a row in `tiers.conf`. No new scripts.

Multiple rows at the same logical tier (2a, 2b) allow trying multiple cloud providers before falling to local. The tier chain walks top to bottom — each row is tried in order.

### Directory Structure

```
csuite/resilience/
├── fallback.sh              # Single entry point — IS the escalation logic
├── lib.sh                   # Shared functions (platform, notify, health, env)
├── monitor.sh               # Background daemon (sources lib.sh)
├── generate-configs.sh      # Guardrails → tool-specific configs (sources lib.sh)
├── resilience.conf          # All runtime config (key=value, no YAML dependency)
├── tiers.conf               # Tier definitions — ordered, declarative
├── guardrails.md            # Canonical guardrails (tool-agnostic)
├── state/                   # Runtime state (gitignored)
│   ├── current_tier
│   ├── monitor.pid
│   ├── monitor.heartbeat    # Touched by active sessions, checked by daemon
│   └── monitor.log          # Max 1MB, rotated to monitor.log.1
└── tools/
    ├── claude/
    │   ├── template.md      # Claude-specific additions (skills, MCP, hooks, personas)
    │   └── setup.md         # Install + config instructions (per-platform)
    ├── codex/
    │   ├── template.md
    │   └── setup.md
    ├── aider/
    │   ├── template.md
    │   └── setup.md
    ├── cursor/
    │   ├── template.md
    │   └── setup.md
    └── ollama/
        └── setup.md
```

### Component Responsibilities

#### fallback.sh — Single Entry Point

The escalation logic as code, not documentation.

**Modes:**
- `fallback.sh` — Auto-detect: try Tier 0 first, walk down on failure
- `fallback.sh 2` — Skip to a specific tier
- `fallback.sh status` — Show readiness of all tiers, monitor health, config sync status
- `fallback.sh --dry-run` — Show what would happen without launching
- `fallback.sh --test` — Walk every tier, check prerequisites, test notifications, report

**Behavior:**
1. Source `lib.sh`
2. Validate config (`validate_config` — fail fast on typos/invalid values)
3. Read `tiers.conf` top to bottom (or from specified tier)
4. For each tier: check prerequisites (`command -v` for binary, env var check, service check)
5. If not ready: log why, skip to next tier
6. If ready: notify which tier is activating, write state, touch heartbeat, start monitor, launch tool
7. If all tiers exhausted: notify with setup instructions for the first unavailable tier

#### lib.sh — Shared Functions (Written Once, Used Everywhere)

```
detect_platform()       # → PLATFORM: macos | windows-git-bash | windows-wsl | linux
validate_config()       # → Check all config values against known valid options, fail fast
notify()                # → Toast + log. Never stdout. Platform-aware fallback chain.
notify_recovery()       # → "Claude stable. Run: fallback.sh 0" or auto-switch
check_network()         # → Basic connectivity test (distinguishes network down from API down)
check_status_page()     # → curl status.anthropic.com/api/v2/status.json, parse status.indicator
check_api_call()        # → Minimal API validation for non-Claude tiers (see Health Check Details)
check_tool()            # → command -v {binary} (universal, not --version)
check_env_vars()        # → Are required env vars set?
read_state()            # → Current tier from state/current_tier
write_state()           # → Update current tier
read_tier()             # → Parse a line from tiers.conf
start_monitor()         # → Background daemon, singleton-safe, heartbeat-tracked
stop_monitor()          # → Clean shutdown
log_metrics()           # → Write to csuite.db if sqlite3 available, else append to CSV fallback
rotate_log()            # → Rotate monitor.log at 1MB
```

**Platform-specific notification fallback chain:**

| Priority | macOS | Windows |
|----------|-------|---------|
| 1 | `osascript -e 'display notification ...'` | `powershell.exe -NoProfile -Command "[Windows.UI.Notifications]..."` |
| 2 | Terminal bell (`\a`) | BurntToast (if installed) |
| 3 | — | Terminal bell (`\a`) |

On Windows, `fallback.sh --test` verifies that at least one notification method works (tests PowerShell invocation, checks execution policy). If none work, warns during setup — not at outage time.

#### monitor.sh — Background Daemon

Runs continuously. Detects outages proactively and notifies the user with an actionable recovery path.

**Health check strategy (two-phase, resource-conscious):**
1. Check basic network connectivity first (`curl -sf --max-time 5 $network_check_url > /dev/null`) — if network is down, skip API checks, notify: "Network down — Tier 3 (local) is your only option." The check URL is configurable in `resilience.conf` (default: `https://1.1.1.1`). Corporate proxy users should set this to an internal endpoint or their proxy health URL.
2. Check Anthropic status page: `curl -sf https://status.anthropic.com/api/v2/status.json` — parse `status.indicator` field (values: `none` = operational, `minor`, `major`, `critical`). Free, no auth, stable JSON API.
3. API call validation (Tier 1+ only, not Tier 0): for tiers that use explicit API keys (OpenAI), send a request to validate the key is working. For Tier 0 (Claude Code), rely on status page only — no OAuth token parsing, no security risk.
4. On 429 (rate limited): exponential backoff on health checks to avoid worsening the problem. Double `check_interval` on each 429, cap at 5 minutes, reset on success.

**Why no API call for Tier 0:** Claude Code uses OAuth tokens in `.credentials.json`, not an API key env var. Parsing these tokens would be fragile and a security concern. The status page check is sufficient to detect Anthropic outages, which is the 80% case.

**Recovery detection (sliding window):**
- Track last N check results in a fixed-size bash array
- Recovery = `recovery_successes` out of `recovery_window` checks pass (default: 10/12 ≈ 5 min at 30s interval)
- Tolerates brief flapping without false recovery signals
- **Cold start:** On daemon startup, the sliding window is empty. Use a reduced threshold for the first `recovery_window` checks: 3 consecutive successes triggers immediate recovery. This avoids a 5-minute blind spot after daemon restart when the service is already healthy.

**Failure detection:**
- `failure_window` consecutive failures triggers outage action (default: 4 checks = 2 min)
- Distinguishes: network down, API outage, rate limited (429), degraded (status page `minor`)

**On confirmed outage (`on_failure` action):**
- `notify` (default): sends toast notification with actionable command: "Anthropic API down for 2+ min. Next available: Tier 1 (Codex). Run: `fallback.sh 1`"
- `auto_failover`: sends the same notification AND writes a `state/failover_ready` file containing the recommended tier and launch command. Does NOT auto-launch an interactive tool from a background process — that's a UX minefield. Instead, the user's next `fallback.sh` invocation (or a shell prompt hook, if configured) picks up the recommendation and launches immediately without re-checking. The `failover_ready` file is cleaned up by `fallback.sh` when it reads it, or by the daemon when it detects recovery (whichever comes first).

**Rate limiting (DEGRADED state):**
- On 429 responses: enter DEGRADED state
- In DEGRADED: increase check interval (exponential backoff), notify user ("Rate limited — consider pausing or switching"), but do NOT auto-failover unless degradation persists beyond `degraded_threshold` (default: 10 minutes)
- DEGRADED → WATCHING when rate limit clears (successful checks resume)

**Resource discipline:**
- Single process, singleton-enforced via PID file + heartbeat
- Heartbeat file (`state/monitor.heartbeat`): the launching shell touches it on startup. The daemon checks heartbeat mtime — if older than `heartbeat_timeout` (default: 10 min), daemon self-terminates. Cross-platform, no PID parent-tracking.
- Output goes to `state/monitor.log` only — never to active terminal
- Log rotation: when `monitor.log` exceeds 1MB, rotate to `monitor.log.1` (keep only 1 backup). Use write-new-then-rename pattern: write to `.tmp`, rename `.log` → `.log.1`, rename `.tmp` → `.log`. Safe on both platforms.
- Minimal memory: fixed-size sliding window array, no history accumulation
- Only logs state transitions and errors, not every health check
- Check interval is configurable, defaults to 30s (negligible CPU)

**State machine:**

```
WATCHING → (failure_window consecutive failures) → MONITORING_RECOVERY
    Action: send notification / write failover_ready file. Immediate transition, no pause.
WATCHING → (429 detected) → DEGRADED
DEGRADED → (rate limit clears) → WATCHING
DEGRADED → (persists > degraded_threshold) → MONITORING_RECOVERY
    Action: same as above — notify/write failover_ready.
MONITORING_RECOVERY → (recovery confirmed via sliding window) → WATCHING
    Action: send recovery notification, clean up failover_ready file.
```

Note: there is no `FAILING_OVER` hold state. Failure detection triggers notification and immediately transitions to `MONITORING_RECOVERY`. The daemon does not wait for the user to act — it starts watching for recovery immediately.

#### tiers.conf — Declarative Tier Definitions

```
# Format: tier | tool | command | required_env | check_cmd
# Delimiter is " | " (space-pipe-space). Commands must not contain " | ".
# Rows are tried top to bottom. First passing row launches.
0       | claude  | claude                                                    |                | command -v claude
1       | codex   | codex --model o3                                          | OPENAI_API_KEY | command -v codex
2a      | aider   | aider --model gpt-4o --read CONVENTIONS.md                | OPENAI_API_KEY | command -v aider
2b      | aider   | aider --model gemini/gemini-2.5-pro --read CONVENTIONS.md | GOOGLE_API_KEY | command -v aider
3       | aider   | aider --model ollama/$local_model --read CONVENTIONS.md   |                | ollama list
sidecar | cursor  | cursor .                                                  |                | command -v cursor
```

Note: Tier 0 has no `required_env` — Claude Code manages its own auth via OAuth. Tier 3 uses `$local_model` from `resilience.conf` so the Ollama model is configurable without editing tiers.conf.

#### resilience.conf — Runtime Configuration

```
# Health check
check_interval=30
health_check=status_page       # status_page | api_call | both
                                # api_call only works for tiers with explicit API keys (not Tier 0)

# Recovery detection (sliding window)
recovery_successes=10
recovery_window=12

# Failure detection
failure_window=4

# Rate limit / degraded state
degraded_threshold=600          # seconds of sustained 429 before escalating to failover

# Actions
on_recovery=notify              # notify | auto_switch | both
on_failure=notify               # notify | auto_failover | both

# Notification
notify_method=both              # terminal | toast | both

# Metrics
log_to_metrics=true             # requires sqlite3 in PATH; falls back to CSV if unavailable

# Local model (used by Tier 3)
local_model=gemma3              # exact ollama model tag — verify with: ollama list

# Project discovery for config generation
project_roots=~/Projects        # comma-separated list of directories to scan

# Daemon lifecycle
heartbeat_timeout=600           # seconds — daemon self-terminates if heartbeat file is stale

# Network check (corporate proxy users: set to internal endpoint)
network_check_url=https://1.1.1.1

# Log management
max_log_size=1048576            # bytes (1MB) — rotate monitor.log when exceeded
```

#### generate-configs.sh — Config Generator

**Input:** `guardrails.md` + `tools/{tool}/template.md`
**Output:** Tool-native config files in each project directory

| Tool | Output file | Location |
|------|-------------|----------|
| Claude | CLAUDE.md | `~/.claude/CLAUDE.md` + `{project}/.claude/CLAUDE.md` |
| Codex | AGENTS.md | `{project}/AGENTS.md` |
| Aider | CONVENTIONS.md | `{project}/CONVENTIONS.md` |
| Cursor | guardrails.mdc | `{project}/.cursor/rules/guardrails.mdc` |

**Behavior:**
- Discovers projects by scanning for `.claude/` directories under each path in `project_roots`
- Also supports explicit project list in config for non-standard locations
- Strictly deterministic: no timestamps, no machine-specific paths, no variable output. Same input → byte-identical output on any machine.
- Writes header in each output: `# Generated by csuite/resilience/generate-configs.sh — do not edit directly`
- Includes SHA256 hash of source files in header — detects external edits on next run and warns before overwriting
- `--verify` mode: checks all outputs match current guardrails, reports drift without overwriting. Suitable for CI.

**CI integration:** Add `generate-configs.sh --verify` to CI pipeline. Fails if any generated file is out of sync with `guardrails.md`. Prevents both drift and merge conflicts from non-deterministic generation.

#### guardrails.md — Canonical Source of Truth

Extracted from current CLAUDE.md, tool-agnostic subset:

1. Epistemic honesty rules
2. Hard guardrails (security, quality, process)
3. Karpathy behavioral principles (think before coding, simplicity, surgical changes, goal-driven execution)
4. Pre-implementation gate
5. Artifact modes table
6. Language-specific overlays (JS/TS, Python, Go, Ruby)
7. Output standards

Everything tool-specific (CSuite skills, MCP servers, hooks, personas) lives only in `tools/claude/template.md`.

### Cross-Platform Strategy

Bash scripts as the single format — works on macOS natively and Windows via Git Bash (which the team already uses).

**Platform divergence points (handled in lib.sh):**

| Concern | macOS | Windows (Git Bash) |
|---------|-------|---------------------|
| Platform detection | `uname -s` → Darwin | `$MSYSTEM` → MINGW / `uname -s` → MSYS |
| Toast notifications | `osascript` (native) | `powershell.exe -NoProfile -Command "..."` (see note) |
| Orphan prevention | Heartbeat file mtime check | Same — heartbeat is cross-platform |
| Path resolution | Native `/Users/...` | `/c/Users/...` (Git Bash) — handled transparently |
| Process background | `&` + `disown` | Same in Git Bash |

**Windows notification note:** Requires PowerShell execution policy to allow the command. `fallback.sh --test` verifies this during setup and warns if notifications won't work. The system does not depend on notifications functioning — they are a convenience. The core fallback logic (tier walking, monitor, state management) works regardless.

### Metrics Integration

Outage events log to `csuite.db` (existing metrics database) when `sqlite3` is available in PATH.

**Graceful degradation when sqlite3 is unavailable:**
- Append metrics to `state/metrics.csv` (same fields, flat file)
- On next run where `sqlite3` is available, `log_metrics()` imports pending CSV rows into the DB and clears the CSV
- The daemon never fails or degrades because of a missing metrics dependency

```sql
CREATE TABLE IF NOT EXISTS outage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    recovered_at TEXT,
    duration_minutes REAL,
    failure_type TEXT NOT NULL,     -- outage | rate_limit | degraded | network
    tier_used TEXT NOT NULL,        -- TEXT not INTEGER: supports 2a, 2b, sidecar
    tool_used TEXT NOT NULL,
    auto_recovered BOOLEAN DEFAULT FALSE,
    platform TEXT NOT NULL
);
```

Over time: "You've fallen back 3 times this quarter, average 45 minutes, always recovered at Tier 1."

### Trust Verification

| Trust signal | Command | What it proves |
|---|---|---|
| Will it work when I need it? | `fallback.sh --dry-run` | Walks tiers, shows what would happen |
| Are my backups configured? | `fallback.sh status` | Readiness of every tier + config sync status |
| Has config drifted? | `generate-configs.sh --verify` | Compares all outputs against current guardrails |
| Is local fallback available? | `fallback.sh --test` | Full prerequisite check, notification test, every tier |
| Is the daemon healthy? | `fallback.sh status` | Monitor running, last check time, current state, heartbeat age |
| Will notifications work? | `fallback.sh --test` | Tests platform-specific notification delivery |

## What This Design Does NOT Do

- Does not replicate CSuite skills/personas in backup tools — outcome parity, not feature parity
- Does not require all tools to be installed — gracefully skips unavailable tiers
- Does not accumulate memory over time — fixed-size sliding window, no history growth
- Does not use complex dependencies — no YAML parser, no Python runtime, no node modules. Pure bash + curl + platform-native notifications. `sqlite3` is optional.
- Does not manage API keys — expects env vars per existing hard guardrails, validates and reports
- Does not auto-launch interactive tools from background processes — notifies with actionable commands instead
- Does not parse Claude Code OAuth tokens — uses status page for Tier 0 health checks

## Team Onboarding

### For engineers who primarily use Claude Code
Nothing changes — Claude is Tier 0, full CSuite. The resilience layer is invisible until needed.

### For engineers who don't use Claude Code
They get guardrails via their tool's native config (AGENTS.md for Codex, CONVENTIONS.md for Aider, .cursor/rules/ for Cursor). They don't need Claude Code installed. The `fallback.sh` tier chain still works — it just skips Tier 0 if Claude isn't available.

### First-time setup
1. Clone the repo (generated configs are committed — guardrails work immediately)
2. Run `fallback.sh status` to see what's ready vs. what needs setup
3. Follow `tools/{tool}/setup.md` for any tool they want to install (per-platform instructions)
4. Set required env vars (API keys)
5. Run `fallback.sh --test` to verify everything works including notifications
6. Done — `fallback.sh` handles the rest

### Per-project config distribution
`generate-configs.sh` discovers projects by scanning for `.claude/` directories under `project_roots`. Generated files are committed — `git pull` delivers updated guardrails without running the generator. CI runs `generate-configs.sh --verify` to catch drift.

## Resolved Questions

1. **Claude Code health check** — Status page only for Tier 0. No OAuth token parsing. `command -v claude` confirms binary presence, `status.anthropic.com/api/v2/status.json` confirms service availability. This covers the 80% case (full outages) without fragile token handling.

2. **Cursor sidecar integration** — Manual choice only. The daemon never suggests or launches Cursor. It stays in the sidecar lane.

3. **Aider multi-provider at Tier 2** — Multiple rows in `tiers.conf` (2a: OpenAI, 2b: Google). The tier chain walks top to bottom, trying each. Adding more providers = adding rows. No code changes needed.

## Review History

### Architecture Review (2026-04-15)
- **18 findings:** 1 Critical, 3 High, 7 Medium, 3 Low, 4 Positive
- **Verdict:** Approved with Issues
- **All issues resolved in this revision:**
  - SQLite dependency → graceful CSV fallback when sqlite3 unavailable
  - Tier 0 health check → status page only, no OAuth parsing
  - Auto-launch UX → notify with actionable command, never auto-launch interactive TUI
  - Generated file conflicts → strict determinism + CI verify check
  - Status page check → explicit JSON API endpoint specified
  - API health check cost → status-page-only for Tier 0, backoff on 429
  - PID orphan prevention → cross-platform heartbeat file instead of parent PID tracking
  - Config validation → `validate_config()` in lib.sh, fail fast on invalid values
  - Log rotation → 1MB max, single backup
  - DEGRADED state → added for rate limiting scenarios
  - Model name verification → configurable `local_model` in resilience.conf
  - Project roots → comma-separated list, not single path
  - Check commands → `command -v` universally, not tool-specific `--version` flags
  - Windows notifications → PowerShell execution policy tested during `--test`, non-blocking if unavailable

### Architecture Review Pass 2 (2026-04-15)
- **7 findings:** 0 Critical, 1 High, 3 Medium, 2 Low, 1 Info
- **Verdict:** Approved with Issues
- **All issues resolved in this revision:**
  - FAILING_OVER state → collapsed to immediate transition, no hold state
  - Network check URL → configurable in resilience.conf for corporate proxy environments
  - Cold start sliding window → reduced threshold (3 consecutive) on daemon startup
  - tiers.conf delimiter → documented as ` | ` (space-pipe-space), commands must not contain it
  - Log rotation safety → write-new-then-rename pattern specified
  - tier_used column → changed from INTEGER to TEXT for non-numeric tier IDs (2a, 2b, sidecar)
  - failover_ready cleanup → cleaned up by fallback.sh on read or by daemon on recovery
