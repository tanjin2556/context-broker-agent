#!/usr/bin/env bash
# start_agent.sh -- run the resident agent INSIDE this project's dev container,
# in the background, alongside your interactive Claude Code session.
#
#   ./start_agent.sh           # start
#   ./start_agent.sh stop      # stop
#   ./start_agent.sh status    # check
#
# Config comes from ./agent.env if present, else the environment. Copy
# agent.env.example -> agent.env and fill it in.
set -euo pipefail
cd "$(dirname "$0")"

[ -f ./agent.env ] && set -a && . ./agent.env && set +a

PIDFILE=.agent/agent.pid
LOG=.agent/agent.log
mkdir -p .agent

case "${1:-start}" in
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE" \
      && echo "stopped" || echo "not running"
    exit 0 ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "running (pid $(cat "$PIDFILE")); logs: $LOG"
    else
      echo "not running"
    fi
    exit 0 ;;
esac

# --- required config -------------------------------------------------------- #
: "${PROJECT_NAME:?set PROJECT_NAME (e.g. in agent.env)}"
: "${PROJECT_REPO:=$(pwd)}"
: "${BROKER_URL:=http://broker:8000}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN (run: claude setup-token)}"
# SELF_ENDPOINT is optional; defaults to this container's hostname:9100.

# An API key would shadow the subscription token -- refuse to start.
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  echo "ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN is set; unset it so the subscription token is used." >&2
  exit 1
fi

# Already running?
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "already running (pid $(cat "$PIDFILE")); ./start_agent.sh stop first."
  exit 0
fi

# claude-agent-sdk requires Python 3.10+. The system python3 may be older
# (e.g. Amazon Linux ships 3.9), so pick a new-enough interpreter. Override
# with AGENT_PYTHON in agent.env if you have a specific one in mind.
#
# A version check alone isn't enough: some distro python3 packages (e.g.
# Debian's) ship WITHOUT venv/ensurepip, so they'd pass the version test and
# then fail at `python -m venv` / `-m pip` ("No module named pip"). So we also
# require that `venv` and `ensurepip` import. pyenv installs (common in dev
# containers) are included as candidates so we don't fall back to a broken
# system python3.
pick_python() {
  pyenvs=$(ls -d "${PYENV_ROOT:-/opt/pyenv}"/versions/*/bin/python3 \
                 "${HOME:-/root}"/.pyenv/versions/*/bin/python3 2>/dev/null | sort -rV)
  for cand in "${AGENT_PYTHON:-}" python3.13 python3.12 python3.11 python3.10 $pyenvs python3; do
    [ -n "$cand" ] || continue
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      echo "$cand"; return 0
    fi
  done
  return 1
}
PY="$(pick_python)" || {
  echo "No suitable Python found (need 3.10+ with venv + pip support)." >&2
  echo "Install one (e.g. 'apt-get install -y python3-venv' or 'dnf install -y python3.11'), or set AGENT_PYTHON in agent.env." >&2
  exit 1
}

# Use an isolated venv so deps don't touch system site-packages.
VENV=.agent/venv
[ -x "$VENV/bin/python" ] || "$PY" -m venv "$VENV"
VPY="$VENV/bin/python"

# Install Python deps once (idempotent, quiet).
"$VPY" -m pip install --quiet --disable-pip-version-check claude-agent-sdk aiohttp httpx

export PROJECT_NAME PROJECT_REPO BROKER_URL CLAUDE_CODE_OAUTH_TOKEN
[ -n "${SELF_ENDPOINT:-}" ] && export SELF_ENDPOINT

nohup "$VPY" resident_agent.py > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
sleep 1
echo "resident agent for '$PROJECT_NAME' started (pid $(cat "$PIDFILE")); logs: $LOG"
