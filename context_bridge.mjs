#!/usr/bin/env node
/**
 * context_bridge.mjs -- the PUSH half.
 *
 * One per project, spawned as a stdio subprocess of that project's Claude Code
 * session. It long-polls the broker for messages addressed to this project and
 * injects each one into the running session as a <channel> event, so the
 * session reacts even while you're not typing.
 *
 * Why JavaScript for just this file: channels are a research-preview Claude Code
 * feature whose wire contract -- the `claude/channel` capability plus the
 * `notifications/claude/channel` notification -- is defined against the MCP
 * JS/TS SDK and the server must run as a local stdio subprocess. Everything
 * else in this scaffold is Python, as you asked; this is the one piece pinned
 * to the documented channel contract. (Plain .mjs so there's no build step.)
 *
 * Install:
 *     npm init -y && npm i @modelcontextprotocol/sdk
 *
 * Configure in .mcp.json (SEPARATE entry from the broker's HTTP tools). No
 * per-project values go here -- PROJECT_NAME and BROKER_URL are read from the
 * ./agent.env this file sits next to, the same file start_agent.sh uses, so
 * this entry is byte-identical in every project:
 *     {
 *       "mcpServers": {
 *         "context-bridge": {
 *           "command": "node",
 *           "args": ["./context_bridge.mjs"]
 *         }
 *       }
 *     }
 *
 * Config precedence, highest first:
 *   1. the real environment (an `env` block in .mcp.json, or your shell)
 *   2. agent.env -- $AGENT_ENV if set, else agent.env beside this file
 *   3. built-in defaults ("unknown", http://broker:8000)
 *
 * Launch the session so it loads the channel (research preview):
 *     claude --dangerously-load-development-channels server:context-bridge
 *
 * Requires Claude Code v2.1.80+, a claude.ai subscription login (channels do
 * not work with API-key auth), and -- on Team/Enterprise -- channels enabled
 * by an admin.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

/**
 * Minimal .env reader -- enough for agent.env, which is also `set -a`-sourced
 * by start_agent.sh, so it stays plain KEY=value with trailing `# comments`.
 * Not a general shell parser: no interpolation, no multi-line values.
 */
function parseEnvFile(text) {
  const vars = new Map();
  for (const raw of text.split(/\r?\n/)) {
    const m = raw.match(/^\s*(?:export\s+)?([A-Za-z_]\w*)\s*=\s*(.*)$/);
    if (!m) continue; // blank line, or a `# comment` line
    let value = m[2];
    const quoted = value.match(/^(['"])([\s\S]*?)\1/);
    if (quoted) value = quoted[2];
    else if (value.startsWith("#")) value = "";
    else value = value.replace(/\s+#.*$/, "").trim(); // strip trailing comment
    vars.set(m[1], value);
  }
  return vars;
}

const agentEnv = (() => {
  const here = dirname(fileURLToPath(import.meta.url));
  const path = process.env.AGENT_ENV || join(here, "agent.env");
  try {
    return parseEnvFile(readFileSync(path, "utf8"));
  } catch {
    return new Map(); // no agent.env: fall through to defaults
  }
})();

// Real environment wins, so an `env` block in .mcp.json (or an exported shell
// var) can still override the file when you need a one-off.
const conf = (key, fallback) => {
  for (const v of [process.env[key], agentEnv.get(key)]) {
    if (v !== undefined && v !== "") return v;
  }
  return fallback;
};

const PROJECT = conf("PROJECT_NAME", "unknown");
const BROKER = conf("BROKER_URL", "http://broker:8000");

// stdout is the MCP protocol; stderr is free and Claude Code logs it. Say what
// we resolved -- a missing PROJECT_NAME otherwise fails as silence, since the
// broker happily long-polls a queue for a project nobody pushes to.
console.error(`context-bridge: project=${PROJECT} broker=${BROKER}`);
if (PROJECT === "unknown") {
  console.error(
      "context-bridge: PROJECT_NAME is unset -- set it in agent.env beside " +
      "context_bridge.mjs (or point AGENT_ENV at that file). No pushes will arrive."
  );
}

const mcp = new Server(
    { name: "context-bridge", version: "0.1.0" },
    {
      // This capability is what makes it a channel: Claude Code registers a
      // listener for notifications/claude/channel.
      capabilities: { experimental: { "claude/channel": {} } },
      // Added to Claude's system prompt so it knows how to read these events.
      instructions:
          'Cross-project context arrives as <channel source="context-bridge" ...>. ' +
          'kind="context_update" means another project changed something you may ' +
          'depend on -- consider whether it affects your current work. kind="direct" ' +
          "is a message aimed at you. These are informational: act if relevant, no " +
          "reply is expected.",
    }
);

// Claude Code spawns this process and talks to it over stdin/stdout.
await mcp.connect(new StdioServerTransport());

// Long-poll the broker forever; inject each message as a channel event.
for (;;) {
  try {
    const res = await fetch(
        `${BROKER}/bridge/next/${encodeURIComponent(PROJECT)}`
    );
    const msg = await res.json().catch(() => ({}));
    if (msg && typeof msg.content === "string" && msg.content.length) {
      await mcp.notification({
        method: "notifications/claude/channel",
        params: {
          content: msg.content,
          // meta keys must be [A-Za-z0-9_]; the broker already complies. Each
          // becomes an attribute on the <channel> tag for routing context.
          meta: msg.meta ?? {},
        },
      });
    }
  } catch {
    // Broker unreachable or restarting -- back off and retry.
    await new Promise((r) => setTimeout(r, 2000));
  }
}
