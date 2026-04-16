# OpenAI Codex CLI Setup

OpenAI's CLI for AI-assisted coding. **Codependent Tier 1.**

## Install

```bash
npm install -g @openai/codex
```

## Authentication

```bash
export OPENAI_API_KEY="your-key-here"
```

Add to your shell profile (~/.bashrc, ~/.zshrc, etc.)

## Verify

```bash
command -v codex && codex --version
```

## Codependent Usage

Tier 1 — first fallback when Claude Code is unavailable.
Launched with: `codex --model o3`
