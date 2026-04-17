# codependent — Architecture

Three ASCII diagrams describing the moving parts. ASCII so they render the
same in GitHub, `cat`, `less`, and VS Code preview.

## 1. Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│   ┌──────────────┐       ┌──────────────┐       ┌──────────────────┐    │
│   │ resilience   │──────▶│   lib.sh     │◀──────│   tiers.conf     │    │
│   │ .conf        │       │  (shared)    │       └──────────────────┘    │
│   └──────────────┘       └──────┬───────┘                               │
│                                 │                                       │
│       ┌─────────────────────────┼─────────────────────────┐             │
│       ▼                         ▼                         ▼             │
│  ┌─────────────┐          ┌──────────────┐        ┌──────────────┐      │
│  │ monitor.sh  │          │ fallback.sh  │        │ generate-    │      │
│  │  (daemon)   │          │   (CLI)      │        │ configs.sh   │      │
│  └──────┬──────┘          └──────────────┘        └──────────────┘      │
│         │                                                               │
│         ▼                                                               │
│   ┌────────────┐                                                        │
│   │ state/     │   monitor.pid, monitor.log, failover_ready,            │
│   │            │   recovery_ready, metrics.csv (fallback)               │
│   └────────────┘                                                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                │                 │              │
                ▼                 ▼              ▼
         status.anthropic.com    Slack       generic webhook
           (health source)     (alerts)        (alerts)
```

## 2. State Machine

```
             ┌──────────────────────────┐
             │                          │
             │       WATCHING           │
             │   (check every N secs)   │
             │                          │
             └──┬──────────────┬────────┘
                │              │
     health=    │              │   health=degraded
     outage OR  │              │
     network_   │              │
     down       │              │
     (failure_  │              │
     window)    │              │
                │              │
                ▼              ▼
  ┌──────────────────────┐   ┌──────────────────────────┐
  │ MONITORING_RECOVERY  │   │   DEGRADED               │
  │ (watch for return)   │   │  (jittered backoff,      │
  │                      │   │   wait for sustain       │
  │                      │   │   threshold or recover)  │
  └────────┬─────────────┘   └──────────┬───────────────┘
           │                            │
           │ sliding_window_             │
           │ check_recovery()           │  health=outage OR
           │ returns true               │  sustained >
           │                            │  degraded_threshold
           │                            │
           │                            ▼
           │              ┌──────────────────────┐
           └─────────────▶│ MONITORING_RECOVERY  │
                          └──────────────────────┘
```

## 3. Tier Tree

```
                     ┌─────────────────┐
                     │  Tier 0         │
                     │  claude (Code)  │
                     │  prereq: bash   │
                     └────────┬────────┘
                              │
                  (on failure / unavailable)
                              │
                              ▼
                     ┌─────────────────┐
                     │  Tier 1         │
                     │  codex          │
                     │  prereq: codex  │
                     │  in PATH        │
                     └────────┬────────┘
                              │
                              ▼
                     ┌─────────────────┐
                     │  Tier 2a        │
                     │  aider+OpenAI   │
                     │  prereq:        │
                     │  OPENAI_API_KEY │
                     └────────┬────────┘
                              │
                              ▼
                     ┌─────────────────┐
                     │  Tier 2b        │
                     │  aider+Google   │
                     │  prereq:        │
                     │  GEMINI_API_KEY │
                     └────────┬────────┘
                              │
                              ▼
                     ┌─────────────────┐
                     │  Tier 3         │
                     │  aider+Ollama   │
                     │  prereq: ollama │
                     │  in PATH        │
                     └─────────────────┘
```

Notes:
- Sidecar tier (if present in `tiers.conf`) is never auto-launched; it only
  surfaces when the operator explicitly runs `fallback.sh sidecar`.
- `check_tier_prerequisites` gates each arrow; skips continue down the tree.
