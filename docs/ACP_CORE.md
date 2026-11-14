# YLPA ACP Core — architecture and integration

This document describes the **ACP layer** added to this repository for YLPA
Console: how it coexists with the existing Hermes Dashboard client (zero UI
loss), and how the app will grow to drive *any* ACP-compatible agent —
Claude Code, OpenCode, Gemini CLI, Codex CLI, Qwen Code, Goose, Kimi CLI, or
a user-defined custom agent — with agent differences stored as **data**
(JSON manifests), never code.

Related: [`packages/ylpa_acp_core/README.md`](../packages/ylpa_acp_core/README.md)
(the package itself) and the upstream protocol at
[agentclientprotocol.com](https://agentclientprotocol.com).

## Status

Integrated as a local path package; **not yet wired into any screen**. The
existing Hermes UI and all its specs are untouched. This doc is the plan.

## Layout inside this repo

```
packages/ylpa_acp_core/        Pure Dart package (no Flutter dependency)
  lib/src/manifest/            ConfigField, AgentTypeManifest, AgentInstance,
                               AgentCatalog (bundled + user dir + remote URL)
  lib/src/acp/                 AcpTransport (WebSocket), JSON-RPC 2.0 framing,
                               typed models, generic AcpClient
  assets/agent_types/*.json    Built-in agent-type manifests (source of truth)
  test/                        Catalog + scripted-client tests
assets/agent_types/*.json      Copy bundled into the app (declared in pubspec).
                               Keep in sync with the package copy.
```

`pubspec.yaml` gains one dependency: `ylpa_acp_core: {path: packages/ylpa_acp_core}`
plus one assets entry: `assets/agent_types/`.

## Why ACP, and how it fits

The app is today a **Hermes Dashboard client** (`ConnectionManager`,
`TuiGatewayClient`, ~65k lines of chat path — deeply Hermes-shaped; see
[`UPSTREAM_CONTRACT.md`](UPSTREAM_CONTRACT.md)). Supporting other agents
through that stack would be a major rewrite. ACP changes the economics:

- **One protocol, many agents.** All of the agents above speak ACP as agents;
  Claude Code via the `claude-agent-acp` adapter, Codex via `codex-acp`,
  OpenCode natively. Even Hermes Agent itself has an ACP mode.
- **The app stays a thin client.** Agents run on the user's machine behind a
  small bridge daemon (e.g. `acpremote serve-command`, WebSocket + bearer
  token at `ws://host:port/acp/ws`). No embedding, no phone-side CLI.
- **Everything dynamic is discovered, not hardcoded.** `initialize` returns
  capabilities; `session/new` returns `configOptions` (models, modes) and
  `availableCommands` (slash commands). The UI renders what the agent
  advertises and hides the rest — the same *fail soft, never invent
  endpoints* principle already codified in `UPSTREAM_CONTRACT.md`.

## The three building blocks

### 1. Agent-type manifest (the "plugin" unit)

A JSON file describes everything that differs between agents:

- `bridge.serveCommand` — the one-paste command to run on the machine
- `auth` — env-var fields (API keys) or OAuth note; secrets go to the
  Keystore via `AgentInstance.secretRefs`, never into persistence or logs
- `spawnOptions` — wizard fields (cwd, default model, …)
- `links`, `extras` — docs and an open extension map (MCP servers, provider
  presets, shared skills) that persists verbatim

Plugin sources, merged in order (later wins only if allowed):

1. **Bundled** — `assets/agent_types/*.json`
2. **User directory** — manifests written by the in-app custom editor
3. **Remote catalog** — a URL returning `{"types": [...]}`; additive-only by
   default, so new agents can ship without an app release and cannot silently
   override built-ins

### 2. AgentInstance (a saved connection to one agent on one machine)

`manifestId` + host/port/token ref + field answers + `extensions` map. JSON
round-trips verbatim; no migrations needed as the schema grows.

### 3. AcpClient (the one backend)

`initialize → session/new → prompt → stream of session/update events →
cancel`, plus agent→client requests answered by pluggable handlers
(`session/request_permission` → the app's approval UI; `fs/read_text_file` /
`fs/write_text_file` → a permissive-by-default-deny bridge). Deny-all by
default; the agent never hangs and never gains access the user did not grant.

## UI compatibility plan (same UI, no loss)

The existing app keeps running exactly as-is. The ACP layer is **additive**.
The reuse map:

| Kept as-is | Reason |
|---|---|
| `lib/core/design/`, `theme/`, `widgets/` | The visual identity the fork exists for |
| Home board, shell/dock, navigation | Generic surfaces |
| SSH terminal + SFTP screens | Manage the bridge machine — protocol-agnostic |
| Chat composer + chat block renderers | ACP updates map onto the same block types (text, reasoning, tool calls, plan, file edits) |
| All Hermes screens (profiles, rooms, cron, Petdex…) | Untouched; they simply don't appear for ACP-only connections |

New screens (later, built on the manifest + capability data, all dynamic):

1. **Add Agent wizard** — pick type from catalog grid → form rendered from
   `auth.fields` + `spawnOptions` → app composes the bridge one-liner →
   QR/deep-link handoff (mirrors the Hermes QR flow).
2. **Agent settings** — the *same generic widget* for every agent type,
   rendering manifest fields + live `configOptions`.
3. **Chat session** — `AcpSessionEvent` → existing block renderers;
   `AcpPermissionNeeded` → the approval dialog.

## Testing

From the repo root or the package folder:

```sh
cd packages/ylpa_acp_core
dart pub get
dart test
```

Pure Dart — no Flutter SDK needed. (Requires a Dart ≥3.6 SDK on PATH.)
11 scripted test cases cover the catalog merge rules and the full client
lifecycle against a fake agent.

## Future notes (deliberately not built yet)

- **Local agents in-app (Termux-like runner):** implement `AcpTransport`
  over stdio and spawn the agent on-device; nothing else changes.
- **Code plugins:** today's plugins are manifest-only. If custom renderers
  or protocol tweaks are ever needed, the seams are `AcpTransport` and the
  client's update-handler hooks — the manifest system stays untouched.
- **Skills/MCP per agent:** ride in `AgentInstance.extensions` today; move
  into per-session config options as ACP surfaces them.
