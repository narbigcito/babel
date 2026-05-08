"""
Babel Proxy Module
Minimal FastAPI app - OpenAI-compatible gateway to LLM providers.
No database, no budgets, no tracking. Just proxy.
"""
import os
import json
import uuid
from typing import AsyncGenerator, Dict, Any
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request, Response, HTTPException, Depends
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware

from .config import load_config, Config, DEFAULT_CONFIG_PATH

# Global state
app_state = {
    'config': None,
    'http_client': None,
}


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage application lifespan"""
    config = load_config(DEFAULT_CONFIG_PATH)
    http_client = httpx.AsyncClient(timeout=300.0)

    app_state['config'] = config
    app_state['http_client'] = http_client

    print(f"🗼  Babel gateway started on {config.host}:{config.port}")
    print(f"    Providers: {list(config.providers.keys())}")
    print(f"    Models: {list(config.models.keys())}")

    yield

    await http_client.aclose()
    print("Babel gateway stopped")


def get_config() -> Config:
    return app_state['config']


def get_http_client() -> httpx.AsyncClient:
    return app_state['http_client']


def require_api_key(request: Request, config: Config = Depends(get_config)):
    """Validate Bearer token if api_key is configured"""
    expected = config.api_key
    if not expected:
        return
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or auth[len("Bearer "):].strip() != expected:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


def resolve_provider(config: Config, model: str) -> tuple:
    """Find provider config for a given model"""
    model_cfg = config.models.get(model)
    if not model_cfg:
        # Try to find by partial match
        for name, cfg in config.models.items():
            if model in name or name in model:
                model_cfg = cfg
                break

    if not model_cfg:
        raise HTTPException(
            status_code=404,
            detail=f"Model '{model}' not configured. Available: {list(config.models.keys())}"
        )

    provider = config.providers.get(model_cfg.provider)
    if not provider:
        raise HTTPException(
            status_code=500,
            detail=f"Provider '{model_cfg.provider}' not configured for model '{model}'"
        )

    return provider, model_cfg


def has_image_content(messages: list) -> bool:
    """Check if any message contains image content"""
    for msg in messages:
        content = msg.get('content', '')
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict):
                    if part.get('type') in ('image_url', 'image'):
                        return True
    return False


# Create FastAPI app
app = FastAPI(
    title="Babel",
    description="Universal LLM Gateway - Speak any language",
    version="0.1.0",
    lifespan=lifespan
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
    max_age=600,
)


@app.get("/v1/models")
async def list_models(
    config: Config = Depends(get_config),
    _auth=Depends(require_api_key)
):
    """List available models in OpenAI-compatible format"""
    models_list = []
    for model_name, model_cfg in config.models.items():
        models_list.append({
            "id": model_name,
            "object": "model",
            "created": 1700000000,
            "owned_by": model_cfg.provider,
        })

    return {
        "object": "list",
        "data": models_list
    }


@app.post("/v1/chat/completions")
async def chat_completions(
    request: Request,
    config: Config = Depends(get_config),
    http_client: httpx.AsyncClient = Depends(get_http_client),
    _auth=Depends(require_api_key)
):
    """Proxy chat completions to the appropriate provider"""
    body = await request.json()
    model = body.get('model', 'unknown')
    stream = body.get('stream', False)

    # Resolve provider for this model
    provider, model_cfg = resolve_provider(config, model)

    # kimi-k2.5 and kimi-k2.6 require temperature=1 when using images
    if ('kimi-k2.5' in model.lower() or 'kimi-k2.6' in model.lower()) and has_image_content(body.get('messages', [])):
        body['temperature'] = 1

    # Build target URL
    target_url = f"{provider.base_url.rstrip('/')}/chat/completions"

    # Build headers
    headers = {
        'content-type': 'application/json',
        'authorization': f'Bearer {provider.api_key}',
    }
    # Add provider default headers
    headers.update(provider.default_headers)
    # Add model-specific headers
    headers.update(model_cfg.extra_headers)

    request_id = str(uuid.uuid4())

    try:
        if stream:
            return await handle_streaming_request(
                http_client, target_url, headers, body, request_id
            )
        else:
            return await handle_regular_request(
                http_client, target_url, headers, body, request_id
            )
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Provider error: {e}")


async def handle_regular_request(
    http_client: httpx.AsyncClient,
    target_url: str,
    headers: Dict[str, str],
    body: Dict[str, Any],
    request_id: str
) -> Response:
    """Handle non-streaming request"""
    response = await http_client.post(target_url, headers=headers, json=body)

    return Response(
        content=response.content,
        status_code=response.status_code,
        headers={
            'content-type': response.headers.get('content-type', 'application/json'),
            'x-babel-request-id': request_id,
        }
    )


async def handle_streaming_request(
    http_client: httpx.AsyncClient,
    target_url: str,
    headers: Dict[str, str],
    body: Dict[str, Any],
    request_id: str
) -> StreamingResponse:
    """Handle streaming request - forward chunks from provider"""

    async def stream_generator() -> AsyncGenerator[bytes, None]:
        async with http_client.stream("POST", target_url, headers=headers, json=body) as response:
            async for chunk in response.aiter_bytes():
                yield chunk

    return StreamingResponse(
        stream_generator(),
        media_type="text/event-stream",
        headers={
            'x-babel-request-id': request_id,
        }
    )


@app.get("/health")
async def health():
    """Health check endpoint"""
    config = app_state['config']
    return {
        "status": "healthy",
        "gateway": "babel",
        "version": "0.1.0",
        "providers": list(config.providers.keys()) if config else [],
        "models": list(config.models.keys()) if config else [],
    }
