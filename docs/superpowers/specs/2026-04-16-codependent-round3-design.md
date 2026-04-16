# Codependent Round 3 — Lightweight 24/7 Hardening

**Date:** 2026-04-16
**Status:** Design (awaiting plan)
**Supersedes:** nothing (additive to `2026-04-15-resilience-platform-design.md`)
**Prior work:** Round 2 closed the set-e / race / signal-handling bugs that were
blocking reliable 24/7 operation. This round adds the operational features a
long-running daemon needs without making codependent heavy.

---

## 1. Goal

Make codependent good enough to leave running for weeks at a time on a developer
workstation, surviving:

- Operator inattention (needs out-of-band alerting, not just terminal toasts)
- Transient failures under load (needs jittered backoff, not fixed cadence)
- Local SQLite corruption (needs to self-recover, not silently drop metrics)
- Config edits while running (needs hot reload, not a restart)

…and make it comprehensible without reading source:

- CI proves it on the three supported platforms on every push
- A troubleshooting runbook covers the top failure modes
- An architecture doc shows the moving parts at a glance
- A history CLI surfaces what the daemon has been doing

Staying lightweight is a first-class constraint. No installer, no supervisor, no
background doctor. Everything is additive bash inside the existing file layout.

## 2. Non-Goals

Explicitly **not** in this round:

- Installer / uninstaller / packaging
- `systemd` units or launchd plists
- A supervisor process or auto-restart wrapper
- A `codependent doctor` command
- SMTP alerting, PagerDuty, OpsGenie
- `inotify` / `fswatch` file-watching for config reload
- Metric export (Prometheus, OpenTelemetry)
- Windows-native Service wrapper

If these are wanted later, they're Round 4+.

## 3. Architecture Changes (Overview)

```
┌───────────────────────────────────────────────────────────────────────┐
│  monitor.sh (daemon)                                                  │
│  ┌──────────────┐   ┌──────────────┐   ┌───────────────────────────┐  │
│  │ health check │──▶│ state machine│──▶│ notify_dispatch           │  │
│  └──────────────┘   └──────┬───────┘   │  ├─ terminal               │  │
│                            │           │  ├─ toast                  │  │
│         ┌──────────────────┘           │  ├─ slack   (NEW)          │  │
│         ▼                              │  └─ webhook (NEW)          │  │
│  ┌──────────────┐                      └───────────────────────────┘  │
│  │next_check_   │  (NEW — jittered exp. backoff)                      │
│  │interval      │                                                     │
│  └──────────────┘                                                     │
│         │                                                             │
│         ▼                                                             │
│  ┌──────────────┐   ┌──────────────────────────────────────────────┐  │
│  │ log_metrics  │──▶│ SQLite w/ integrity_check + recovery (NEW)   │  │
│  └──────────────┘   └──────────────────────────────────────────────┘  │
│                                                                       │
│  trap 'reload_config' HUP   (NEW)                                     │
└───────────────────────────────────────────────────────────────────────┘
     ▲                                     ▲
     │ SIGHUP                              │
     │                                     │
┌────┴────────────┐                 ┌──────┴──────────────┐
│ monitor.sh      │                 │ fallback.sh history │  (NEW)
│   reload  (NEW) │                 └─────────────────────┘
└─────────────────┘
```

No new long-running processes. No new daemons. All additions are either
in-process (trap, helper function) or short-lived CLI invocations.

## 4. Detailed Design

### 4.1 Notifications — Slack + generic webhook (#5)

**Config keys (new in `resilience.conf`):**

```
# Multi-channel notification — comma-separated list
# Values: terminal, toast, slack, webhook, both (back-compat: terminal+toast)
notify_method=terminal,slack

# Slack incoming webhook URL (if "slack" in notify_method)
notify_slack_url=

# Generic webhook URL — receives JSON {timestamp, level, message, event}
# (if "webhook" in notify_method)
notify_webhook_url=
```

**Semantics:**

- `notify_method` is parsed as comma-separated; whitespace trimmed per entry
- Legacy `both` continues to mean `terminal,toast`
- Unknown channel names log a warning once at startup and are ignored
- Empty URL for an enabled channel logs a warning once at startup and disables
  that channel (the daemon does not exit)

**Wire format — Slack:**

```json
{"text": "codependent: <message>"}
```

Plain `text` only — no Block Kit, no attachments. Keeps the payload small and
avoids Slack API schema churn.

**Wire format — generic webhook:**

```json
{
  "timestamp": "2026-04-16T18:42:01Z",
  "level": "warning",
  "event": "api_down",
  "message": "Anthropic API down. Next available: Tier 1 (codex). Run: fallback.sh 1"
}
```

`level` ∈ {info, warning, critical}. `event` ∈ {startup, api_down, api_degraded,
api_recovered, db_corrupted, config_reloaded}. Both keys are new taxonomy —
lib.sh functions will pass them through `notify_dispatch`.

**Delivery:**

- `curl -sS -m 10 -X POST -H 'Content-Type: application/json' -d "$payload" "$url"`
- Non-zero curl exit → log a warning; never crash the daemon
- No retries, no queueing (if Slack is down during an outage, the terminal +
  toast channels still fire)

**Functions added in `lib.sh`:**

```
notify_slack url message
notify_webhook url level event message
```

`notify_dispatch` is extended to iterate `notify_method` and call the
corresponding function for each channel.

### 4.2 Jittered exponential backoff (#6)

**Helper (new in `lib.sh`):**

```
next_check_interval base failures
```

Returns the next `sleep` interval in seconds. Algorithm:

```
raw    = base * 2^failures               (failures capped so raw ≤ 300)
jitter = random integer in [-raw/10, +raw/10]
out    = max(base, min(300, raw + jitter))
```

`$RANDOM` is the jitter source. Cap is hardcoded at 300s.

**Where it's used in `monitor.sh`:**

- `WATCHING`: on consecutive health-check curl failures, take
  `max(CFG_check_interval, next_check_interval(base, failures))`
  rather than a flat `CFG_check_interval`
- `DEGRADED`: replaces the current `CURRENT_INTERVAL=$((CURRENT_INTERVAL * 2))`
  line with `CURRENT_INTERVAL=$(next_check_interval "$CFG_check_interval" "$deg_failures")`
- `MONITORING_RECOVERY`: unchanged — still fixed cadence, because we want prompt
  recovery detection

A `consecutive_network_failures` counter is added to `WATCHING` state, reset to
zero on any successful check.

### 4.3 SQLite corruption recovery (#7)

**Where:** `log_metrics` in `lib.sh`.

**Flow:**

```
INSERT → fail
  ↓
run `sqlite3 $db 'PRAGMA integrity_check;'`
  ↓                       ↓
result = "ok"        result != "ok"
  ↓                       ↓
log warning,         mv  metrics.db  metrics.db.corrupted-<epoch>
return non-fatal     sqlite3 metrics.db < schema.sql
                     notify_dispatch "critical" "db_corrupted" \
                       "Metrics DB corrupted — recreated. Old file: <path>"
                     retry INSERT once
                       ↓                  ↓
                     success            still fails
                       ↓                  ↓
                     return 0           append to metrics.csv.fallback
                                        (one line per metric, CSV)
```

**Schema recreation:** An `init_metrics_db` function (already partly present in
`lib.sh` for fresh installs) is extracted so the recovery path can reuse it.

**CSV fallback format:**

```
timestamp,event,state,detail
2026-04-16T18:42:01Z,api_down,MONITORING_RECOVERY,tier=1
```

Appending to the CSV is best-effort. If even that fails (disk full, permission),
the metric is dropped with a single log line.

**Corruption is rare and loud:** The `critical` alert fires through every
configured channel (terminal, toast, slack, webhook).

### 4.4 Hot config reload — SIGHUP + `reload` subcommand (#8)

**In-process:**

```bash
trap 'reload_config' HUP
```

`reload_config`:

1. Loads candidate config into a temp namespace (e.g. `NEWCFG_*` vars)
2. Runs validators (same checks `load_config` already has: positive integers,
   valid enum values, URL shape for webhook keys)
3. If validation **passes**: copy `NEWCFG_*` → `CFG_*`, reset
   `CURRENT_INTERVAL` to `CFG_check_interval`, emit `info` notification
   `"Config reloaded"`, emit `config_reloaded` metric
4. If validation **fails**: log warning with specific error, keep old config,
   emit `warning` notification `"Config reload failed: <reason>. Keeping prior config."`

Reload is a no-op for changes that require daemon restart to take effect
(`check_interval` changes mid-sleep don't interrupt the current sleep; the new
value applies on the next iteration). That's documented, not fixed.

**CLI:**

```
monitor.sh reload
```

Reads `monitor.pid`, `kill -HUP <pid>`. If the PID file is missing or the PID
isn't alive, exits 1 with `"monitor not running"`.

### 4.5 CI matrix (#11)

**New file:** `.github/workflows/ci.yml`

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4
      - name: Install sqlite3 (linux)
        if: runner.os == 'Linux'
        run: sudo apt-get install -y sqlite3
      - name: Install sqlite3 (macos)
        if: runner.os == 'macOS'
        run: brew install sqlite
      # windows-latest git-bash already ships sqlite3
      - name: Run tests
        run: bash tests/runner.sh
```

**Platform guards:** Tests that rely on `notify_toast` or platform-specific
binaries must already skip gracefully on other platforms. Any gap found while
green-ing the matrix is fixed reactively — no preemptive rewriting of tests.

### 4.6 Troubleshooting runbook (#12)

**New file:** `docs/troubleshooting.md`

Structured as FAQ, each entry:

1. **Symptom** (what the user sees)
2. **Likely cause**
3. **Diagnosis command**
4. **Fix**

Entries in v1:

- Monitor won't start — stale PID file
- `monitor.sh stop` hangs — covered by Round 2 fix, but sanity check
- Status shows "outage" but Anthropic is up — network check URL unreachable
  behind corporate proxy
- Slack alerts not arriving — webhook URL wrong or Slack rate-limiting
- Metrics DB missing / corrupted — point at recovery path
- "Too many open files" — log rotation failing
- CI fails on Windows — usually a path separator or line-ending issue

### 4.7 Architecture diagrams (#13)

**New file:** `docs/architecture.md`

Three ASCII diagrams:

1. **Component diagram** — monitor.sh, fallback.sh, lib.sh, state/, config files,
   external: Anthropic status page, Slack, webhook target
2. **State machine diagram** — WATCHING → DEGRADED ↔ MONITORING_RECOVERY →
   WATCHING with transition labels (which events trigger which transitions)
3. **Tier tree diagram** — T0 Claude → T1 Codex → T2a Aider+OpenAI →
   T2b Aider+Google → T3 Aider+Ollama (with prerequisite check on each arrow)

ASCII is deliberate. It renders everywhere (GitHub, terminal `cat`, VS Code
preview, `less`) and doesn't require a rendering toolchain.

### 4.8 History CLI (#14)

**New subcommand:** `fallback.sh history [--limit N] [--since YYYY-MM-DD]`

**Defaults:** `--limit 20`, `--since` unset (all time).

**Output:**

```
codependent — fallback history

Summary (last 20 events, since: all time):
  failovers:  4
  recoveries: 4
  uptime:     98.2%  (over 12d 4h)

TIMESTAMP             EVENT           STATE                  DETAIL
2026-04-16T18:42:01Z  api_down        MONITORING_RECOVERY    tier=1
2026-04-16T18:47:33Z  api_recovered   WATCHING               -
...
```

Rendered with `column -t` for alignment. No colors (keeps it pipe-safe).

**Graceful degradation:**

- `sqlite3` not installed → print hint: `"sqlite3 not found — install it to enable history"`
- `metrics.db` missing → print hint: `"No history yet — daemon hasn't recorded any events"`
- DB exists but empty → print header + empty-state line

**Flags validated:**

- `--limit` must be positive integer, 1–1000
- `--since` must match `^\d{4}-\d{2}-\d{2}$`

Invalid flags exit 1 with a usage message.

## 5. Testing Plan

**New tests (target ~15, suite stays under 4 minutes):**

`tests/test_notify.sh`:
- `notify_method` comma-split parsing
- Slack payload shape
- Webhook payload shape (timestamp / level / event / message)
- Unknown channel warning
- Empty-URL channel disables gracefully

`tests/test_backoff.sh`:
- `next_check_interval` respects base floor
- Respects 300s ceiling
- Jitter lives in ±10% window over N=50 trials
- Monotonic growth (before cap) across increasing `failures`

`tests/test_db_recovery.sh`:
- Corrupt DB triggers rename + recreate
- New DB has schema
- Old file is preserved with `.corrupted-<ts>` suffix
- CSV fallback appends correctly when recreate also fails
- Critical alert fires

`tests/test_reload.sh`:
- SIGHUP with valid config swaps values
- SIGHUP with invalid config keeps old values + warning
- `monitor.sh reload` sends SIGHUP to correct PID
- `monitor.sh reload` exits 1 when no monitor running

`tests/test_history.sh`:
- `fallback.sh history` prints header + table
- `--limit` validation
- `--since` validation
- Empty-DB output
- Missing-sqlite3 hint

**Existing tests:** expected to stay green without modification.

**Suite budget:** current suite ≈ 70s on Windows Git Bash. New tests target <3s
each, most <1s. Total budget 4min under CI cold-start overhead.

## 6. Rollout

Single PR, single commit series. No feature flags — the new config keys have
safe defaults (`notify_slack_url=""` disables Slack; existing configs keep
working).

**Backwards compatibility:**

- `notify_method=both` continues to mean `terminal,toast`
- Unrecognized config keys are ignored with a startup warning (already the case)
- Metrics schema is unchanged — no migration

## 7. Open Questions

None blocking. Minor ones to revisit during implementation:

- Should `notify_webhook_url` support multiple URLs (array)? → deferred; if
  needed, a user can forward via their own receiver
- Should `history` default include full message text vs. `detail`? → deferred;
  `detail` column is compact, full message can be added if noisy

## 8. Appendix — File Touches

**Modified:**

- `lib.sh` — add `notify_slack`, `notify_webhook`, `next_check_interval`,
  `reload_config`, `init_metrics_db` (extracted); extend `notify_dispatch`,
  `log_metrics`, `log_metrics` failure path
- `monitor.sh` — `trap HUP`, `reload` subcommand, use `next_check_interval`,
  `consecutive_network_failures` counter
- `fallback.sh` — add `history` subcommand + arg parser
- `resilience.conf` — add `notify_slack_url`, `notify_webhook_url`, update
  `notify_method` comment
- `README.md` — one-paragraph callout of new features + link to new docs

**Added:**

- `.github/workflows/ci.yml`
- `docs/troubleshooting.md`
- `docs/architecture.md`
- `tests/test_backoff.sh`
- `tests/test_db_recovery.sh`
- `tests/test_reload.sh`
- `tests/test_history.sh`
- `tests/test_notify.sh` additions (file exists)

**Unchanged:** `generate-configs.sh`, `tiers.conf`, `guardrails.md`,
`tools/`, `state/`.
