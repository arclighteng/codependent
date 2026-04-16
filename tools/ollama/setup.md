# Ollama Setup

Run LLMs locally. **Used by Codependent Tier 3 via Aider.**

## Install

**macOS:**
```bash
brew install ollama
```

**Windows:**
Download from https://ollama.com/download

## Pull a Model

```bash
ollama pull gemma3
```

(Default model configured in `resilience.conf` as `local_model`)

## Verify

```bash
ollama list
```

## Codependent Usage

Tier 3 — last resort, fully offline. Used via Aider:
`aider --model ollama/gemma3 --read CONVENTIONS.md`
