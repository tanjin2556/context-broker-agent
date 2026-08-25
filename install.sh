#!/usr/bin/env sh
# install.sh -- drop the resident-agent + push-bridge files into a project.
#
# Run this INSIDE a project's dev container, from that project's root:
#
#     curl -fsSL https://raw.githubusercontent.com/tanjin2556/context-broker-agent/main/install.sh | sh
#
# or, from a clone of this repo:
#
#     ./install.sh --dir /path/to/project
#
# It installs four runtime files plus a setup guide, and merges two entries into
# the project's .mcp.json without disturbing MCP servers already registered
# there. It does NOT start anything, install npm/pip packages, or touch your
# credentials -- read AGENT_SETUP.md afterwards for the manual steps.
#
# Re-running is safe: an existing agent.env is never overwritten, files you have
# edited are kept unless --force, and .mcp.json is backed up before it is edited.

set -eu

REPO="${CONTEXT_BROKER_REPO:-tanjin2556/context-broker-agent}"
REF="${CONTEXT_BROKER_REF:-main}"
DIR="."
FORCE=0
DO_MCP=1
DO_GITIGNORE=1

# Files fetched into the project. AGENT_SETUP.md is the per-project guide.
FILES="resident_agent.py start_agent.sh agent.env.example context_bridge.mjs AGENT_SETUP.md"

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

  --dir DIR          project root to install into (default: current directory)
  --repo OWNER/REPO  source repo to download from
  --ref REF          branch, tag, or commit to download (default: main)
  --force            overwrite files that already exist and differ
  --no-mcp           do not touch .mcp.json
  --no-gitignore     do not add anything to the project's .gitignore
  -h, --help         show this help

Environment: CONTEXT_BROKER_REPO and CONTEXT_BROKER_REF are honoured as defaults.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR="${2:?--dir needs a path}"; shift 2 ;;
    --repo)    REPO="${2:?--repo needs OWNER/REPO}"; shift 2 ;;
    --ref)     REF="${2:?--ref needs a git ref}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    --no-mcp)  DO_MCP=0; shift ;;
    --no-gitignore) DO_GITIGNORE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install.sh: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$DIR" ] || die "no such directory: $DIR"
DIR=$(cd "$DIR" && pwd)

# --- where do the files come from? ------------------------------------------ #
# If install.sh sits in a clone next to the other files, copy them: that makes
# the script testable and lets you install from a checkout with no network.
# Otherwise download from the repo.
SRC=""
case "$0" in
  */*)
    candidate=$(cd "${0%/*}" 2>/dev/null && pwd) || candidate=""
    if [ -n "$candidate" ] && [ -f "$candidate/resident_agent.py" ]; then
      SRC="$candidate"
    fi
    ;;
esac

TMP=$(mktemp -d) || die "could not create a temp directory"
trap 'rm -rf "$TMP"' EXIT INT TERM

if [ -n "$SRC" ]; then
  say "Installing from local checkout: $SRC"
  for f in $FILES; do
    [ -f "$SRC/$f" ] || die "missing from checkout: $f"
    cp "$SRC/$f" "$TMP/$f"
  done
else
  case "$REPO" in
    */*/*|/*|*/) die "--repo wants OWNER/REPO, got: $REPO" ;;
    */*) : ;;
    *)   die "--repo wants OWNER/REPO, got: $REPO" ;;
  esac
  BASE="https://raw.githubusercontent.com/$REPO/$REF"
  say "Downloading from $REPO@$REF"
  if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
  elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
  else
    die "need curl or wget to download; or run install.sh from a clone"
  fi
  for f in $FILES; do
    fetch "$BASE/$f" "$TMP/$f" || die "could not fetch $f from $BASE (check --repo/--ref)"
    [ -s "$TMP/$f" ] || die "downloaded an empty $f from $BASE"
  done
fi

# --- install ---------------------------------------------------------------- #
installed=""
skipped=""
for f in $FILES; do
  dest="$DIR/$f"
  if [ -e "$dest" ] && [ "$FORCE" -eq 0 ] && ! cmp -s "$TMP/$f" "$dest"; then
    warn "$f already exists and differs -- keeping yours (use --force to replace)"
    skipped="$skipped $f"
    continue
  fi
  cp "$TMP/$f" "$dest"
  installed="$installed $f"
done
chmod +x "$DIR/start_agent.sh" 2>/dev/null || true

# agent.env holds a long-lived OAuth token: create it once, never clobber it.
if [ -f "$DIR/agent.env" ]; then
  say "Keeping your existing agent.env (not overwritten)."
else
  cp "$DIR/agent.env.example" "$DIR/agent.env"
  say "Created agent.env from the example -- edit it before starting the agent."
fi

# That token must never reach a commit. This is the only tracked file we touch,
# and the only reason we look at git at all -- rev-parse is a read-only probe.
# Entries are checked one at a time so a project installed before an entry
# existed still picks it up, and so we never duplicate what's already there.
if [ "$DO_GITIGNORE" -eq 1 ] && git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  added=""
  for entry in 'agent.env' '.agent/' '.mcp.json.bak'; do
    grep -qxF "$entry" "$DIR/.gitignore" 2>/dev/null && continue
    if [ -z "$added" ] && [ -s "$DIR/.gitignore" ]; then
      printf '\n# context-broker resident agent (agent.env holds an OAuth token)\n' >> "$DIR/.gitignore"
    elif [ -z "$added" ]; then
      printf '# context-broker resident agent (agent.env holds an OAuth token)\n' >> "$DIR/.gitignore"
    fi
    printf '%s\n' "$entry" >> "$DIR/.gitignore"
    added="$added $entry"
  done
  [ -n "$added" ] && say "Added to .gitignore:$added"
  # Belt and braces: if agent.env is somehow still not ignored, say so loudly.
  if ! git -C "$DIR" check-ignore -q agent.env 2>/dev/null; then
    warn "agent.env is NOT ignored by git -- it holds an OAuth token. Fix before committing."
  fi
fi

# --- .mcp.json -------------------------------------------------------------- #
# Merge rather than replace: the project may already register other MCP servers.
MERGE_PY='
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict):
        raise ValueError("top level is not an object")
except FileNotFoundError:
    doc = {}
except Exception as exc:
    sys.exit("error: could not parse %s: %s\n       fix or move it, then re-run install.sh" % (path, exc))
servers = doc.setdefault("mcpServers", {})
if not isinstance(servers, dict):
    sys.exit("error: %s has a non-object mcpServers; fix it and re-run" % path)
servers["context"] = {"type": "http", "url": "http://broker:8000/mcp"}
servers["context-bridge"] = {"command": "node", "args": ["./context_bridge.mjs"]}
with open(path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
kept = [k for k in servers if k not in ("context", "context-bridge")]
print("Wrote .mcp.json (context, context-bridge)" + ("; left alone: " + ", ".join(kept) if kept else ""))
'

MERGE_JS='
const fs = require("fs"), p = process.argv[1];
let doc = {};
if (fs.existsSync(p)) {
  try { doc = JSON.parse(fs.readFileSync(p, "utf8")); }
  catch (e) { console.error("error: could not parse " + p + ": " + e.message); process.exit(1); }
}
if (typeof doc !== "object" || doc === null || Array.isArray(doc)) {
  console.error("error: top level of " + p + " is not an object"); process.exit(1);
}
if (!doc.mcpServers || typeof doc.mcpServers !== "object") doc.mcpServers = {};
doc.mcpServers["context"] = { type: "http", url: "http://broker:8000/mcp" };
doc.mcpServers["context-bridge"] = { command: "node", args: ["./context_bridge.mjs"] };
fs.writeFileSync(p, JSON.stringify(doc, null, 2) + "\n");
const kept = Object.keys(doc.mcpServers).filter(k => k !== "context" && k !== "context-bridge");
console.log("Wrote .mcp.json (context, context-bridge)" + (kept.length ? "; left alone: " + kept.join(", ") : ""));
'

MCP_OK=1
if [ "$DO_MCP" -eq 1 ]; then
  target="$DIR/.mcp.json"
  [ -f "$target" ] && cp "$target" "$target.bak" && say "Backed up your .mcp.json to .mcp.json.bak"
  # A broken .mcp.json is the user's to fix -- report it, but don't abort and
  # leave them without the rest of the summary. The files are already in place.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "$MERGE_PY" "$target" || MCP_OK=0
  elif command -v python >/dev/null 2>&1; then
    python -c "$MERGE_PY" "$target" || MCP_OK=0
  elif command -v node >/dev/null 2>&1; then
    node -e "$MERGE_JS" "$target" || MCP_OK=0
  else
    warn "no python3 or node found -- skipping .mcp.json"
    MCP_OK=0
  fi
fi

# --- report ----------------------------------------------------------------- #
say ""
say "Installed into $DIR:"
for f in $installed; do say "  + $f"; done
for f in $skipped;  do say "  . $f (kept yours)"; done
say ""
if [ "$MCP_OK" -eq 0 ]; then
  say "!! .mcp.json was NOT updated. Add these two entries under \"mcpServers\" by hand:"
  say '     "context": { "type": "http", "url": "http://broker:8000/mcp" },'
  say '     "context-bridge": { "command": "node", "args": ["./context_bridge.mjs"] }'
  say ""
fi
say "Still needed, and NOT installed by this script:"
command -v node    >/dev/null 2>&1 || say "  ! node is missing -- the push bridge needs it"
command -v python3 >/dev/null 2>&1 || say "  ! python3 is missing -- the resident agent needs 3.10+"
[ -d "$DIR/node_modules/@modelcontextprotocol/sdk" ] \
  || say "  - npm i @modelcontextprotocol/sdk     (once, for context_bridge.mjs)"
say "  - a CLAUDE_CODE_OAUTH_TOKEN in agent.env  (run: claude setup-token)"
say ""
say "Next: 1) edit agent.env   2) ./start_agent.sh   3) relaunch your session with"
say "      claude --dangerously-load-development-channels server:context-bridge"
say ""
say "Full walkthrough and troubleshooting: $DIR/AGENT_SETUP.md"
