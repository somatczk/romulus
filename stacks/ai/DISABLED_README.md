# AI Stack Disabled

The AI stack has been temporarily disabled to save power on the server.

## Services disabled:
- Ollama (GPU-intensive, draws significant power)
- OpenClaw
- Open-WebUI
- AI Socket Proxy

## To re-enable:
1. Rename `compose.yml.disabled` back to `compose.yml`
2. Run `docker compose up -d` in this directory

## Reason for disabling:
The Ollama container is currently unused but draws a lot of power due to GPU usage.