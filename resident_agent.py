"""
Resident Agent
==============
A headless Claude (via the Claude Agent SDK) that is the resident expert for ONE
project. It loads that project's CLAUDE.md + repo and answers questions about it
on POST /ask. On startup it registers itself with the broker so other projects
can reach it through the broker's `ask_project` tool.

One of these runs per project, INSIDE that project's existing dev container,
in the background alongside the interactive Claude Code session. The repo and
the Claude CLI are already there, so there's nothing extra to mount.

Requirements (already present in a dev container that runs Claude Code; install
the Python deps if missing):
    pip install claude-agent-sdk aiohttp httpx

Auth: this runs on a Claude subscription (Pro/Max/Team/Enterprise), NOT an API
key. Once, on a machine with a browser, generate a long-lived token:
    claude setup-token                       # prints a sk-ant-oat01-... token
then set it as CLAUDE_CODE_OAUTH_TOKEN wherever this runs. Do NOT also set
ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN -- they take precedence and would
silently bill the API instead of your subscription.

Run (use ./start_agent.sh, or directly):
    export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
    unset  ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    PROJECT_NAME=payments \
    PROJECT_REPO=/workspace \
    BROKER_URL=http://broker:8000 \
    python resident_agent.py

SELF_ENDPOINT defaults to http://<this-container-hostname>:$PORT, which other
containers on the network can resolve. Override it if your dev container is
reachable under a different name/alias.
"""

from __future__ import annotations

import asyncio
import os
import socket
from urllib.parse import urlsplit

import httpx
from aiohttp import web
from claude_agent_sdk import ClaudeAgentOptions, query

PROJECT_NAME = os.environ["PROJECT_NAME"]
PROJECT_REPO = os.environ.get("PROJECT_REPO", os.getcwd())
BROKER_URL = os.environ.get("BROKER_URL", "http://broker:8000")
# PORT is what we bind; SELF_ENDPOINT is what other containers dial. They have
# to agree unless a port mapping sits between them, so whichever one you set
# fills in the other: name a port in SELF_ENDPOINT and we bind it, set PORT
# alone and we advertise it. Setting both to different ports stays legal -- a
# published container port is exactly that -- but is announced, since the
# far more common cause is a typo in one of the two.
#
# Inside the dev container, other containers reach us at this container's
# hostname. Override SELF_ENDPOINT if your dev container uses a different alias.
SELF_ENDPOINT = os.environ.get("SELF_ENDPOINT")
_advertised_port = urlsplit(SELF_ENDPOINT).port if SELF_ENDPOINT else None

if os.environ.get("PORT"):
    LISTEN_PORT = int(os.environ["PORT"])
elif _advertised_port:
    LISTEN_PORT = _advertised_port
else:
    LISTEN_PORT = 9100

if not SELF_ENDPOINT:
    SELF_ENDPOINT = f"http://{socket.gethostname()}:{LISTEN_PORT}"
elif _advertised_port and _advertised_port != LISTEN_PORT:
    print(
        f"[warn] advertising port {_advertised_port} in SELF_ENDPOINT but "
        f"binding {LISTEN_PORT} from PORT -- correct only if something "
        f"forwards {_advertised_port} to {LISTEN_PORT}; otherwise ask_project "
        f"will time out.",
        flush=True,
    )

# --- Auth guard ------------------------------------------------------------ #
# The SDK drives the Claude CLI, which picks auth in this order: cloud creds >
# ANTHROPIC_AUTH_TOKEN > ANTHROPIC_API_KEY > apiKeyHelper > CLAUDE_CODE_OAUTH_TOKEN.
# So if an API key is present it SHADOWS the subscription token and you'd be
# billing the API without noticing. Refuse to start in that case.
if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"):
    raise SystemExit(
        "ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN is set and would shadow your "
        "subscription token. Unset it so CLAUDE_CODE_OAUTH_TOKEN is used."
    )
if not os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
    print(
        "[warn] CLAUDE_CODE_OAUTH_TOKEN is not set; the SDK will fail unless the "
        "Claude CLI is already logged in (run `claude setup-token` and export it)."
    )

# bypassPermissions (like `claude --dangerously-skip-permissions`) refuses to
# run as root unless the CLI believes it's sandboxed. Dev containers commonly
# run as root, so when we are root we set IS_SANDBOX=1 here — baked into startup
# so it survives restarts no matter how the agent is launched (start_agent.sh,
# directly, or `docker exec -d`), without depending on agent.env being sourced.
# setdefault means an explicit IS_SANDBOX in the environment still wins.
if hasattr(os, "geteuid") and os.geteuid() == 0:
    os.environ.setdefault("IS_SANDBOX", "1")
    print(
        "[info] running as root — set IS_SANDBOX=1 so bypassPermissions works "
        f"(IS_SANDBOX={os.environ['IS_SANDBOX']})."
    )

SYSTEM_PROMPT = (
    f"You are the resident expert and operator for the '{PROJECT_NAME}' project. "
    "You can read its files and run commands inside its dev container to answer "
    "questions about the code, environment, dependencies, and runtime. "
    "Be concise and concrete: name files, symbols, endpoints, and contracts. "
    "When asked to run a command, run it and return its exact stdout/stderr "
    "verbatim rather than paraphrasing. If something is outside this project, "
    "say so plainly."
)


def _make_options() -> ClaudeAgentOptions:
    return ClaudeAgentOptions(
        cwd=PROJECT_REPO,
        setting_sources=["project"],          # load CLAUDE.md + .claude/ config
        # Do NOT inherit the project's .mcp.json servers. That file declares the
        # `context-bridge` stdio server, whose context_bridge.mjs unconditionally
        # long-polls the broker's single-consumer /bridge/next/<project> queue.
        # A headless resident session has no channel capability, so any push it
        # wins is silently dropped — starving the interactive session that the
        # message was meant for. strict_mcp_config ignores .mcp.json; with the
        # default empty mcp_servers below, this session loads no MCP servers at
        # all (the resident agent doesn't need them — it only reads/runs locally).
        strict_mcp_config=True,
        # Full access, no prompts: approves every tool, including Bash/Write/Edit.
        # (allowed_tools does NOT constrain bypassPermissions, so it's omitted.)
        # To carve out exceptions later, use disallowed_tools — it still applies
        # in bypass mode (e.g. disallowed_tools=["Bash(rm *)"]).
        permission_mode="bypassPermissions",
        system_prompt=SYSTEM_PROMPT,
        max_turns=12,
    )


async def _final_text(stream) -> str:
    final = ""
    async for message in stream:
        # The terminal ResultMessage carries the final text in .result
        if hasattr(message, "result") and getattr(message, "result"):
            final = message.result
    return final or "(no answer produced)"


async def answer_oneshot(question: str) -> str:
    """Stateless single turn — no memory of prior calls."""
    return await _final_text(query(prompt=question, options=_make_options()))


# --- multi-turn conversations ---------------------------------------------- #
# Keyed by conversation_id. The caller (another project) keeps sending turns
# with the same id; the agent remembers context across them and can run commands
# each turn, until the caller ends the conversation. A per-conversation lock
# serializes turns so two requests can't interleave on one client.
CONVERSATIONS: dict[str, dict] = {}
MAX_CONVERSATIONS = 50


async def converse(conversation_id: str, message: str) -> str:
    conv = CONVERSATIONS.get(conversation_id)
    if conv is None:
        # Evict the oldest if we're at capacity (dicts preserve insertion order).
        if len(CONVERSATIONS) >= MAX_CONVERSATIONS:
            old_id = next(iter(CONVERSATIONS))
            await end_conversation(old_id)
        from claude_agent_sdk import ClaudeSDKClient
        client = ClaudeSDKClient(options=_make_options())
        await client.connect()
        conv = {"client": client, "lock": asyncio.Lock()}
        CONVERSATIONS[conversation_id] = conv
    async with conv["lock"]:
        await conv["client"].query(message)
        return await _final_text(conv["client"].receive_response())


async def end_conversation(conversation_id: str) -> None:
    conv = CONVERSATIONS.pop(conversation_id, None)
    if conv:
        try:
            await conv["client"].disconnect()
        except Exception:  # noqa: BLE001
            pass


async def handle_ask(request: web.Request) -> web.Response:
    body = await request.json()
    cid = body.get("conversation_id")
    # Close an existing conversation.
    if body.get("end") and cid:
        await end_conversation(cid)
        return web.json_response({"answer": "(conversation closed)", "conversation_id": cid})
    q = (body.get("question") or "").strip()
    if not q:
        return web.json_response({"error": "missing 'question'"}, status=400)
    # With a conversation_id -> stateful multi-turn; without -> one-shot.
    answer = await converse(cid, q) if cid else await answer_oneshot(q)
    return web.json_response({"answer": answer, "conversation_id": cid})


async def handle_health(_: web.Request) -> web.Response:
    return web.json_response({"ok": True, "project": PROJECT_NAME})


async def register(_: web.Application) -> None:
    """Tell the broker we exist (and where to reach us)."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            await client.post(
                f"{BROKER_URL}/internal/register",
                json={
                    "name": PROJECT_NAME,
                    "endpoint": SELF_ENDPOINT,
                    "description": f"Resident agent for {PROJECT_NAME}",
                },
            )
        print(f"[ok] registered '{PROJECT_NAME}' with broker at {BROKER_URL}")
    except Exception as e:  # noqa: BLE001
        print(f"[warn] could not register with broker: {e!r}")


def main() -> None:
    app = web.Application()
    app.add_routes(
        [
            web.post("/ask", handle_ask),
            web.get("/health", handle_health),
        ]
    )
    app.on_startup.append(register)
    web.run_app(app, host="0.0.0.0", port=LISTEN_PORT)


if __name__ == "__main__":
    main()