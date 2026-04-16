# Claude Code Setup

Anthropic's CLI for AI-assisted coding. **Codependent Tier 0 (primary).**

## Install

**macOS / Linux:**
```bash
npm install -g @anthropic-ai/claude-code
```

**Windows (Git Bash):**
```bash
npm install -g @anthropic-ai/claude-code
```

## Authentication

Claude Code uses OAuth — run `claude` and follow the browser prompt.
No API key environment variable needed.

## Verify

```bash
command -v claude && claude --version
```

## Codependent Usage

Tier 0 — the primary tool. Codependent monitors Anthropic's status page
and fails over to lower tiers when Claude Code is unavailable.
