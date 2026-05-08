# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install (editable, with dev deps)
pip install -e ".[dev]"

# Run locally
babel init        # creates ~/.babel/config.yaml on first use
babel start       # starts gateway on :8787

# Docker
docker-compose up -d
curl http://localhost:8787/health

# Lint
black babel/
ruff check babel/

# Tests
pytest
```

## Architecture

Babel is a stateless FastAPI proxy. Incoming OpenAI-compatible requests are routed to external LLM providers based on a YAML config — no database, no state.

**Request flow:**
1. Client → `POST /v1/chat/completions` with `model` field
2. `proxy.py:resolve_provider()` looks up the model in `config.models`, then fetches the matching entry from `config.providers`
3. Request is forwarded via `httpx.AsyncClient` to `provider.base_url/chat/completions`, substituting the provider's API key in the `Authorization` header
4. Streaming responses are piped back as `text/event-stream`; non-streaming responses are returned as-is

**Key files:**
- `babel/config.py` — YAML config loading into `Config`, `ProviderConfig`, `ModelConfig` dataclasses. Config path defaults to `~/.babel/config.yaml`; Docker mounts it at `/root/.babel/config.yaml`
- `babel/proxy.py` — FastAPI app with lifespan-managed `httpx.AsyncClient`; all routing logic lives here
- `babel/cli.py` — Click CLI (`babel start`, `babel init`)
- `data/config.yaml` — runtime config (gitignored); `data/config.example.yaml` is the template

**Adding a provider or model** requires only config changes — no code modifications needed.

**Special case:** `kimi-k2.5` / `kimi-k2.6` models force `temperature=1` when the request contains image content (`proxy.py:157`).

## Configuration shape

```yaml
api_key: optional-secret        # protects Babel itself (Bearer token)

providers:
  <name>:
    base_url: https://...
    api_key: sk-...
    default_headers: {}         # added to every request to this provider

models:
  <model-id>:
    provider: <provider-name>
    base_url: <override>        # optional per-model override
    extra_headers: {}           # merged on top of provider headers

server:
  host: 0.0.0.0
  port: 8787
```
