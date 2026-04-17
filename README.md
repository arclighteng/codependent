# codependent

A tiered failover system for AI coding assistants. When your primary tool goes down, codependent detects the outage and gets you working again on the next available option — automatically.

The name is the joke. You're uncomfortably reliant on AI coding tools. This makes that dependency slightly less dangerous.

## How It Works

```
Claude Code (Tier 0) — primary
       ↓ outage detected
Codex (Tier 1) — first fallback
       ↓ not available
Aider + OpenAI (Tier 2a)
       ↓ not available
Aider + Google (Tier 2b)
       ↓ not available
Aider + Ollama (Tier 3) — fully offline, last resort
```

Cursor sits outside the chain as a manual sidecar — always available, never auto-launched.

A background daemon (`monitor.sh`) watches Anthropic's status page every 30 seconds. When it detects an outage, it notifies you and tells you exactly what to run. When Claude recovers (stable for ~5 minutes), it notifies you again.

Your guardrails, coding standards, and behavioral rules follow you across every tool via generated config files — one source of truth, every tool speaks the same language.

## Quick Start

```bash
git clone https://github.com/arclighteng/codependent.git
cd codependent

# See what's available
bash fallback.sh status

# Test notifications and prerequisites
bash fallback.sh --test

# Start the background monitor
bash monitor.sh &

# When an outage hits (or you want to switch manually)
bash fallback.sh        # walks tiers, launches first available
bash fallback.sh 2a     # jump directly to a specific tier
```

## New in Round 3

- **Multi-channel alerts** — `notify_method` is now a comma-separated list.
  Channels: `terminal`, `toast`, `slack`, `webhook`, `both` (legacy). See
  `resilience.conf` for the new `notify_slack_url` and `notify_webhook_url`
  keys.
- **Jittered exponential backoff** — `monitor.sh` adapts check interval on
  sustained failure, capped at 5 minutes with ±10% jitter.
- **Self-healing metrics** — on SQLite corruption, the monitor renames the bad
  file and recreates the schema; a `critical` alert fires.
- **Hot config reload** — edit `resilience.conf`, then `monitor.sh reload`.
  Invalid configs are rejected and the prior config is retained.
- **History CLI** — `fallback.sh history [--limit N] [--since YYYY-MM-DD]`
  shows outages with uptime summary.

See [`docs/architecture.md`](docs/architecture.md) for diagrams and
[`docs/troubleshooting.md`](docs/troubleshooting.md) for the operator runbook.

## Commands

| Command | What it does |
|---------|-------------|
| `fallback.sh status` | Show all tiers, readiness, monitor state |
| `fallback.sh --dry-run` | Show what would launch without launching |
| `fallback.sh --test` | Full system test — tiers, notifications, config validation |
| `fallback.sh` | Walk tiers top-to-bottom, launch first available |
| `fallback.sh <tier>` | Jump to a specific tier (e.g., `fallback.sh 2a`) |
| `monitor.sh` | Start the background health monitor |
| `monitor.sh stop` | Stop the monitor |
| `generate-configs.sh` | Generate tool configs from guardrails.md |
| `generate-configs.sh --verify` | Check for config drift without regenerating |

## Example Output

```
$ bash fallback.sh status
codependent — fallback status

  Tier 0       claude     ✓ ready
  Tier 1       codex      ✗ tool not available
  Tier 2a      aider      ✗ OPENAI_API_KEY not set
  Tier 2b      aider      ✗ GOOGLE_API_KEY not set
  Tier 3       aider      ✓ ready
  Tier sidecar cursor     ✗ tool not available

Monitor: not running
```

When a tier is active or failover is recommended:

```
$ bash fallback.sh status
codependent — fallback status

  Tier 0       claude     ✓ ready
  [... other tiers ...]

Monitor: running (PID 12345)
Heartbeat: 2s ago
Active tier: 2a
```

## Configuration

### resilience.conf

Runtime settings. Key=value, no dependencies.

| Key | Default | What it controls |
|-----|---------|-----------------|
| `check_interval` | `30` | Seconds between health checks |
| `health_check` | `status_page` | Health check method: `status_page`, `api_call`, `both` |
| `recovery_successes` | `10` | Successful checks needed to confirm recovery |
| `recovery_window` | `12` | Sliding window size for recovery detection |
| `failure_window` | `4` | Consecutive failures before declaring outage |
| `degraded_threshold` | `600` | Seconds of degradation before escalating to outage |
| `on_recovery` | `notify` | Recovery action: `notify`, `auto_switch`, `both` |
| `on_failure` | `notify` | Failure action: `notify`, `auto_failover`, `both` |
| `notify_method` | `both` | Notification method: `terminal`, `toast`, `both` |
| `log_to_metrics` | `true` | Log outage events to metrics DB |
| `local_model` | `gemma3` | Ollama model for Tier 3 |
| `project_roots` | `~/Projects` | Comma-separated paths for config generation |
| `heartbeat_timeout` | `600` | Seconds before daemon self-terminates without heartbeat |
| `network_check_url` | `https://1.1.1.1` | URL for network connectivity check |
| `max_log_size` | `1048576` | Max log file size in bytes before rotation |

### tiers.conf

Declarative fallback chain. Each row is tried top-to-bottom.

```
# Format: tier | tool | command | required_env | check_cmd
0       | claude  | claude                                                    |                | command -v claude
1       | codex   | codex --model o3                                          | OPENAI_API_KEY | command -v codex
2a      | aider   | aider --model gpt-4o --read CONVENTIONS.md                | OPENAI_API_KEY | command -v aider
2b      | aider   | aider --model gemini/gemini-2.5-pro --read CONVENTIONS.md | GOOGLE_API_KEY | command -v aider
3       | aider   | aider --model ollama/$local_model --read CONVENTIONS.md   |                | ollama list
sidecar | cursor  | cursor .                                                  |                | command -v cursor
```

Edit this file to change models, add tools, or reorder the chain. Delimiter is ` | ` (space-pipe-space).

The `--read CONVENTIONS.md` flag tells aider to load your generated tool-specific rules on startup. Remove it if you don't use config generation.

## Config Generation

codependent keeps your guardrails consistent across every tool:

```
guardrails.md (canonical rules)
    + tools/claude/template.md  →  .claude/CLAUDE.md
    + tools/codex/template.md   →  AGENTS.md
    + tools/aider/template.md   →  CONVENTIONS.md
    + tools/cursor/template.md  →  .cursor/rules/guardrails.mdc
```

```bash
# Generate configs for all projects in project_roots
bash generate-configs.sh

# Check if any generated files have drifted
bash generate-configs.sh --verify
```

Edit `guardrails.md` for rules that apply to all tools. Edit `tools/<tool>/template.md` for tool-specific additions.

## The Monitor

The background daemon watches Anthropic's status page and manages a state machine:

```
WATCHING → (failures detected) → MONITORING_RECOVERY
    ↑                                    ↓
    ←── (recovery confirmed) ────────────┘

WATCHING → (degraded) → DEGRADED → (escalation) → MONITORING_RECOVERY
```

- **WATCHING**: Normal operation. Checks every `check_interval` seconds.
- **DEGRADED**: API is slow/rate-limited. Exponential backoff on checks. Escalates to full outage after `degraded_threshold` seconds.
- **MONITORING_RECOVERY**: Outage confirmed. Sliding window tracks recovery — needs `recovery_successes` out of `recovery_window` checks to confirm stable. Cold start shortcut: 3 consecutive successes.

The daemon self-terminates if its heartbeat file goes stale (no active tool refreshing it), preventing orphan processes.

## Per-Tool Setup

Setup guides for each tool are in `tools/<tool>/setup.md`:

- [Claude Code](tools/claude/setup.md) — Tier 0
- [Codex](tools/codex/setup.md) — Tier 1
- [Aider](tools/aider/setup.md) — Tiers 2a, 2b, 3
- [Cursor](tools/cursor/setup.md) — Sidecar
- [Ollama](tools/ollama/setup.md) — Tier 3 (local)

You don't need all tiers. Install what you want — codependent skips unavailable tiers automatically.

## Platform Support

Works on macOS and Windows (Git Bash). Pure bash + curl — no Python, Node, or YAML dependencies. sqlite3 is optional (metrics fall back to CSV).

Notifications: macOS uses `osascript`, Windows uses PowerShell toast notifications with BurntToast fallback, everything else gets a terminal bell.

## Team Setup

1. Clone this repo somewhere shared (or fork it)
2. Each team member edits `resilience.conf` for their environment (or use the defaults)
3. Install the tools you want available as fallbacks
4. Run `bash fallback.sh --test` to verify
5. Run `bash generate-configs.sh` to push guardrails to all projects
6. Start the monitor: `bash monitor.sh &`

## Tests

```bash
bash tests/runner.sh          # run all tests
bash tests/runner.sh test_health.sh  # run one file
```

## Architecture

```
fallback.sh          ← entry point (you run this)
monitor.sh           ← background daemon (runs itself)
lib.sh               ← all shared functions
generate-configs.sh  ← config generator
resilience.conf      ← runtime config
tiers.conf           ← fallback chain
guardrails.md        ← canonical rules
tools/               ← per-tool templates and setup guides
state/               ← runtime state (gitignored)
tests/               ← test suite
```
