"""
Context Broker
==============
A shared MCP server that lets isolated Claude Code sessions -- each in its own
dev container, each with its own context window -- share context across a Docker
network.

It has two surfaces:

  1. MCP tools (streamable-HTTP). This is what each project's Claude Code session
     calls. Exposed on 0.0.0.0 so every container on the network can reach it.

  2. A small *bridge* HTTP API (plain HTTP, NOT MCP) used by:
       - the per-session channel bridges, which long-poll it for pushed messages
       - the resident agents, which register themselves on startup

Run:
    pip install "mcp[cli]" httpx uvicorn
    python broker.py                      # serves on 0.0.0.0:8000, MCP at /mcp

Each project registers the broker in .mcp.json (project scope) so its session
can call the tools:
    {
      "mcpServers": {
        "context": { "type": "http", "url": "http://broker:8000/mcp" }
      }
    }

NOTE: state here is in-memory. For anything beyond a demo, back BOARD / PROJECTS
with SQLite or Redis so it survives a restart and can be shared across replicas.
"""

from __future__ import annotations

import asyncio
import json
import os
import sqlite3
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

mcp = FastMCP("context-broker", host="0.0.0.0", port=8000)

# --------------------------------------------------------------------------- #
# State                                                                       #
#   - board + registry are persisted to SQLite (survive restarts)            #
#   - queues are in-memory only (in-flight pushes are transient by nature)    #
# Set BROKER_DB=:memory: to run without persistence.                          #
# --------------------------------------------------------------------------- #

DB_PATH = os.environ.get("BROKER_DB", "/data/broker.db")
_db_lock = threading.Lock()
_db = sqlite3.connect(DB_PATH, check_same_thread=False)
_db.execute("PRAGMA journal_mode=WAL")
_db.executescript(
    """
    CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY, project TEXT, summary TEXT, tags TEXT, ts REAL
    );
    CREATE TABLE IF NOT EXISTS projects (
        name TEXT PRIMARY KEY, endpoint TEXT, description TEXT, last_seen REAL
    );
    """
)
_db.commit()


@dataclass
class Project:
    name: str
    endpoint: str                      # resident agent base URL, e.g. http://payments-agent:9100
    description: str = ""
    last_seen: float = field(default_factory=time.time)


@dataclass
class Note:
    id: str
    project: str
    summary: str
    tags: list[str]
    ts: float


PROJECTS: dict[str, Project] = {}
BOARD: list[Note] = []
QUEUES: dict[str, asyncio.Queue] = {}   # project -> messages waiting for its channel bridge


def _save_project(p: Project) -> None:
    with _db_lock:
        _db.execute(
            "INSERT INTO projects(name, endpoint, description, last_seen) "
            "VALUES(?,?,?,?) ON CONFLICT(name) DO UPDATE SET "
            "endpoint=excluded.endpoint, description=excluded.description, "
            "last_seen=excluded.last_seen",
            (p.name, p.endpoint, p.description, p.last_seen),
        )
        _db.commit()


def _save_note(n: Note) -> None:
    with _db_lock:
        _db.execute(
            "INSERT OR REPLACE INTO notes(id, project, summary, tags, ts) VALUES(?,?,?,?,?)",
            (n.id, n.project, n.summary, json.dumps(n.tags), n.ts),
        )
        _db.commit()


def _load_state() -> None:
    for name, endpoint, desc, last_seen in _db.execute(
        "SELECT name, endpoint, description, last_seen FROM projects"
    ):
        PROJECTS[name] = Project(name, endpoint, desc, last_seen)
    for id_, project, summary, tags, ts in _db.execute(
        "SELECT id, project, summary, tags, ts FROM notes ORDER BY ts"
    ):
        BOARD.append(Note(id_, project, summary, json.loads(tags), ts))


_load_state()


def _queue(project: str) -> asyncio.Queue:
    return QUEUES.setdefault(project, asyncio.Queue())


async def _push(project: str, content: str, meta: dict[str, str]) -> None:
    """Enqueue a message for a project's running session (drained by its bridge)."""
    await _queue(project).put({"content": content, "meta": meta})


# --------------------------------------------------------------------------- #
# MCP tools -- called by the Claude Code sessions                             #
# --------------------------------------------------------------------------- #

@mcp.tool()
def list_projects() -> list[dict[str, str]]:
    """List the projects currently registered with the broker."""
    return [{"name": p.name, "description": p.description} for p in PROJECTS.values()]


@mcp.tool()
def register_project(name: str, endpoint: str, description: str = "") -> str:
    """Register (or refresh) a project and the URL of its resident agent.

    Usually the resident agent calls this for itself on startup, but a session
    can call it too.
    """
    p = Project(name=name, endpoint=endpoint, description=description)
    PROJECTS[name] = p
    _save_project(p)
    _queue(name)
    return f"registered {name}"


@mcp.tool()
async def publish_context(project: str, summary: str, tags: list[str] | None = None) -> str:
    """Publish a short context note to the shared board AND notify other projects.

    Use this when you've made a change or decision other projects depend on
    (an API contract change, a new shared schema, a deprecation). Keep `summary`
    tight -- one or two sentences. Every other project's running session gets a
    push so it can react.
    """
    note = Note(
        id=uuid.uuid4().hex[:8],
        project=project,
        summary=summary,
        tags=tags or [],
        ts=time.time(),
    )
    BOARD.append(note)
    _save_note(note)
    for other in PROJECTS:
        if other != project:
            await _push(
                other,
                f"{project} published context: {summary}",
                {"kind": "context_update", "source": project},
            )
    return f"published note {note.id}"


@mcp.tool()
def get_shared_context(
    topic: str | None = None,
    project: str | None = None,
    limit: int = 20,
) -> list[dict[str, Any]]:
    """Read recent notes from the shared board, newest first.

    Optionally filter by `project` or a case-insensitive `topic` substring
    (matched against the summary and tags).
    """
    items = list(reversed(BOARD))
    if project:
        items = [n for n in items if n.project == project]
    if topic:
        t = topic.lower()
        items = [
            n for n in items
            if t in n.summary.lower() or any(t in tag.lower() for tag in n.tags)
        ]
    return [asdict(n) for n in items[:limit]]


@mcp.tool()
async def ask_project(project: str, request: str, conversation_id: str | None = None) -> dict:
    """Send a request to another project's resident agent and get its reply back.

    This is the SYNCHRONOUS request/response path (not the push channel). The
    agent runs INSIDE that project's dev container with full tool access, so
    `request` can be either a question about the code OR an instruction to run
    commands. Examples:
      - "run `printenv COMPANY_ID` and return the exact stdout, verbatim"
      - "run the unit tests and report pass/fail with the summary line"
      - "how does this service sign webhooks?"

    Multi-turn: to go back and forth until a task is done, pass the SAME
    conversation_id on every call — the agent keeps its context across turns.
    Omit it on the first call; the returned conversation_id is the thread to
    continue. Keep calling with that id (refining, asking follow-ups, reacting
    to output) until you're satisfied, then call end_project_conversation.

    Returns {"conversation_id", "reply"}.
    """
    p = PROJECTS.get(project)
    if not p:
        known = ", ".join(PROJECTS) or "(none registered)"
        return {"conversation_id": conversation_id, "reply": f"unknown project '{project}'. Known: {known}"}
    cid = conversation_id or uuid.uuid4().hex[:12]
    try:
        async with httpx.AsyncClient(timeout=300) as client:
            r = await client.post(
                f"{p.endpoint.rstrip('/')}/ask",
                json={"question": request, "conversation_id": cid},
            )
            r.raise_for_status()
            return {"conversation_id": cid, "reply": r.json().get("answer", "(empty answer)")}
    except Exception as e:  # noqa: BLE001 -- surface the failure to the caller
        return {"conversation_id": cid, "reply": f"failed to reach {project}'s resident agent: {e!r}"}


@mcp.tool()
async def end_project_conversation(project: str, conversation_id: str) -> str:
    """Close a multi-turn ask_project conversation and free the agent session."""
    p = PROJECTS.get(project)
    if not p:
        return f"unknown project '{project}'"
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            await client.post(
                f"{p.endpoint.rstrip('/')}/ask",
                json={"conversation_id": conversation_id, "end": True},
            )
        return f"closed conversation {conversation_id} with {project}"
    except Exception as e:  # noqa: BLE001
        return f"failed to close conversation: {e!r}"


@mcp.tool()
async def notify_project(project: str, message: str) -> str:
    """Push a one-off message into another project's running session.

    Delivered through that project's channel bridge as a <channel> event, so the
    other session reacts even though nobody typed anything in its terminal.
    """
    if project not in PROJECTS:
        return f"unknown project '{project}'"
    await _push(project, message, {"kind": "direct", "from": "broker"})
    return f"queued message for {project}"


# --------------------------------------------------------------------------- #
# Bridge HTTP API -- called by channel bridges + resident agents, NOT Claude  #
# --------------------------------------------------------------------------- #
# These attach to the same Starlette app FastMCP serves. If your `mcp` version
# lacks `custom_route`, mount them on `mcp.streamable_http_app()` instead.

@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_: Request) -> JSONResponse:
    """Liveness probe (the /mcp endpoint speaks MCP, so don't curl that)."""
    return JSONResponse({"ok": True, "projects": len(PROJECTS), "notes": len(BOARD)})


@mcp.custom_route("/internal/register", methods=["POST"])
async def http_register(request: Request) -> JSONResponse:
    body = await request.json()
    register_project(body["name"], body["endpoint"], body.get("description", ""))
    return JSONResponse({"ok": True})


@mcp.custom_route("/bridge/next/{project}", methods=["GET"])
async def bridge_next(request: Request) -> JSONResponse:
    """Long-poll: block up to ~25s for the next pushed message for `project`.

    Returns {"content": ..., "meta": ...} when there's a message, or {} on
    timeout (the bridge simply re-polls).
    """
    project = request.path_params["project"]
    q = _queue(project)
    try:
        msg = await asyncio.wait_for(q.get(), timeout=25)
        return JSONResponse(msg)
    except asyncio.TimeoutError:
        return JSONResponse({})


if __name__ == "__main__":
    # MCP is served at http://<host>:8000/mcp ; bridge API at the same origin.
    mcp.run(transport="streamable-http")
