# RFC: codependent config schema — locking v0.1, surfacing one-way doors

**Status:** Doors closed 2026-06-03. v0.1 schema is the stable contract for SaaS build. Author: Dade (coder agent). Date: 2026-06-03 (updated).
**Companion artifacts:** `schema/v0.1/SCHEMA.md`, `schema/v0.1/schema.yaml`, `schema/v0.1/validate.py`, two example configs under `schema/v0.1/examples/`.

**Decision summary (from arc, 2026-06-03):**

| # | Door                                       | Resolution                                                                                         |
|---|--------------------------------------------|----------------------------------------------------------------------------------------------------|
| 1 | Schema versioning policy                   | **DEFERRED to v0.2.** v0.1 ships with `version: "0.1"` (major-only string); semver vs major-only is a v0.2 decision. |
| 2 | Validation source of truth                 | **LOCKED.** Server-side Go is canonical. `validate.py` is a developer convenience and must be marked as such in its header. |
| 3 | Secrets in config                          | **LOCKED.** Never store secrets inline. All secret-bearing fields are vault references.            |
| 4 | Config cardinality                         | **LOCKED.** Many configs per team allowed. **Hard cap: 4 chain members per config.**               |
| 5 | `reporter.sh` event payload shape          | **LOCKED in v0.1.** Schema defined inline below.                                                   |
| 6 | v1.0 promotion criteria                    | **LOCKED.** Bar defined inline below.                                                              |

## Why this RFC

The config file is the load-bearing primitive. v0.1 exists and validates, but its status is "draft, expected to iterate" — that ambiguity blocks the control-plane API contract, the web UI editor, `codependent pull/push`, the audit-log schema, and Team-tier billing copy. This RFC forces v0.1 into one of two states — **locked for v1.0** or **frozen pending named changes** — and surfaces the decisions only arc can make.

## What v0.1 already commits to (non-negotiable from here)

| Field             | Required | Type / valid values                                              | Default                                  |
|-------------------|----------|------------------------------------------------------------------|------------------------------------------|
| `version`         | yes      | string, must be `"0.1"` for this validator                       | —                                        |
| `name`            | yes      | string, human label                                              | —                                        |
| `fallback_trigger`| yes      | object: `mode` (`any`\|`all`) + `rules[]`                        | `mode: any`                              |
| `chain`           | yes      | array, ≥2 and ≤4 entries, ordered (index 0 = primary)            | —                                        |
| `recovery_trigger`| no       | object: `consecutive_successes`, `window_seconds`, `min_dwell_seconds` | `10 / 300 / 600`                   |
| `scope`           | no       | object: `model_tiers`, `paths`, `users`, `environments`          | applies to all sessions                  |
| `notify`          | no       | object: `channels[]`, URLs, `events[]`, `silence_after_seconds`  | `channels: [terminal]`, `events: [on_failover, on_recovery]` |
| `audit`           | no       | object: `enabled`, `path`, `format` (`jsonl`\|`csv`), `retention_days` | `enabled: false`                   |

**Rule kinds in `fallback_trigger.rules[]`:** `latency_p95_ms`, `error_rate`, `status_page`, `manual`. Closed set. Adding a new kind is a v0.2 break.

**Providers in `chain[].provider`:** `anthropic`, `openai`, `google`, `ollama`, `local`. Closed set. New providers = v0.2 break.

**Notify channels:** `terminal`, `toast`, `slack`, `webhook`. Closed set.

## The failover decision tree (centerpiece)

```
Each provider in `chain` is evaluated in order, starting at index 0 (primary).

  ┌─ primary healthy ────► stay on primary
  │
  ├─ ANY rule in fallback_trigger.rules fires (mode: any)
  │     OR
  │   ALL rules fire simultaneously (mode: all)
  │      │
  │      ▼
  │   switch to next chain entry that passes its health_check
  │      │
  │      ▼
  │   stay on fallback until recovery_trigger satisfies:
  │      consecutive_successes from primary over window_seconds
  │      AND min_dwell_seconds elapsed on fallback (anti-flap)
  │      │
  │      ▼
  │   return to primary
  │
  └─ manual rule (kind: manual) is always available unless enabled: false
```

The **per-team knob** is the rule set in `fallback_trigger`. A team that wants aggressive failover sets `latency_p95_ms: 4000`; a team that wants conservative sets `15000` plus `mode: all`. This is the surface the web UI edits.

## Concrete example — 5-engineer dev team, Claude → Gemini fallback

```yaml
version: "0.1"
name: acme-eng-team-claude-to-gemini

fallback_trigger:
  mode: any
  rules:
    - kind: status_page
      url: https://status.anthropic.com/api/v2/summary.json
      poll_seconds: 30
      degraded_treated_as_failure: false
    - kind: error_rate
      threshold_pct: 5.0
      window_seconds: 60
      counted_as_error: [http_5xx, rate_limit_429]

recovery_trigger:
  consecutive_successes: 10
  window_seconds: 300
  min_dwell_seconds: 600

chain:
  - id: primary-claude
    provider: anthropic
    model: claude-opus-4-7
    auth_env: ANTHROPIC_API_KEY
  - id: fallback-gemini
    provider: google
    model: gemini-2.5-pro
    auth_env: GOOGLE_API_KEY

scope:
  model_tiers: ["*"]
  environments: [dev, prod]

notify:
  channels: [slack]
  slack_webhook_ref: vault://team/acme-eng/slack_webhook   # or env://SLACK_WEBHOOK for local-only
  events: [on_failover, on_recovery]
  silence_after_seconds: 1800
```

> Note: per Door 3 (Secrets in config), inline webhook URLs are rejected by the validator. Use `vault://team/{team_id}/{name}` for SaaS or `env://VAR_NAME` for local-only.

## One-way doors — resolved

### 1. Schema versioning policy — DEFERRED to v0.2

`version` is a string equal to `"0.1"` for this validator (major-only). Whether v0.2 adopts full semver (`"0.2.3"`) and how deprecation windows are documented is a v0.2 decision, deliberately not resolved here. The server-side validator accepts only the exact string `"0.1"` for the duration of v0.1's life.

**Open question (v0.2):** semver vs major-only string, deprecation window length, breaking-change policy.

### 2. Validation source of truth — LOCKED: server-side Go is canonical

The Go control-plane API is the single source of truth for config validation. `validate.py` is reclassified as a **developer convenience** for local editing and CI hooks — not a contract.

**Rationale.** The SaaS sells the contract on `PUT /api/v1/teams/:id/config` and `codependent push`. If the Go server says "valid," it must be valid; if Python disagrees, that's a dev-tooling bug to fix in Python, never in Go. The reverse (Python authoritative, Go re-implements) makes every Go release block on Python tests and turns drift into a paying-customer-facing outage. Porting Python → Go once is cheap; the reverse coupling is permanent tax.

**Concrete requirements:**

- The Go validator and `validate.py` MUST share a single test corpus (`schema/v0.1/testdata/`) — fixtures are the contract.
- Every `validate.py` change MUST land with a Go-side test demonstrating identical behavior, or it is rejected.
- `validate.py`'s file header MUST carry a banner: `# Developer convenience. The Go control plane is the authoritative validator. See RFC.`
- CI MUST run both validators against `schema/v0.1/testdata/` on every PR and fail on any divergence.

### 3. Secrets in config — LOCKED: never store inline

The team config blob MUST NOT contain secrets. This is a hard policy, enforced by the server-side validator.

**Affected fields and replacements:**

| Old shape (rejected)                                              | New shape (required)                                                                  |
|-------------------------------------------------------------------|---------------------------------------------------------------------------------------|
| `slack_webhook_url: https://hooks.slack.com/services/T00/B00/XXX` | `slack_webhook_ref: vault://team/{team_id}/slack_webhook`                             |
| `auth_env: ANTHROPIC_API_KEY` (local agent only)                  | unchanged — `auth_env` already references an env var name, not a secret value         |
| `webhook.url: https://...?token=...`                              | `webhook.url_ref: vault://team/{team_id}/notify_webhook`                              |

**Validator rule.** Any field matching a "looks-like-a-secret" pattern is rejected at validation time:

- Any URL containing `hooks.slack.com/services/T*/B*/*`
- Any URL with a query parameter named `token`, `key`, `secret`, `password`, `auth`
- Any literal bearer token shape (`xox[abp]-`, `sk-`, `ghp_`, `gho_`, etc.)

The validator returns a structured error pointing to the vault-ref form.

**Vault reference shape.** `vault://team/{team_id}/{name}` is opaque to the validator; the control plane resolves it at agent-fetch time. Local-only configs (no SaaS) MAY use `env://VAR_NAME` for the same fields — the validator accepts both `vault://` and `env://` schemes.

### 4. Config cardinality — LOCKED: many per team, cap 4 chain members

A team MAY have multiple configs (dev, prod, per-service, etc.). The control-plane API exposes them as:

- `GET /api/v1/teams/:id/configs` — list
- `GET /api/v1/teams/:id/configs/:config_id` — fetch one
- `PUT /api/v1/teams/:id/configs/:config_id` — upsert
- `DELETE /api/v1/teams/:id/configs/:config_id` — remove

The agent fetches a specific config by ID (set via `CODEPENDENT_CONFIG_ID` env or CLI flag); `scope.environments` does NOT act as a multi-config selector — each config is addressed by ID, scope filters what sessions inside that config it applies to.

**Hard cap: `chain.length ≤ 4`.** The failover party maxes at 4 members per config. Enforced server-side in the Go validator and client-side in `validate.py`. Per arc verbatim: "party is capped at 4 people. No more."

**Rationale for cap.** Failover chains beyond 4 imply a planning problem (cost, latency, or vendor strategy), not a resilience problem. The 4th hop is already operating on degraded assumptions; the 5th is theater. Holding the line at 4 also keeps the dashboard's chain visualization tractable.

### 5. `reporter.sh` event payload shape — LOCKED in v0.1

`reporter.sh` posts state transitions to `POST /api/v1/teams/:team_id/configs/:config_id/events`. Payload is JSON, one event per POST, schema below. Adding fields is non-breaking (consumers MUST ignore unknown fields); removing or renaming fields is a v0.2 break.

```json
{
  "schema_version": "0.1",
  "event_id": "uuid-v4",
  "team_id": "string",
  "config_id": "string",
  "agent_id": "string",
  "occurred_at": "RFC3339 timestamp with milliseconds",
  "reported_at": "RFC3339 timestamp with milliseconds",
  "event_type": "failover|recovery|manual_trigger|health_degraded|health_restored",
  "from_provider": {"id": "primary-claude", "provider": "anthropic", "model": "claude-opus-4-7"},
  "to_provider":   {"id": "fallback-gemini", "provider": "google", "model": "gemini-2.5-pro"},
  "trigger": {
    "rule_kind": "latency_p95_ms|error_rate|status_page|manual",
    "observed_value": "number or string",
    "threshold": "number or string",
    "window_seconds": 60
  },
  "session_scope": {
    "session_id": "string-or-null",
    "user": "string-or-null",
    "path": "string-or-null"
  }
}
```

**Required fields:** `schema_version`, `event_id`, `team_id`, `config_id`, `agent_id`, `occurred_at`, `reported_at`, `event_type`, `from_provider`, `to_provider`.
**Optional fields:** `trigger` (omitted for `manual_trigger`), `session_scope` (omitted when not session-scoped).

**Server contract.** The control plane validates the payload against this schema and rejects with HTTP 400 on schema violation. `event_id` provides idempotency — duplicate `event_id` returns HTTP 200 with no side effect. The audit-log row and timeline-view entity are 1:1 with this payload (no transformation), so this schema also locks the audit-log shape.

### 6. v1.0 promotion criteria — LOCKED

v0.1 → v1.0 promotion requires **all** of the following, evidenced in writing:

1. **3 paying teams** running v0.1 in production for **≥30 consecutive days each**, with no config rewrite required by codependent (teams may edit their own configs; we may not edit theirs to make them work).
2. **Zero schema-breaking field requests** during the trailing 30-day window. A "breaking request" = a customer-blocking ask that cannot be addressed by an additive v0.1 change. Additive requests (new optional fields, new enum values in open sets) do not count.
3. **Go validator and `validate.py` parity** demonstrated by green CI on `schema/v0.1/testdata/` for ≥30 consecutive days.
4. **`reporter.sh` event ingestion** running with <0.1% rejection rate (schema 400s) across all active teams over the trailing 14 days.
5. **Written sign-off** from arc in `RFC-v1.0-promotion.md` referencing the metrics above with timestamps and team IDs.

If any criterion slips, v0.1 stays draft and the v0.2 RFC supersedes this one.

## What unblocks now

With these doors closed, the SaaS build proceeds against v0.1 as a stable contract:

- Go control-plane API: implement the canonical validator against `schema/v0.1/schema.yaml` + `testdata/`.
- Web UI editor: build against the locked field list, with the chain-length cap (4) enforced in the form.
- `reporter.sh`: implement payload per §5; control-plane ingest endpoint and audit-log writer mirror the schema 1:1.
- Vault layer: implement `vault://team/{team_id}/{name}` resolution at agent-fetch time; `env://VAR_NAME` accepted as fallback for local-only deployments.
- Billing copy: "up to 4 providers in a failover chain, multiple configs per team."

## Open for v0.2 (do not address here)

- Schema versioning policy (semver vs major-only, deprecation window).
- Adding `chain` members beyond 4 (will require arc revisit of the cap rationale).
- New provider kinds, new rule kinds, new notify channels.
- Multi-region replication of the events stream.
