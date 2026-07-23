# AdaptiveAgent Desktop

A restrained macOS 14+ SwiftUI vertical slice for the local AdaptiveAgent runtime. The app supervises a bundled `agent-runtime` process and communicates exclusively over protocol `1.10` using JSON-RPC 2.0 NDJSON on stdin/stdout. Filesystem access, agent loading, tools, providers, and Postgres runtime semantics remain in the runtime process.

## Requirements

- macOS 14 or newer and Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A local Postgres instance and valid `DATABASE_URL` when settings explicitly select the Postgres runtime
- A protocol `1.10` standalone `agent-runtime` executable

## Install the runtime bridge

For a tagged GitHub release (the release publishes versioned `adaptive-agent-runtime-<tag>-darwin-<arch>.tar.gz` artifacts and checksums):

```sh
Scripts/fetch-runtime-release.sh v1.2.3
```

For a locally built executable:

```sh
Scripts/install-local-runtime.sh /absolute/path/to/agent-runtime
```

Both install to `Resources/AgentRuntime/agent-runtime`, which is copied into the app bundle and intentionally gitignored.

## Generate, build, and test

```sh
xcodegen generate
xcodebuild -project AdaptiveAgentDesktop.xcodeproj -scheme AdaptiveAgentDesktop build
xcodebuild -project AdaptiveAgentDesktop.xcodeproj -scheme AdaptiveAgentDesktop test
```

Open `AdaptiveAgentDesktop.xcodeproj` in Xcode to run. Signing defaults to local ad-hoc signing; no Developer ID or development team is configured.

During development, you can skip copying the executable into resources by setting `ADAPTIVE_AGENT_RUNTIME_PATH` in the Xcode scheme to an absolute locally compiled `agent-runtime` path.

In **Product > Scheme > Edit Scheme > Run > Arguments > Environment Variables**, set `DATABASE_URL` when using Postgres. Provider API keys required by the selected profile must be set there as environment variables as well. The app inherits these values into the child process. It never writes them to `UserDefaults`, files, command payloads, stdout, or the UI. Do not place secrets in the agent/settings JSON.

The settings override field may be left blank. During initialization the runtime discovers settings in this order: `ADAPTIVE_AGENT_SETTINGS`, `<workspace>/agent.settings.json`, then `~/.adaptiveAgent/agent.settings.json`. Entering a path in the field takes precedence over those locations. The settings file can select initialization behavior such as the runtime mode:

```json
{
  "version": 1,
  "runtime": {
    "mode": "memory"
  }
}
```

Choose a workspace directory and agent profile JSON, connect, and then start a run or send a session chat message. The event pane receives incremental `agent/event` notifications. Run results expose approval and clarification controls when requested, plus steer, inspect, resume, retry, and interrupt controls.

## Architecture and security boundary

- `RuntimeClient` owns `Process`, separate stdin/stdout/stderr pipes, partial/multiple-line stdout buffering, JSON-RPC request correlation, and clean shutdown.
- Startup requires a JSON-RPC `runtime/ready` notification, protocol `1.10` negotiation with `initialize`, and then a separate `runtime/initialize` before agent operations.
- `AppModel` is main-actor isolated and translates UI actions into typed JSON-RPC methods. Runtime initialization leaves runtime mode, provider, and model resolution to `agent.settings.json` unless an RPC override is explicitly added.
- The Swift renderer does not read workspace/profile contents and has no cloud behavior. Native file panels select paths only; the runtime process performs all runtime and filesystem behavior.
- Runtime stderr is captured separately and displayed as diagnostic event entries; it is never parsed as protocol traffic.

This development slice inherits the complete app process environment. Production distribution should narrow inherited variables and add an explicit secret-management design without moving runtime behavior into the renderer.
