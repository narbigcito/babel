# AGENTS.md - Babel

Universal LLM Gateway. OpenAI-compatible API for local and cloud models.

## Project Structure

```
babel/
├── babel/
│   ├── __init__.py
│   ├── config.py        # YAML config loading
│   ├── proxy.py         # FastAPI app (the gateway)
│   └── cli.py           # CLI: babel <cmd>
├── Dockerfile
├── docker-compose.yml
├── pyproject.toml
└── data/
    └── config.yaml      # Runtime config (gitignored)
```

## Quick Start

```bash
# Local dev
pip install -e "."
babel init              # Creates ~/.babel/config.yaml
babel start             # Runs on :8787

# Docker
docker-compose up -d
curl http://localhost:8787/health
```

## Configuration

Config lives in `~/.babel/config.yaml` (local) or mounted at `/root/.babel/config.yaml` (Docker).

```yaml
providers:
  <name>:
    base_url: <url>
    api_key: <key>
    default_headers: {}  # optional

models:
  <model-id>:
    provider: <provider-name>
    base_url: <override>  # optional
    extra_headers: {}     # optional

server:
  host: 0.0.0.0
  port: 8787

# Optional: protect the gateway itself
api_key: your-secret
```

## How it Works

1. Client sends request to `POST /v1/chat/completions` with `model` field
2. Babel looks up model in config → finds provider
3. Babel proxies request to provider's base_url with provider's api_key
4. Response streamed back to client unchanged

## Adding a New Provider

1. Add provider to `config.yaml` under `providers:`
2. Add models under `models:` pointing to that provider
3. Restart Babel

No code changes needed.

## Development

```bash
# Lint
black babel/
ruff check babel/

# Test
pytest
```

## Production Notes

- Babel is stateless. No DB, no volumes needed (except config).
- Set `api_key` in production to prevent unauthorized access.
- Use Docker healthcheck (already configured).
- For HTTPS, put behind a reverse proxy (nginx, traefik, etc.).

## Ports

| Environment | URL |
|-------------|-----|
| Local | http://localhost:8787 |
| Docker | http://localhost:8787 |
| Internal (containers) | http://babel:8787 |
