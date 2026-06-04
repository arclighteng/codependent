# RFC: codependent config schema — locking v0.1, surfacing one-way doors

**Status:** Draft for sign-off. Author: Dade (coder agent). Date: 2026-06-03.
**Companion artifacts:** `schema/v0.1/SCHEMA.md`, `schema/v0.1/schema.yaml`, `schema/v0.1/validate.py`, two example configs under `schema/v0.1/examples/`.

## Why this RFC

The config file is the load-bearing primitive. v0.1 exists and validates, but its status is "draft, expected to iterate" — that ambiguity blocks the control-plane API contract, the web UI editor, `codependent pull/push`, the audit-log schema, and Team-tier billing copy. This RFC forces v0.1 into one of two states — **locked for v1.0** or **frozen pending named changes** — and surfaces the decisions only arc can make.

## What v0.1 already commits to (non-negotiable from here)

| Field             | Required | Type / valid values                                              | Default                                  |
|-------------------|----------|------------------------------------------------------------------|------------------------------------------|
| `version`         | yes      | string, must be `"0.1"` for this validator                       | —                                        |
| `name`            | yes      | string, human label                                              | —                                        |
| `fallback_trigger`| yes      | object: `mode` (`any`\|`all`) + `rules[]`                        | `mode: any`                              |
| `chain`           | yes      | array, ≥2 entries, ordered (index 0 = primary)                   | —                                        |
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
  slack_webhook_url: https://hooks.slack.com/services/T00/B00/XXXX
  events: [on_failover, on_recovery]
  silence_after_seconds: 1800
```

## One-way doors — arc decides, this RFC does not

These shape pricing, GTM, or product surface. Decide before v1.0 is cut.

1. **Schema versioning policy.** Is `version` semver (`"0.1.3"`) or major-only (`"0.1"`)? Pick one and document the deprecation window. Server-side `PUT /api/v1/teams/:id/config` rejection rules depend on this.
2. **Server-side vs client-side validation source of truth.** Does the Go control-plane API re-implement `validate.py`, or does it shell out / port? If they drift, the SaaS contract breaks. Recommend porting to Go and treating the Python validator as a developer convenience only.
3. **Secrets in config.** Today `auth_env` names a local env var, so the YAML carries no secrets. Per-team config in the SaaS will tempt webhooks-with-credentials inline (Slack URL is already inline in the example). Lock in: **never store secrets in the team config blob.** Webhook URLs are pre-signed or vaulted; `slack_webhook_url` becomes a reference to a team-vault entry, not a raw URL. This decision shapes the dashboard UX and the GTM compliance pitch.
4. **One config per team or many.** Web UI assumes one. Some teams will want a dev/prod split. If multi-config is in v1.0, `scope.environments` becomes the selector and the API needs `GET /api/v1/teams/:id/configs`. If not, document "one config per team" as a constraint, not an oversight.
5. **Agent → control-plane event payload shape.** `reporter.sh` (per SPEC.md) posts state transitions. The payload schema is not in v0.1 — it should be, or it should be explicitly out-of-scope and versioned separately. This decision sets the audit-log shape and the timeline view contract.
6. **Promotion criteria for v1.0.** What evidence promotes v0.1 → v1.0? (e.g., 3 paying teams running v0.1 unchanged for 30 days, zero schema-breaking field requests.) Without a written bar, v0.1 stays "draft" forever and the SaaS launches on quicksand.

## Decision requested

Per door above: **lock, defer to v0.2, or kill.** Once signed off, v0.1 is the stable contract; the build (control plane, web UI, `reporter.sh`) unblocks.
