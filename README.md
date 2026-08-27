# Cross-project context for Claude Code sessions

Three small processes that let isolated Claude Code sessions (one per dev
container, each with its own context window) share context over your Docker
network.

```
                         ┌─────────────────────────────────────┐
                         │            broker  (HTTP)            │
                         │  MCP tools:  list_projects           │
   project A session ───▶│               publish_context        │
   (.mcp.json -> /mcp)   │               get_shared_context     │
                         │               ask_project ───────────┼──┐
   project B session ───▶│               notify_project         │  │  POST /ask
                         │  bridge API: /bridge/next/{proj}      │  │
                         │              /internal/register       │  ▼
                         └───────▲──────────────▲────────────────┘  resident agents
                                 │ long-poll    │ register          (Agent SDK, 1/project,
            context_bridge.mjs ──┘              └── resident_agent.py   knows that repo)
            (stdio subprocess,
             1 per session)
```

- **`broker.py`** — central hub. Exposes the **pull** tools every session calls
  (over streamable-HTTP MCP at `/mcp`) and a small plain-HTTP API the bridges
  and agents use.
- **`resident_agent.py`** — one per project. A headless Claude Agent SDK
  "consultant" that knows that project's repo + `CLAUDE.md` and answers
  questions about it. `ask_project` routes here.
- **`context_bridge.mjs`** — one per session. The **push** half. A `claude/channel`
  stdio subprocess that long-polls the broker and injects messages into the
  running session as `<channel>` events.

## Why two MCP registrations per project

The broker and the bridge are different transports and serve different roles:

| Piece            | Transport            | Role  | `.mcp.json` form |
|------------------|----------------------|-------|------------------|
| broker tools     | remote HTTP          | pull  | `{"type":"http","url":"http://broker:8000/mcp"}` |
| context bridge   | local stdio subprocess | push | `{"command":"node","args":["./context_bridge.mjs"]}` |

A channel **must** be a local stdio subprocess of the session — it can't be the
remote broker. The bridge is the local relay that connects the session to the
broker.

### Each project's `.mcp.json`

```json
{
  "mcpServers": {
    "context": {
      "type": "http",
      "url": "http://broker:8000/mcp"
    },
    "context-bridge": {
      "command": "node",
      "args": ["./context_bridge.mjs"]
    }
  }
}
```

This file is identical in every project — nothing per-project is hardcoded in
it. `context_bridge.mjs` reads `PROJECT_NAME` and `BROKER_URL` from the
`agent.env` it sits next to, the same file `start_agent.sh` uses, so the two
halves can't drift apart. Precedence is: real environment (an `env` block here,
or an exported shell var) > `agent.env` (`$AGENT_ENV` if set, else the one
beside `context_bridge.mjs`) > defaults. The bridge logs the project and broker
it resolved to stderr on startup, and warns loudly if `PROJECT_NAME` is missing
— otherwise that failure looks exactly like "nobody pushed anything".

Then start that project's session so it loads the channel:

```bash
claude --dangerously-load-development-channels server:context-bridge
```

## Running

### Broker

The broker is published on Docker Hub as
[`ahmedtanjin/agent-context-broker`](https://hub.docker.com/r/ahmedtanjin/agent-context-broker)
(`linux/amd64`). You don't need this repo to run it — the image is
self-contained, so anyone can pull and start it.

However you start it, three things matter:

- it must join the **same Docker network** as your project dev containers;
- those containers must reach it as the hostname **`broker`** on port 8000 —
  that's the URL baked into every `.mcp.json` (`http://broker:8000/mcp`);
- mount a volume at **`/data`** if the board and project registry should survive
  a restart (`BROKER_DB` defaults to `/data/broker.db`; set it to `:memory:` for
  no persistence).

Check liveness with `GET /healthz` — never curl `/mcp`, which speaks MCP and
will look broken to a plain HTTP client.

#### From Docker Hub, with Docker Compose

Save this as `docker-compose.yml` anywhere (no clone needed) and run
`docker compose up -d`:

```yaml
services:
  broker:                              # the service key IS the DNS name; keep it "broker"
    image: ahmedtanjin/agent-context-broker:latest
    container_name: context-broker
    restart: unless-stopped
    environment:
      BROKER_DB: /data/broker.db       # ":memory:" to run with no persistence
    ports:
      - "8000:8000"                    # only if something on the HOST must reach it
    volumes:
      - broker-data:/data
    networks:
      - shared
    healthcheck:
      test: ["CMD", "python", "-c", "import sys,urllib.request; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz', timeout=2).status==200 else 1)"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 5s

volumes:
  broker-data:

networks:
  shared:
    external: true
    name: my-dev-network               # the network your project containers already use
```

```bash
docker compose pull && docker compose up -d
docker compose ps                       # expect "healthy"
curl http://localhost:8000/healthz      # {"ok":true,"projects":0,"notes":0}
```

`external: true` means the network must already exist — usually the one your dev
containers are on (`docker network ls` to find it). If you don't have one yet:

```bash
docker network create claude-context    # then set  name: claude-context  above
```

#### From Docker Hub, without Compose

```bash
docker network create claude-context          # or reuse an existing network
docker volume create broker-data

docker run -d \
  --name context-broker \
  --restart unless-stopped \
  --network claude-context \
  --network-alias broker \
  -e BROKER_DB=/data/broker.db \
  -p 8000:8000 \
  -v broker-data:/data \
  ahmedtanjin/agent-context-broker:latest
```

`--network-alias broker` is what makes `http://broker:8000` resolve; with
`--name context-broker` alone the container answers to `context-broker` instead,
and every `.mcp.json` would have to be rewritten.

Attach each project's dev container to the same network, then verify from inside
it that the name resolves:

```bash
docker network connect claude-context my-project-dev
docker exec my-project-dev curl -s http://broker:8000/healthz
# {"ok":true,"projects":0,"notes":0}
```

Tags: `latest` and `0.1.0` (currently the same build). Pin `:0.1.0` rather than
`latest` if you don't want a redeploy to move underneath you, or pin the exact
build by digest — `ahmedtanjin/agent-context-broker@sha256:<digest>`, printed by
`docker buildx imagetools inspect ahmedtanjin/agent-context-broker:latest`.

#### From this repo (build it yourself)

```bash
docker compose -f docker-compose.broker.yml up -d --build   # network: $BROKER_NETWORK, default hrbc1_hrbc
```

Or with no container at all:

```bash
pip install -r requirements.txt
python broker.py            # 0.0.0.0:8000, MCP at /mcp
```

### Resident agent (one per project, inside the dev container)

Runs inside each project's existing dev container, in the background, beside the
interactive session — no separate container or repo mount.

**The quick way** — run it from the project's root, inside its dev container.
Root matters: the installed files resolve paths relative to themselves and
Claude Code only reads `.mcp.json` from the directory you launch it in. From
anywhere else, pass `--dir <project-root>`.

```bash
curl -fsSL https://raw.githubusercontent.com/tanjin2556/context-broker-agent/main/install.sh | sh
```

Pre-fill the config while you're at it — everything but the token:

```bash
curl -fsSL https://raw.githubusercontent.com/tanjin2556/context-broker-agent/main/install.sh   | sh -s -- --name payments --broker http://broker:8000
```

`--broker` sets the URL in **both** places it is needed — the `.mcp.json` pull
entry and `BROKER_URL` in `agent.env` — so the pull and push halves can't end up
pointing at different brokers.

That drops in `resident_agent.py`, `start_agent.sh`, `agent.env`,
`context_bridge.mjs` and an `AGENT_SETUP.md` walkthrough, and merges the two
entries into the project's `.mcp.json` — preserving any MCP servers already
registered there, and backing the file up first. It installs nothing globally
and starts nothing; re-running it never overwrites your `agent.env` or files
you've edited (`--force` if you want that).

It leaves the target project's git repository alone — no `add`, `commit`,
`checkout` or `init`, and history, index, remotes and branch are untouched. The
installed files land untracked for you to review, and the one tracked file it
modifies is `.gitignore`, to add `agent.env` (which holds an OAuth token),
`.agent/` and `.mcp.json.bak`. `--no-gitignore` skips even that.
`./install.sh --help` for options.

**By hand**, if you'd rather:

```bash
# one-time, on a machine with a browser: mint a ~1-year subscription token
claude setup-token                     # prints sk-ant-oat01-...; copy it

# in each project's dev container, with resident_agent.py + start_agent.sh present:
cp agent.env.example agent.env         # set PROJECT_NAME, PROJECT_REPO, token
./start_agent.sh                       # background; logs in .agent/agent.log
```

`start_agent.sh` installs the Python deps (`claude-agent-sdk aiohttp httpx`) on
first run, refuses to start if `ANTHROPIC_API_KEY` is set (it would shadow the
subscription token), and registers the agent with the broker. `SELF_ENDPOINT`
defaults to the dev container's hostname:9100.

### Bridge (per session, inside the project container)

```bash
npm i --no-save @modelcontextprotocol/sdk   # install.sh does this for you
# launched automatically by Claude Code via the .mcp.json entry above,
# and configured from the same agent.env the resident agent uses
```

No `npm init` needed: `--no-save` only populates `node_modules/`, so a project
without a `package.json` stays without one.

### What runs where

```
broker container ........ ahmedtanjin/agent-context-broker (compose or docker run)
project dev container A .. resident agent (./start_agent.sh) + interactive session + bridge
project dev container B .. resident agent (./start_agent.sh) + interactive session + bridge
...                        all on the hrbc1_hrbc network
```

Only the broker is a container you deploy; everything else lives inside the dev
containers you already run.

## Try it

With two projects registered and both sessions running:

- In project A's session: *"ask the payments project how it signs webhook
  payloads"* → `ask_project` → A gets a synthesized answer without loading B's code.
- In project A's session: *"publish that the auth header is now X-Sig-v2"* →
  `publish_context` → B's running session receives a `<channel>` event about it.

## Caveats

- **Channels are research preview.** Need Claude Code v2.1.80+, the
  `--dangerously-load-development-channels` flag for a custom channel, and a
  **claude.ai subscription login** for the interactive sessions (channels don't
  work with API-key auth). On Team/Enterprise, an admin must enable channels.
- **Resident agents run on the subscription too.** Authenticate with a
  `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` and keep `ANTHROPIC_API_KEY`
  out of those containers — it takes precedence and would silently bill the API.
- **One subscription, one shared quota.** Every resident agent and every
  interactive session draws on the same plan's quota and rate limits, so a burst
  of concurrent `ask_project` calls can hit your limit. The OAuth token is
  licensed for *individual* use through Claude Code / the Agent SDK; routing a
  whole team's traffic through one person's token isn't what it's for and can run
  into Anthropic's terms. For shared or higher-throughput use, point the resident
  agents at an API key (or Bedrock/Vertex) instead.
- **Persistence.** The broker keeps the board and project registry in SQLite at
  `BROKER_DB` (default `/data/broker.db`); mount a volume there (the compose file
  does) and they survive restarts. The push **queues** stay in memory — in-flight
  pushes are transient, so a few can be lost on a restart. Set `BROKER_DB=:memory:`
  to disable persistence entirely.
- **Anything pushed becomes instructions in front of Claude.** A `<channel>`
  event is read by the receiving session as input — treat the broker as a
  prompt-injection surface. Keep it on the private `hrbc1_hrbc` network only; if you ever
  expose it, add a sender allowlist before `publish_context` / `notify_project`
  can enqueue.
- **Resident agents have full tool access.** They run
  `permission_mode="bypassPermissions"`, so `Bash`, `Write` and `Edit` are on the
  table — an `ask_project` question can change files in the target repo, not just
  read them. `allowed_tools` does *not* constrain bypass mode; the lever that
  still applies is `disallowed_tools` (e.g. `disallowed_tools=["Bash(rm *)"]` in
  `_make_options()`). Running as root sets `IS_SANDBOX=1` so bypass mode is
  permitted at all.
- **`custom_route`**: if your installed `mcp` version doesn't have it, mount the
  two bridge routes on `mcp.streamable_http_app()` instead.
