# Resident agent + context bridge — setup for this project

These files were installed into this project by `install.sh`. They connect this
project's Claude Code session to a **context broker** shared with your other
projects, so sessions that each have their own context window can exchange
context instead of you copy-pasting between them.

**This is only half the system.** These files are the client side. They need a
**broker** already running and reachable from this container — one broker, shared
by all your projects. If nobody has stood one up yet, that comes first:

> https://github.com/tanjin2556/context-broker-agent — see `SETUP.md`

Without a reachable broker the agent starts, fails to register, and nothing
arrives; the session works normally but the cross-project tools do nothing.

## What got installed

| File | What it is |
|---|---|
| `resident_agent.py` | headless Claude that answers questions about *this* repo on `POST /ask` |
| `start_agent.sh` | starts/stops it in the background; makes its own venv in `.agent/` |
| `agent.env` | your config — **holds an OAuth token, never commit it** |
| `agent.env.example` | the template, for reference |
| `context_bridge.mjs` | relays pushed messages into your live session as `<channel>` events |
| `.mcp.json` | two MCP entries were merged in; anything else already there was left alone |

`.mcp.json.bak` is your previous `.mcp.json`, if you had one.

These sit in the **project root** on purpose, and moving them apart breaks
things quietly: `start_agent.sh` resolves paths relative to itself and defaults
`PROJECT_REPO` to its own directory, `context_bridge.mjs` looks for `agent.env`
beside itself (override with `AGENT_ENV`), and Claude Code only reads `.mcp.json`
from the directory you launch it in. If you installed into the wrong place,
re-run the installer with `--dir <project-root>` and delete the stray copies.

## What it did to your git repo

Nothing, to the repository itself. The installer runs exactly one git command —
`git rev-parse --git-dir`, a read-only check for whether this is a repo at all.
Your branch, HEAD, commit history, staged index, remotes and reflog are all
untouched; it never runs `add`, `commit`, `checkout`, `init` or `push`.

What it *does* leave is working-tree changes you can review before committing:

- **the installed files, untracked** — `resident_agent.py`, `start_agent.sh`,
  `agent.env.example`, `context_bridge.mjs`, `AGENT_SETUP.md`, `.mcp.json`.
  They show up in `git status` for you to commit, or not. Committing them is
  reasonable if your team shares the setup; the only file that must *never* be
  committed is `agent.env`.
- **three lines appended to `.gitignore`** — `agent.env`, `.agent/` and
  `.mcp.json.bak`. This is the only tracked file the installer modifies, and the
  reason is `agent.env` holds a long-lived OAuth token. Entries are added
  individually and skipped if already present, so re-running never duplicates
  them. Pass `--no-gitignore` to skip this entirely — but then ignore
  `agent.env` yourself before you commit anything.

`git diff` and `git status` show you all of it. Nothing is staged.

## Setup

### 0. Check the broker is actually reachable

Do this first, **from inside this container** — not from the host. Everything
below is wasted effort if it fails:

```bash
curl -s http://broker:8000/healthz     # {"ok":true,"projects":N,"notes":N}
```

If it hangs or refuses, this container isn't on the broker's Docker network.
From the host:

```bash
docker network connect hrbc1_hrbc <this-container-name>
```

Better, add the network to this container's compose file so it survives a
rebuild. Note `broker` is the compose *service* key — `container_name` does not
create a DNS name, and with plain `docker run` you need `--network-alias broker`.

If your broker is somewhere else, whatever host and port you `curl` successfully
must match `BROKER_URL` in `agent.env` **and** the `context` URL in `.mcp.json`.
Re-running the installer with `--broker <url>` sets both together.

### 1. Get a subscription token

**Once per machine**, somewhere with a browser:

```bash
claude setup-token          # prints sk-ant-oat01-...
```

This runs on a Claude subscription (Pro/Max/Team/Enterprise), **not** an API key.

### 2. Fill in `agent.env`

```bash
PROJECT_NAME=payments                 # how other projects address this one
PROJECT_REPO=/workspace               # path to this repo INSIDE this container
BROKER_URL=http://broker:8000         # the broker's service name on the shared network
IS_SANDBOX=1                          # only if this container runs as root
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
```

`PROJECT_NAME` must be unique across your projects — it is the address other
sessions push to. Both halves read this one file, so you set it here only.

`SELF_ENDPOINT` is optional. It defaults to this container's hostname on port
9100, which is right as long as other containers can resolve that hostname. If
they can't, set it to this container's service or alias name on the shared
network (e.g. `http://hrbc1-payments:9100`).

### 3. Start the resident agent

```bash
./start_agent.sh              # background; logs to .agent/agent.log
./start_agent.sh status       # running? which pid?
./start_agent.sh stop
```

First run builds a venv at `.agent/venv` and installs `claude-agent-sdk`,
`aiohttp`, `httpx` — it needs Python 3.10+ with `venv` and `pip` available. If
the system `python3` is older or is missing `venv`, set `AGENT_PYTHON` in
`agent.env` to a specific interpreter.

On startup it registers itself with the broker. Check right here, the same way
you did in step 0 — `projects` should have gone up by one, and `PROJECT_NAME`
should be listed:

```bash
curl -s http://broker:8000/healthz
```

If the count didn't move, read `.agent/agent.log`; registration failing is the
agent's first action, so the reason is at the top.

### 4. Install the bridge dependency

`install.sh` already did this, unless you passed `--no-npm` or had no `npm` on
PATH — it says which. To do it by hand, or to check:

```bash
npm i --no-save @modelcontextprotocol/sdk
```

`--no-save` populates `node_modules/` and nothing else: no `package.json` is
created if the project has none, and an existing one is not rewritten.

`context_bridge.mjs` needs this. It is launched automatically by Claude Code via
the `.mcp.json` entry — you never run it yourself. Without it the bridge exits
immediately and the session reports only `context-bridge (CONNECTION_CLOSED)`.

### 5. Launch your session with the push channel

```bash
claude --dangerously-load-development-channels server:context-bridge
```

Channels are a research-preview feature: Claude Code v2.1.80+, subscription
login (they do not work with API-key auth), and on Team/Enterprise an admin has
to enable them. Without this flag the pull tools still work; only push is off.

## Checking it works

`/mcp` inside the session should list **context** (connected) and
**context-bridge**. Then:

```
> get_shared_context
> publish_context with a note, and see whether the other project's session
  renders a <channel source="context-bridge"> event
```

The bridge prints its resolved config to stderr at startup, which Claude Code
captures in the MCP server logs:

```
context-bridge: project=payments broker=http://broker:8000
```

## What this actually does

Three paths, and it helps to keep them apart:

- **Pull** — you call the broker's MCP tools (`get_shared_context`,
  `publish_context`, `ask_project`, …) over HTTP. Normal tool calls.
- **Push** — another project publishes something; the broker queues it;
  `context_bridge.mjs` long-polls and injects it into your running session as a
  `<channel>` event, so your session reacts without you typing.
- **Ask** — another project's session asks *your* resident agent a question. The
  broker POSTs `/ask` on port 9100 here, and `resident_agent.py` answers with
  full knowledge of this repo.

Two things to be aware of before you wire this into a real project:

- **The resident agent runs with `permission_mode="bypassPermissions"`** — full
  tool access to this repo including Bash, Write and Edit. It is not read-only.
  Use `disallowed_tools` in `resident_agent.py` to carve out exceptions;
  `allowed_tools` does not constrain bypass mode.
- **Anything pushed to you becomes instructions in front of your Claude.** There
  is no sender allowlist. Keep the broker on a private Docker network and only
  connect projects you control.

## Troubleshooting

**`project=unknown` in the bridge log** — no `PROJECT_NAME` was found. The
bridge looks at the real environment first, then `$AGENT_ENV`, then `agent.env`
sitting beside `context_bridge.mjs`. If you moved the files apart, set
`AGENT_ENV` to the full path. Left unfixed this fails as *silence*: the bridge
happily long-polls a queue nobody pushes to.

**Agent refuses to start: "ANTHROPIC_API_KEY is set"** — working as intended. An
API key takes precedence over `CLAUDE_CODE_OAUTH_TOKEN` in the CLI's auth order,
so it would silently bill the API instead of your subscription. `unset
ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN` rather than removing the guard.

**Bypass mode refused because you're root** — set `IS_SANDBOX=1` in `agent.env`.

**`ask_project` times out** — the broker can't reach this container at
`SELF_ENDPOINT`. Check what got registered (`/healthz` on the broker) and
confirm both containers are on the same network; set `SELF_ENDPOINT` explicitly
if the hostname isn't resolvable from the broker.

**Nothing in `/mcp`** — Claude Code reads `.mcp.json` from the directory you
launched it in. Start the session from this project's root.

**Pushes go missing intermittently** — something else is draining your queue.
Each message is delivered once, so two bridges for the same `PROJECT_NAME` will
steal from each other. Check for a stray `./start_agent.sh` from another repo
using the same name, or a second session open on the same project.

**The broker restarted and queued messages vanished** — expected. The board and
registry are persisted to SQLite; in-flight pushes are in-memory only.

## Removing it

```bash
./start_agent.sh stop
rm -rf .agent
rm resident_agent.py start_agent.sh agent.env agent.env.example context_bridge.mjs AGENT_SETUP.md
mv .mcp.json.bak .mcp.json     # or delete the two entries by hand
```
