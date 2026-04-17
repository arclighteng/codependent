# codependent — Troubleshooting

Operator runbook for the top failure modes. Each entry: symptom → cause →
diagnosis → fix.

## Monitor won't start — "Monitor already running"

**Symptom:** `monitor.sh` exits immediately with `"Monitor already running
(PID <N>)"` but no process with that PID exists.

**Cause:** Stale PID file from a crash or SIGKILL.

**Diagnose:**
```bash
cat state/monitor.pid          # print stored PID
kill -0 $(cat state/monitor.pid) 2>&1 || echo "stale"
```

**Fix:**
```bash
rm state/monitor.pid
bash monitor.sh &
```

## `monitor.sh stop` appears to hang

**Symptom:** `monitor.sh stop` sits for several seconds before returning.

**Cause:** The daemon is inside a `sleep`; on Windows Git Bash signals are
deferred until sleep ends. This is expected for up to 10 seconds before the
SIGKILL fallback fires.

**Diagnose:** Wait 10 seconds. If it still hasn't returned, there's a bug —
open an issue.

**Fix:** None needed — the stop command escalates to SIGKILL automatically.

## Status shows "outage" but Anthropic is up

**Symptom:** `fallback.sh status` reports an active outage; `curl
https://status.anthropic.com/api/v2/status.json` works fine.

**Cause:** `network_check_url` (default `https://1.1.1.1`) is blocked by a
corporate proxy or firewall. The daemon classifies this as `network_down` →
`outage`.

**Diagnose:**
```bash
curl -sf --max-time 5 "$(grep '^network_check_url' resilience.conf | cut -d= -f2)"
```

**Fix:** Edit `resilience.conf`, set `network_check_url` to an internal
reachable endpoint (e.g. your corporate gateway), then hot-reload:
```bash
bash monitor.sh reload
```

## Slack alerts not arriving

**Symptom:** `notify_method=slack` is set, outages fire, but Slack channel is
silent.

**Diagnose:**
```bash
# Test the webhook directly
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"text":"codependent test"}' "$(grep '^notify_slack_url' resilience.conf | cut -d= -f2)"
```

**Common causes and fixes:**
- Webhook URL typo or revoked → regenerate in Slack, update `resilience.conf`,
  run `monitor.sh reload`
- Slack rate-limiting → reduce alert volume; the daemon already rate-limits via
  state-machine transitions, but repeated restarts can spam
- Corporate egress filter blocking `hooks.slack.com` → consult your network
  team; the generic `notify_webhook_url` against an internal receiver is an
  alternative

## Metrics DB missing or corrupted

**Symptom:** `fallback.sh history` says `"No history yet"` despite outages
having happened. Or monitor.log contains `"Metrics DB corrupted — recreated"`.

**Diagnose:**
```bash
ls -la ~/.claude/csuite.db*
sqlite3 ~/.claude/csuite.db 'PRAGMA integrity_check;'
```

**Fix:**
- If the DB is missing, nothing to do — the daemon will recreate it on the
  next metric write
- If corrupted, the daemon auto-renames to `csuite.db.corrupted-<epoch>` and
  recreates. Old data is preserved in the `.corrupted-*` file; open it
  read-only with `sqlite3` to recover specific rows if needed

## "Too many open files"

**Symptom:** Errors in `monitor.log` about file handles, or daemon silently
stops.

**Cause:** Log rotation failing to release the old file handle (rare).

**Diagnose:**
```bash
ls -la state/monitor.log*
ulimit -n
```

**Fix:**
```bash
bash monitor.sh stop
rm state/monitor.log.1 2>/dev/null || true
bash monitor.sh &
```

## CI matrix fails on Windows only

**Symptom:** `ubuntu-latest` and `macos-latest` are green, `windows-latest`
fails.

**Likely causes:**
- CRLF vs LF line endings in a test fixture (check `.gitattributes`)
- Path separator — most often `mktemp` on Windows returns a path like
  `/c/Users/.../Temp/...` that some tools don't accept
- A test uses `kill; wait $pid` instead of `terminate_pid` — `wait` can block
  indefinitely under Git Bash when the child is in `sleep`

**Fix:** Reproduce locally in Git Bash, then correct the offending test. Use
`terminate_pid` (defined in `tests/test_monitor.sh`) for any background
process.
