"""
Babel Config Module
Simple YAML configuration for providers and models.
"""
import os
import yaml
from pathlib import Path
from dataclasses import dataclass, field
from typing import Dict, List, Optional

DEFAULT_CONFIG_DIR = Path.home() / ".babel"
DEFAULT_CONFIG_PATH = DEFAULT_CONFIG_DIR / "config.yaml"


@dataclass
class ModelConfig:
    """Model configuration"""
    name: str
    provider: str
    # Optional: override base_url for this model
    base_url: Optional[str] = None
    # Optional: extra headers
    extra_headers: Dict[str, str] = field(default_factory=dict)


@dataclass
class ProviderConfig:
    """Provider configuration"""
    name: str
    base_url: str
    api_key: str
    # Default headers for all requests
    default_headers: Dict[str, str] = field(default_factory=dict)


@dataclass
class Config:
    """Babel configuration"""
    providers: Dict[str, ProviderConfig]
    models: Dict[str, ModelConfig]
    # Server settings
    host: str = "0.0.0.0"
    port: int = 8787
    # Optional API key to protect Babel itself
    api_key: Optional[str] = None


def load_config(path: Optional[Path] = None) -> Config:
    """Load configuration from YAML file"""
    config_path = path or DEFAULT_CONFIG_PATH

    if not config_path.exists():
        raise FileNotFoundError(
            f"Config not found: {config_path}\n"
            f"Run: babel init"
        )

    with open(config_path, 'r') as f:
        data = yaml.safe_load(f) or {}

    # Parse providers
    providers = {}
    for name, pdata in data.get('providers', {}).items():
        providers[name] = ProviderConfig(
            name=name,
            base_url=pdata['base_url'],
            api_key=pdata.get('api_key', ''),
            default_headers=pdata.get('default_headers', {})
        )

    # Parse models
    models = {}
    for name, mdata in data.get('models', {}).items():
        models[name] = ModelConfig(
            name=name,
            provider=mdata['provider'],
            base_url=mdata.get('base_url'),
            extra_headers=mdata.get('extra_headers', {})
        )

    server = data.get('server', {})

    return Config(
        providers=providers,
        models=models,
        host=server.get('host', '0.0.0.0'),
        port=server.get('port', 8787),
        api_key=data.get('api_key')
    )


def ensure_config_exists():
    """Create default configuration if it doesn't exist"""
    DEFAULT_CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    if DEFAULT_CONFIG_PATH.exists():
        return

    default_config = """# Babel Configuration
# Simple LLM Gateway - OpenAI Compatible API

# Optional: protect Babel with an API key
# api_key: your-secret-key

providers:
  moonshot:
    base_url: https://api.moonshot.ai/v1
    api_key: sk-your-moonshot-key
  openai:
    base_url: https://api.openai.com/v1
    api_key: sk-your-openai-key
  # ollama:
  #   base_url: http://localhost:11434/v1
  #   api_key: ollama  # Ollama doesn't require a real key

models:
  # Moonshot models
  kimi-k2-0711:
    provider: moonshot
  kimi-k2.5:
    provider: moonshot

  # OpenAI models
  # gpt-4o:
  #   provider: openai

  # Local models via Ollama
  # llama3.2:
  #   provider: ollama

server:
  host: 0.0.0.0
  port: 8787
"""

    with open(DEFAULT_CONFIG_PATH, 'w') as f:
        f.write(default_config)

    print(f"Created default config: {DEFAULT_CONFIG_PATH}")
