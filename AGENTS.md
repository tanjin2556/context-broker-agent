# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## What this is

A three-process scaffold that lets isolated Claude Code sessions—one per project dev container, each with its own context window—share context over a Docker network. There is no test suite, no linter config, and no CI; it is deployed by copying files into containers.

The pieces live in one flat folder but **run in different places**, which is the single most important thing to keep straight when editing:

| File | Runs | Language | Role |
|---|---|---|---|
| `broker.py` | its own container (`docker-compose.broker.yml`) | Python / FastMCP | central hub |
| `resident_agent.py` + `start_agent.sh` | *inside each project's existing dev container*, backgrounded | Python / Claude Agent SDK | per-project expert |
| `context_bridge.mjs` | stdio subprocess of each interactive session | Node / MCP JS SDK | per-session push relay |

`install.sh` is the fourth kind of thing here: it runs on the *user's* machine, downloads the five project-side files plus `AGENT_SETUP.md` from the public repo (or copies them from a clone), and merges the two `.mcp.json` entries. It is POSIX `sh`, not bash, and is meant to survive `curl | sh` — so no `read`, no bashisms, and the `.mcp.json` merge shells out to python3/python/node in that order, probing each with a throwaway program before trusting it — a `command -v` hit is not proof it runs, since Windows ships a Store-alias `python3.exe` that executes nothing. If you add or rename a project-side file, update `FILES` in it.

Only the broker is a container you deploy. `resident_agent.py`, `start_agent.sh`, `agent.env.example`, and `context_bridge.mjs` are *copied into* other projects' containers—treat them as artifacts shipped elsewhere, so avoid adding imports/deps that assume this folder's environment.

## Commands

```bash
# Broker—build + run (from this folder)
docker compose -f docker-compose.broker.yml up -d --build
docker compose -f docker-compose.broker.yml ps          # expect "healthy"
docker compose -f docker-compose.broker.yml logs -f
curl http://localhost:8000/healthz                      # {"ok":true,"projects":N,"notes":N}

# Broker—run directly, no container
pip install -r requirements.txt
BROKER_DB=:memory: python broker.py                     # 0.0.0.0:8000, MCP at /mcp

# Resident agent (in a project's dev container, after copying the files there)
./install.sh --dir /path/to/project   # or: curl -fsSL <raw>/install.sh | sh
cp agent.env.example agent.env && ./start_agent.sh
./start_agent.sh status | stop

# Interactive session with the push channel enabled (in a project container)
claude --dangerously-load-development-channels server:context-bridge
```

`docker compose ... down -v` wipes the `broker-data` volume (board + registry). `start_agent.sh` creates its own venv at `.agent/venv` and logs to `.agent/agent.log`.

`/mcp` speaks MCP—never curl it to check liveness; use `/healthz`.

## Architecture

Two independent directions of traffic, and conflating them is the usual source of confusion:

- **Pull**—a session calls the broker's MCP tools over streamable HTTP at `http://broker:8000/mcp`. Registered in `.mcp.json` as `{"type":"http"}`.
- **Push**—the broker enqueues a message; `context_bridge.mjs` long-polls `GET /bridge/next/{project}` (25s server-side timeout, empty `{}` on miss) and emits it as a `notifications/claude/channel` notification, which the session renders as a `<channel>` event. Registered in `.mcp.json` as a *separate* stdio entry. A channel **must** be a local stdio subprocess—it cannot be the remote broker, which is why there are two MCP registrations per project and why this one file is JavaScript (the channel wire contract is defined against the MCP JS SDK). Neither `.mcp.json` entry carries per-project values: `context_bridge.mjs` reads `PROJECT_NAME`/`BROKER_URL` from `$AGENT_ENV` or the `agent.env` beside it (the same file `start_agent.sh` sources), with the real environment taking precedence over the file. So `.mcp.json` is identical in every project, and a project is renamed in exactly one place.

`ask_project` is a third path: synchronous request/response. The broker POSTs `/ask` on the target project's registered `endpoint`, which is the resident agent's aiohttp server (default `http://<container-hostname>:9100`). Passing the same `conversation_id` across calls keeps a stateful `ClaudeSDKClient` alive on the agent side (capped at `MAX_CONVERSATIONS = 50`, oldest evicted); omitting it runs a stateless one-shot `query()`.

Registration is self-service: on startup the resident agent POSTs `/internal/register` with its name and `SELF_ENDPOINT`. Nothing in the broker discovers projects on its own.

### State in `broker.py`

Board (`notes`) and registry (`projects`) are held in module-level `BOARD` / `PROJECTS` *and* written through to SQLite at `BROKER_DB` (default `/data/broker.db`, on the `broker-data` volume); `_load_state()` rehydrates them at import. The push `QUEUES` are `asyncio.Queue`s and deliberately in-memory—in-flight pushes are lost on restart. **The module docstring still says state is in-memory; it is stale.** If you add persisted state, write through in the same pattern (`_save_*` under `_db_lock`, then load in `_load_state`).

Single-process assumptions are baked in: in-memory queues and a single SQLite connection mean the broker does not scale to replicas as written.

## Constraints that will bite you

- **Auth is subscription-based, not API-key.** `resident_agent.py` and `start_agent.sh` both *refuse to start* if `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` is set, because those shadow `CLAUDE_CODE_OAUTH_TOKEN` in the CLI's auth precedence and would silently bill the API. Don't "fix" this guard. Channels likewise do not work with API-key auth.
- **`strict_mcp_config=True` in `_make_options()` is load-bearing.** Without it, every headless resident-agent session auto-loads the project's `.mcp.json`, spawns its own `context_bridge.mjs`, and steals pushes from the real interactive session—silently. `setting_sources=["project"]` is kept so the target repo's `CLAUDE.md` still loads.
- **Resident agents run `permission_mode="bypassPermissions"`**—full tool access including Bash/Write/Edit, deliberately. `allowed_tools` does not constrain bypass mode; use `disallowed_tools` to carve out exceptions. (The README still describes agents as read-only `Read/Grep/Glob`; the code is broader.) Running as root sets `IS_SANDBOX=1` so bypass mode is permitted.
- **Anything pushed becomes instructions in front of another Claude.** `publish_context` / `notify_project` are a prompt-injection surface with no sender allowlist. This is why the broker is meant to stay on a private Docker network.
- **Networking.** Containers reach the broker by the compose *service* key `broker` (not `container_name: context-broker`), on the `hrbc1_hrbc` network, declared `external: true` so it must already exist. Changing the shared network means editing both the service's `networks:` entry and the bottom `networks:` block.
- `mcp.custom_route` is used for the non-MCP HTTP routes; older `mcp` versions lack it, in which case mount on `mcp.streamable_http_app()` instead.

## Docs

`README.md` (architecture + caveats) and `SETUP.md` (step-by-step deploy) are the user-facing docs and overlap heavily with this file—when behavior changes, they need updating too. Note `env.example` references a `docker-compose.agents.yml` that no longer exists (agents moved into the dev containers).
