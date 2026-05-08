# Babel

> **Universal LLM Gateway - One API for all models.**

Babel es un gateway minimalista con API compatible con OpenAI. Actúa como proxy universal entre tus aplicaciones (n8n, OpenCode, etc.) y cualquier proveedor de LLMs (cloud o local).

## Features

- **🔌 OpenAI-compatible API**: `/v1/chat/completions` y `/v1/models`
- **☁️ Cloud Providers**: Moonshot, OpenAI, Anthropic, etc.
- **🏠 Local Models**: Ollama, llama.cpp (listo para usar)
- **⚡ Streaming**: Soporte completo para respuestas en streaming
- **🔒 Seguridad**: API key opcional para proteger el gateway
- **🐳 Docker**: Un contenedor, un servicio
- **📡 Sin estado**: No hay base de datos, no hay tracking, no hay complejidad

## Quick Start

### Docker (Recomendado)

```bash
cd babel

# Crear configuración
cp data/config.example.yaml data/config.yaml
# Editar data/config.yaml con tus API keys

# Iniciar
docker-compose up -d

# Verificar
curl http://localhost:8787/health
```

### Local

```bash
# Instalar
pip install -e "."

# Inicializar config
babel init

# Editar ~/.babel/config.yaml

# Iniciar
babel start
```

## Configuración

`~/.babel/config.yaml` o `data/config.yaml`:

```yaml
# Opcional: proteger Babel
# api_key: tu-api-key-secreta

providers:
  moonshot:
    base_url: https://api.moonshot.ai/v1
    api_key: sk-tu-key-moonshot
  openai:
    base_url: https://api.openai.com/v1
    api_key: sk-tu-key-openai
  ollama:
    base_url: http://localhost:11434/v1
    api_key: ollama

models:
  kimi-k2-0711:
    provider: moonshot
  gpt-4o:
    provider: openai
  llama3.2:
    provider: ollama

server:
  host: 0.0.0.0
  port: 8787
```

## Uso

### Con OpenCode

```yaml
providers:
  babel:
    baseURL: http://localhost:8787/v1
    apiKey: sk-dummy-key  # O la api_key de Babel si está configurada

models:
  kimi-k2-0711:
    provider: babel
```

### Con n8n

Usar el nodo **HTTP Request** o **OpenAI** configurado con:
- Base URL: `http://babel:8787/v1`
- API Key: (la de Babel, o cualquiera si no está protegido)

### cURL

```bash
curl http://localhost:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "kimi-k2-0711",
    "messages": [{"role": "user", "content": "Hola"}]
  }'
```

## Endpoints

| Endpoint | Método | Descripción |
|----------|--------|-------------|
| `/v1/models` | GET | Lista modelos disponibles |
| `/v1/chat/completions` | POST | Chat completions (proxy) |
| `/health` | GET | Health check |

## Arquitectura

```
n8n ──┐
      ├──► Babel (8787) ──► Moonshot/OpenAI/Ollama
OpenCode ──┘
```

## License

MIT
