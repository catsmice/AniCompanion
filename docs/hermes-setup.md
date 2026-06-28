# Setting up Hermes Agent for AniCompanion

AniCompanion has no built-in LLM. It connects to a local **[Hermes Agent](https://github.com/NousResearch/hermes-agent)**
gateway over its OpenAI-compatible HTTP API. This guide covers the AniCompanion-specific parts;
for installing and configuring Hermes itself, follow the official
[Hermes docs](https://hermes-agent.nousresearch.com).

## 1. Install Hermes and pick a model

Install Hermes Agent and configure a model provider (for example, OpenRouter pointing at a Claude
or other model). Confirm it works on its own first — e.g. with the Hermes CLI — before wiring up
the app.

## 2. Enable the HTTP API server

The Hermes **CLI** and the **HTTP API server (gateway)** are separate. AniCompanion needs the
gateway. In `~/.hermes/.env`:

```ini
API_SERVER_ENABLED=true
API_SERVER_KEY=<your-key>
```

- Generate a key with `openssl rand -hex 32`. It only guards your local gateway, but don't use a
  guessable placeholder.
- A starter file is provided at [`examples/hermes.env`](../examples/hermes.env).

## 3. Start the gateway

```bash
hermes gateway
# → [API Server] API server listening on http://127.0.0.1:8642
```

Leave it running. Verify it's healthy:

```bash
curl http://127.0.0.1:8642/health
# → {"status": "ok", "platform": "hermes-agent", ...}
```

And that streaming chat works (replace the key):

```bash
curl -sN http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"say hi"}],"stream":true}'
# → a stream of `data: {chat.completion.chunk}` lines, ending with `data: [DONE]`
```

## 4. Point the app at it

In AniCompanion's **Settings (⚙️) → Connection**:

- **Agent backend**: `Hermes Agent`
- **Endpoint**: `http://127.0.0.1:8642`
- **API Key**: the same `API_SERVER_KEY` value

Save. The connection indicator turns green when the gateway's `/health` responds. The `model` field
the app sends (`hermes-agent`) is cosmetic — your Hermes config decides the actual LLM.

## 5. (Optional) MCP tools for richer proactive behavior

When 小光 has been idle for a while she does a self-directed activity (research a topic, recommend
something, teach a Japanese word) and shares it. These prompts are **tool-agnostic**:

- With **no tools configured**, she answers from the model's own knowledge — everything still works.
- If you configure **MCP servers** in Hermes (e.g. web search, maps, email), the Hermes agent will
  use them automatically when a task benefits, making her replies live and grounded.

Configure MCP servers in Hermes per its docs; AniCompanion needs no changes and references no
specific tool names. Anything that may post or send outward should still be confirmed with you —
the system prompt instructs her to ask first.

## Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| App shows "Hermes rejected the API key (HTTP 401)" | The key in Settings doesn't match `API_SERVER_KEY` in `~/.hermes/.env`. Re-enter it and Save. |
| Connection indicator stays red / "not connected" | Gateway isn't running or wrong endpoint. Start `hermes gateway`; confirm `curl .../health` returns 200. |
| Chat does nothing, no error | Hermes' model provider isn't configured or is failing. Test Hermes directly (CLI / curl) first. |
| Nothing on port 8642 | `API_SERVER_ENABLED=true` missing, or you started the CLI instead of `hermes gateway`. |
