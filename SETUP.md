# Setup — step by step

Assumes 2+ projects, each already in its own dev container on a shared Docker
network. Replace `payments` with each real project name as you go.

## 0. Prerequisites (once)

- Docker + Docker Compose on the host.
- A Claude subscription (Pro/Max/Team/Enterprise).
- Claude Code CLI on a machine **with a browser**, for the one-time login:
  ```bash
  npm i -g @anthropic-ai/claude-code
  ```

## 1. Get the broker

The broker is published on Docker Hub as `ahmedtanjin/agent-context-broker`
(`linux/amd64`). Pick one:

- **A — pull the image (recommended).** Nothing to copy onto the host; go
  straight to step 2. You still need `resident_agent.py`, `start_agent.sh`,
  `agent.env.example` and `context_bridge.mjs` for steps 5–6 — but those get
  copied into your *project* containers, not the broker host.
- **B — build from source.** In a folder on the host, place `broker.py`,
  `Dockerfile`, `requirements.txt`, `.dockerignore`, `docker-compose.broker.yml`.

## 2. Mint a subscription token (once)

On the machine with a browser:
```bash
claude setup-token          # opens browser, prints sk-ant-oat01-...
```
Copy the token. You'll reuse it for every resident agent.

## 3. Start the broker

Whichever route you take, the same three things have to hold: the broker joins
the **same Docker network** as your project dev containers, those containers
reach it as the hostname **`broker`** on port 8000, and a volume is mounted at
**`/data`** so the board and registry survive a restart.

### A — from Docker Hub, with Compose

Save this as `docker-compose.yml` in any folder, then `docker compose up -d`:

```yaml
services:
  broker:                          # the service key IS the DNS name — keep it "broker"
    image: ahmedtanjin/agent-context-broker:latest
    container_name: context-broker
    restart: unless-stopped
    environment:
      BROKER_DB: /data/broker.db
    ports:
      - "8000:8000"                # only if the HOST must reach it
    volumes:
      - broker-data:/data
    networks:
      - shared

volumes:
  broker-data:

networks:
  shared:
    external: true
    name: hrbc1_hrbc               # your existing shared network
```

`external: true` means that network must already exist — `hrbc1_hrbc` does once
the `hrbc1` stack has been started. Substitute your own name if it differs
(`docker network ls` to check).

### B — from Docker Hub, no Compose

```bash
docker volume create broker-data

docker run -d \
  --name context-broker \
  --restart unless-stopped \
  --network hrbc1_hrbc \
  --network-alias broker \
  -e BROKER_DB=/data/broker.db \
  -p 8000:8000 \
  -v broker-data:/data \
  ahmedtanjin/agent-context-broker:latest
```

`--network-alias broker` is what makes `http://broker:8000` resolve inside other
containers; `--name` alone would only give you `context-broker`, and every
`.mcp.json` in step 6 would have to be rewritten.

### C — build from source (option B in step 1)

```bash
docker compose -f docker-compose.broker.yml up -d --build
```
That compose file is already set to join your existing `hrbc1_hrbc` network
(declared `external: true`), so the broker lands on the same bridge as your
project containers. Override with `BROKER_NETWORK=<name>`, or change both the
service's `networks:` entry and the `networks:` block to match.

## 4. Verify the broker

```bash
docker compose ps                                     # should be "healthy"
# built from source instead:  docker compose -f docker-compose.broker.yml ps
# started with docker run:    docker ps --filter name=context-broker
curl http://localhost:8000/healthz                    # {"ok": true, ...}
```
From another container on the network:
```bash
docker exec my-project-dev curl -s http://broker:8000/healthz
```
If that container isn't on the shared network yet:
`docker network connect hrbc1_hrbc my-project-dev`.

Health-check `/healthz` only — `/mcp` speaks MCP and will look broken to curl.

## 5. Run a resident agent inside each project's dev container

The agent runs *inside* the project's existing dev container, in the background,
next to your interactive session — the repo and Claude CLI are already there, so
there's nothing to build or mount.

**Shortcut for steps 5 and 6:** from the project's root inside its dev
container, `curl -fsSL https://raw.githubusercontent.com/tanjin2556/context-broker-agent/main/install.sh | sh`
copies in every file below, writes the `.mcp.json` from step 6, and leaves an
`AGENT_SETUP.md` in the project. You still do `claude setup-token`, fill in
`agent.env`, and run `./start_agent.sh` yourself. The rest of this section is
what that script automates — read on if you'd rather do it by hand.

In each project's dev container, copy in `resident_agent.py`, `start_agent.sh`,
and `agent.env.example`, then (the `agent.env` you create here also configures
the push bridge in step 6, so put it where `context_bridge.mjs` will live):

```bash
cp agent.env.example agent.env     # edit: PROJECT_NAME, PROJECT_REPO, token
chmod +x start_agent.sh
./start_agent.sh                   # starts in background; logs in .agent/agent.log
```

`./start_agent.sh status` / `stop` manage it. The agent registers with the
broker on startup. Confirm from the broker host:
```bash
curl http://localhost:8000/healthz     # "projects" count should go up by one
```

Notes:
- `SELF_ENDPOINT` defaults to this container's hostname on port 9100. Only set it
  in `agent.env` if other containers can't reach this dev container by that
  hostname (use its service/alias name on `hrbc1_hrbc`, e.g. `http://hrbc1-payments:9100`).
- To start it automatically with the container, add to `devcontainer.json`:
  `"postStartCommand": "./start_agent.sh"` (with the token available in the
  container's environment).

## 6. Register the broker + bridge in each project's `.mcp.json`

Drop `context_bridge.mjs` into the project **next to the `agent.env` from step
5**, then `npm i --no-save @modelcontextprotocol/sdk` (`install.sh` does both
for you). Add both entries — this JSON is the
same in every project, nothing in it is per-project:
```json
{
  "mcpServers": {
    "context": { "type": "http", "url": "http://broker:8000/mcp" },
    "context-bridge": {
      "command": "node",
      "args": ["./context_bridge.mjs"]
    }
  }
}
```

The bridge reads `PROJECT_NAME` and `BROKER_URL` from `agent.env` itself, so
step 5 configures both halves and there's nothing to keep in sync here. It
looks for `$AGENT_ENV` if set, otherwise `agent.env` beside `context_bridge.mjs`
— if you keep them in different directories, set `AGENT_ENV` (or fall back to an
explicit `"env": {...}` block, which takes precedence over the file).

Check it resolved correctly — the bridge logs this to stderr at startup, and
Claude Code captures it:
```
context-bridge: project=payments broker=http://broker:8000
```
`project=unknown` means it found no `PROJECT_NAME`; the bridge will long-poll a
queue nobody pushes to, which looks identical to "no messages yet".

## 7. Launch each session with the push channel enabled

In the project container, make sure Claude Code is logged in to your
subscription (`claude` then `/login`, or reuse the token), then:
```bash
claude --dangerously-load-development-channels server:context-bridge
```
(Channels are research preview and need Claude Code v2.1.80+; on Team/Enterprise
an admin must enable them.)

## 8. Smoke test

With two projects up and both sessions running:

- In project A's session: *"use the context tools to ask the payments project
  how it signs webhooks"* → pulls an answer via `ask_project`, no code copied.
- In project A's session: *"publish context that the auth header is now
  X-Sig-v2"* → project B's running session receives a `<channel>` event about it.

---

### Repeat per project
Steps 5–7 are per project (one resident agent + one `.mcp.json` + one launch
flag each). Step 8 is just to confirm it all talks.

### Common gotchas
- `http://broker:8000` must resolve — the broker must be on the **same network**
  and answer to the name `broker` there: that's the **service key** under Compose,
  or `--network-alias broker` with plain `docker run`. `container_name` doesn't
  do it.
- If a resident agent exits immediately, `ANTHROPIC_API_KEY` is probably set in
  that container — unset it (the agent guards against this on purpose).
- Persistence lives on the `broker-data` volume; `docker compose ... down -v`
  (or `docker volume rm broker-data`) wipes the board and registry.
