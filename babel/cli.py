"""
Babel CLI Module
Simple command-line interface.
"""
import uvicorn
import click

from .config import ensure_config_exists, DEFAULT_CONFIG_PATH
from .proxy import app


@click.group()
@click.version_option(version="0.1.0", prog_name="babel")
def cli():
    """Babel - Universal LLM Gateway
    
    OpenAI-compatible API for local and cloud LLMs.
    """
    pass


@cli.command()
@click.option('--host', default=None, help='Host to bind to')
@click.option('--port', default=None, type=int, help='Port to bind to')
def start(host, port):
    """Start the gateway server"""
    ensure_config_exists()
    
    # Load config to get defaults
    from .config import load_config
    config = load_config(DEFAULT_CONFIG_PATH)
    
    host = host or config.host
    port = port or config.port
    
    click.echo(f"🗼  Babel starting on {host}:{port}")
    click.echo(f"    Models: {list(config.models.keys())}")
    click.echo(f"    Health: http://{host}:{port}/health")
    
    uvicorn.run(
        "babel.proxy:app",
        host=host,
        port=port,
        log_level="info",
        reload=False
    )


@cli.command()
def init():
    """Initialize Babel configuration"""
    ensure_config_exists()
    click.echo("✓ Babel initialized")
    click.echo(f"  Config: {DEFAULT_CONFIG_PATH}")
    click.echo("  Edit the file and add your API keys")


# Entry point
def main():
    cli()


if __name__ == '__main__':
    main()
