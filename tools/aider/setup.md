# Aider Setup

AI pair programming in your terminal. **Codependent Tiers 2a, 2b, 3.**

## Install

```bash
pip install aider-chat
```

Or with pipx:
```bash
pipx install aider-chat
```

## Authentication

**Tier 2a (OpenAI):** `export OPENAI_API_KEY="your-key-here"`
**Tier 2b (Google):** `export GOOGLE_API_KEY="your-key-here"`
**Tier 3 (Ollama):** No API key needed (local model)

## Verify

```bash
command -v aider && aider --version
```

## Codependent Usage

- Tier 2a: `aider --model gpt-4o --read CONVENTIONS.md`
- Tier 2b: `aider --model gemini/gemini-2.5-pro --read CONVENTIONS.md`
- Tier 3: `aider --model ollama/$local_model --read CONVENTIONS.md`
