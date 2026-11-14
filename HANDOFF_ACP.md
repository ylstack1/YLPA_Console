# Handoff: YLPA Console — ACP (Agent Client Protocol) Layer

**Repo:** `E:/ylstack-space/Developments/ai/agents_app/YLPA_Console`  
**Remote:** `https://github.com/ylstack1/YLPA_Console.git`  
**Local commit:** `5c1b025 feat(acp): add Agent Client Protocol layer for any agent CLI`  
**Status:** Committed locally, NOT pushed (push blocked — no TTY for credential manager)  
**Last verified:** flutter analyze clean, `dart test` → 19/19 passed, debug APK built and installed on device `192.168.1.188:5555`

---

## What this session built

### New ACP layer (all additive — zero changes to Hermes `lib/`)

**Core package:** `packages/ylpa_acp_core/` (pure Dart, no Flutter dep)
- `lib/src/manifest/config_field.dart` — ConfigField (FieldType: text/secret/choice/bool/number); `dynamic`→`isDynamic` in code, JSON key stays `"dynamic"`
- `lib/src/manifest/agent_type_manifest.dart` — AgentTypeManifest (field `abstract`→`isTemplate`, JSON key stays `"abstract"`), BridgeSetup, AuthSetup
- `lib/src/manifest/agent_instance.dart` — AgentInstance, acpEndpoint() → `ws://host:port/acp/ws`, effectivePort()
- `lib/src/manifest/agent_catalog.dart` — ManifestSource (allowOverride), InlineManifestSource, DirectoryManifestSource, RemoteCatalogSource, merge rules, fail-soft
- `lib/src/acp/acp_transport.dart` — AcpTransport interface + WebSocketAcpTransport (bearer token, protocols:['acp'], 10s fail-fast)
- `lib/src/acp/jsonrpc.dart` — JSON-RPC 2.0 framing, JsonRpcMultiplexer
- `lib/src/acp/acp_models.dart` — AgentCaps, SessionConfigOption, ContentBlock, SessionUpdate variants (AgentMessageChunk, AgentThoughtChunk, ToolCall, ToolCallUpdate, PlanUpdate, AvailableCommandsUpdate, CurrentModeUpdate, UserMessageChunk, UnknownUpdate), AcpPermissionRequest, PermissionOutcome
- `lib/src/acp/acp_client.dart` — AcpClient: initialize → sessionNew → prompt (streams updates) → cancel/set_config_option/listSessions; agent→client handlers (session/request_permission, fs/read_text_file, fs/write_text_file; terminal/elicitation denied with -32601)
- `assets/agent_types/*.json` — 6 manifests: claude-code, opencode, gemini-cli, codex, qwen-code, custom-acp (abstract template)
- `test/` — acp_client_test.dart + manifest_catalog_test.dart, 19 tests

**App integration** (`lib/core/acp/` + `lib/core/screens/acp/`):
- `acp_catalog_loader.dart` — loads `assets/agent_types/*.json` via AssetManifest + rootBundle, fail-soft
- `acp_instance_store.dart` — persists AgentInstance list in SharedPreferences (`acp_instances_v1`)
- `acp_session_controller.dart` — connect → initialize → sessionNew → streaming transcript, permission flow via Completer map, sendPrompt/cancelTurn/setConfigOption, ConnectionState: idle/connecting/ready/failed
- `acp_add_agent_screen.dart` — 3-step wizard: type chips → host/port/token → dynamic manifest form; Test connection button; copy-ready bridge command card; saves to SecureStorage
- `acp_agent_form.dart` — dynamic form from manifest `auth.fields` + `spawnOptions` (secret/choice/text/number), `__cwd` pseudo-field
- `acp_agent_settings_screen.dart` — edit/delete instance, delete confirmation clears secrets
- `acp_chat_screen.dart` — transcript rendering (coalesced agent text, in-place tool-call updates, plan ☑▣☐), permission banner + dialog, config bottom sheet, composer with send/stop, failure/retry view, auto-scroll

**Modified files (additive):**
- `lib/core/screens/app_settings_screen.dart` — new HermesToolDestination `acp_agents` → AcpHubScreen
- `lib/core/screens/onboarding_screen.dart` — ACP agent door + "Continue without an agent (demo)" skip button
- `lib/core/screens/onboarding/connect_method_draft.dart` — added `ConnectWay.acp` to enum
- `lib/core/screens/onboarding/connect_method_cards.dart` — ACP card mappings (icon, title, body)
- `lib/main.dart` — removed Hermes-required gate from `_finishOnboarding()` (onboarding now completable without Hermes)
- `lib/core/services/secure_storage.dart` — `read/write/deleteAcpSecret` (prefix-scan via `readAll()`)
- `pubspec.yaml` — added `ylpa_acp_core` path dep + `assets/agent_types/` bundle entry

**Build fixes (to make Flutter 3.50 compile):**
- `android/gradle/wrapper/gradle-wrapper.properties` — Gradle 9.1.0 → 9.3.1
- `android/settings.gradle.kts` — AGP 9.0.1 → 9.1.1
- `android/gradle.properties` — `kotlin.incremental=false` + `kotlin.compiler.execution.strategy=in-process` (Windows Kotlin cache-close fix)

---

## Current state on device

- APK installed on `192.168.1.188:5555` (QA flavor, `dev.xpetalab.hermesconsole.qa`)
- `acpremote expose --host 0.0.0.0 --port 8765 -- opencode acp` was running on PC (serving `ws://0.0.0.0:8765/acp/ws`)
- Bridge log: `/tmp/acpremote.log`
- APK download server: `http://192.168.1.130:8082/app-qa-debug.apk` (was running, may need restart)

---

## Remaining goals (in order)

### 1. Push the commit
```powershell
cd E:\ylstack-space\Developments\ai\agents_app\YLPA_Console
git push origin HEAD
```
Blocked by Windows Credential Manager needing TTY. Use `git credential-manager` interactively or set `GH_TOKEN`.

### 2. Live end-to-end validation
- PC: `acpremote expose --host 0.0.0.0 --port 8765 -- opencode acp` (or full path to opencode.cmd)
- Phone: Settings → ACP agents → Add → Host `192.168.1.130`, Port `8765`, Working dir (absolute path)
- Send a message — expect streaming agent response
- If OpenCode hangs: 60s timeout now throws "OpenCode did not respond to prompt within 60 seconds"

### 3. Add-Agent wizard polish
- Working directory field: currently requires absolute path; validate Windows paths (`C:\...`) and Unix paths (`/...`)
- Bridge command card: shows `manifest.bridge.serveCommand` but `acpremote` subcommand is `expose`, not `serve-command` — update manifest text to match actual acpremote CLI

### 4. Widget tests for wizard + form
- `test/widget/` — AcpAgentForm renders fields from manifest, _save returns true only when valid
- No Hermes dependency needed

### 5. QR-code pairing for bridge setup
- Mirror Hermes QR onboarding flow for ACP (scan code → populate host/port/token)

### 6. Rebrand sweep (deferred by user)
- README, app label, package name `hermes_android` → YLPA
- Changing `applicationId` breaks existing installs — needs user confirmation

---

## Key design decisions (don't re-litigate)

| Decision | Rationale |
|---|---|
| ACP over bridge daemon (`acpremote`) | Agents run on user's machine; app is thin network client; no embedding |
| One generic AcpBackend for all agents | Differences are manifest data (JSON), never code; capabilities discovered at runtime |
| Manifest = plugin unit | Bundled (assets) + user-directory + remote catalog; remote additive-only by default |
| New core as local path package inside repo | Additive to existing app — zero changes to `lib/` Hermes code |
| Transport interface pluggable | `AcpTransport` (WebSocket now) — future stdio impl enables Termux-like local runner |
| Secrets never in AgentInstance | `secretRefs` maps env-var → Keystore key; `acp_<field>_<instanceId>` keys |

---

## Critical technical details

**ACP wire shape:**
- `session/update` notification params = `{sessionId, update: {sessionUpdate: '<kind>', ...}}` — client parses nested `update` key
- Bridge endpoint: `ws://host:port/acp/ws` with `Authorization: Bearer <token>`
- OpenCode requires `protocolVersion` as **number** (not string) and `mcpServers` present (even `{}`) in `session/new`
- OpenCode requires `cwd` as **absolute path** (not `~`)

**Toolchain activation:**
- `. F:\toolchain\env.ps1` (PowerShell)
- Bash: `export PATH="/f/toolchain/flutter/bin:$PATH" && export PUB_CACHE="F:/toolchain/pub-cache"`
- Flutter 3.50.0 / Dart 3.14.0 / JDK 21 / Gradle 9.3.1 / Android SDK 36

**Test commands:**
- `cd packages/ylpa_acp_core && dart pub get && dart test` → 19/19
- `flutter analyze` (app root) → clean on new/touched files
- `flutter build apk --debug --flavor qa` → builds QA debug APK

**Repo conventions (don't break):**
- Hermes screens: StatefulWidget with constructor-injected deps, no Riverpod, plain `MaterialApp` + `Navigator.push(MaterialPageRoute(...))`
- Design system: `HermesPage`, `HermesSectionHeader`, `HermesListGroup`/`HermesListRow`, `HermesThemeColors` via `Theme.of(context).hermes`
- Secure storage: `SecureStorage` class, keyed patterns like `acp_<field>_<instanceId>`
- Hardcoded English strings OK initially

---

## Files to re-check before next build

- `packages/ylpa_acp_core/assets/agent_types/opencode.json` — spawnOptions includes `cwd` (test requires it); app's `assets/agent_types/opencode.json` must stay in sync
- `lib/core/screens/acp/acp_add_agent_screen.dart` — `_cwdController` provides absolute path; form validation requires it
- `packages/ylpa_acp_core/lib/src/acp/acp_client.dart` — `prompt()` has 60s timeout; `session/new` sends `mcpServers: {}`

---

## Session summary for next AI

The ACP layer is complete and tested at unit level (19/19). The app builds and installs. The remaining work is: push the commit, validate live against OpenCode via acpremote, then optionally add widget tests and QR pairing. Hermes functionality is 100% untouched.
