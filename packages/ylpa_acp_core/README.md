# YLPA ACP Core

Foundation layer for **YLPA Console** (YL Private Agents Console): a
manifest-driven **agent-type catalog** plus a generic **ACP client**
([Agent Client Protocol](https://agentclientprotocol.com)) in pure Dart.

**One backend, every agent.** Claude Code, OpenCode, Gemini CLI, Codex CLI,
Qwen Code, Goose, Kimi CLI — anything that speaks ACP — work without a single
line of agent-specific Dart. Agent differences are *data* (JSON manifests),
never code.

```
┌──────────────────────────────────────────────────────┐
│ YLPA Console UI (Flutter, later phase)               │
│   dynamic screens rendered from manifests + caps     │
├──────────────────────────────────────────────────────┤
│ ylpa_acp_core (this package)                         │
│   AgentCatalog (bundled + user + remote manifests)   │
│   AgentInstance  (per-agent saved config)            │
│   AcpClient      (JSON-RPC 2.0 over WebSocket)       │
├──────────────────────────────────────────────────────┤
│ Machine running agents (one command sets up)         │
│   acpremote / vacp_bridge style daemon               │
│   ws://host:port/acp/ws   (bearer token)             │
│   └─ spawns any agent over stdio ACP                 │
└──────────────────────────────────────────────────────┘
```

## Layout

```
assets/agent_types/   Built-in agent-type manifests (JSON)
lib/src/manifest/     ConfigField, AgentTypeManifest, AgentInstance, AgentCatalog
lib/src/acp/          Transport, JSON-RPC framing, typed ACP models, AcpClient
test/                 Catalog tests + scripted AcpClient tests
```

## Manifest = plugin

An "agent-type plugin" is just a manifest JSON file:

- **Bundled**: `assets/agent_types/*.json` — curated, ships with the app.
- **User**: manifests placed in a user-visible directory (loaded at runtime).
  User manifests override bundled ones by `id` (higher `version` wins).
- **Remote**: a catalog URL returning `{"types": [...]}` — new agents reach
  every user without an app release. Remote entries never override bundled
  ones unless the user opts in.

Adding support for a brand-new ACP agent = dropping one JSON file. No app
update, no code, no rebuild.

Capabilities are **never** stored in manifests. They come from the agent at
runtime (`initialize` → capabilities, `session/new` → `configOptions` +
`availableCommands`). The UI renders what the agent advertises and hides what
it doesn't — fail soft, never invent features.

## Per-agent configuration without per-agent code

`AgentInstance` stores everything needed to connect to *one* agent on *one*
machine:

| Field | Meaning |
|---|---|
| `manifestId` | which agent type (drives wizard + settings forms) |
| `host` / `port` | the bridge daemon's WebSocket endpoint |
| `tokenRef` | Keystore key of the bearer token |
| `fieldValues` | answers to the manifest's non-secret fields |
| `secretRefs` | env key → Keystore key for secret fields (API keys etc.) |
| `cwd` | working directory the agent operates in |
| `extensions` | open JSON map — per-agent extras (MCP servers, providers, shared skills) so the schema can grow without migrations |

Model/provider selection is dynamic: ACP returns each session's
`configOptions` (category `model`), applied with `session/set_config_option`.
MCP servers, connectors and shared skills ride in `extensions` and, once ACP
exposes them, in per-session config options — still no per-agent code.

## What this package does NOT do (by design, for now)

- **No Flutter/UI** — the console app consumes this; widgets come later.
- **No local agent execution** — a future Termux-like in-app runner would
  implement `AcpTransport` over stdio instead of WebSocket; nothing else
  changes (transports are pluggable).
- **No code plugins** — manifest plugins today. If we later need *code*
  plugins (custom renderers, protocol tweaks), the seam is
  `AcpTransport` + the client's update-handler hooks.

## Run tests

```sh
dart pub get
dart test
```

Pure Dart — no Flutter SDK needed.
