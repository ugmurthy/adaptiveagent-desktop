# AdaptiveAgent Desktop

A restrained macOS 14+ SwiftUI vertical slice for the local AdaptiveAgent runtime. The app supervises a bundled `agent-runtime` process and communicates exclusively over protocol `1.17` using JSON-RPC 2.0 NDJSON on stdin/stdout. Filesystem access, agent loading, tools, providers, and Postgres runtime semantics remain in the runtime process.

## Requirements

- macOS 14 or newer and Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A local Postgres instance and valid `DATABASE_URL` when settings explicitly select the Postgres runtime
- A protocol `1.17` standalone `agent-runtime` executable

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

Persisted SQLite/Postgres run history also uses the read-only
`trace-session-sidecar` helper. Compile it from the AdaptiveAgent monorepo and
install it separately:

```sh
bun build packages/trace-session/src/trace-sidecar.ts --compile --target=bun-darwin-arm64 --outfile /tmp/trace-session-sidecar
Scripts/install-local-trace-session.sh /tmp/trace-session-sidecar
```

Use `bun-darwin-x64` on Intel Macs. The helper is installed to
`Resources/TraceSession/trace-session-sidecar` and is intentionally gitignored.

## Generate, build, and test

```sh
xcodegen generate
xcodebuild -project AdaptiveAgentDesktop.xcodeproj -scheme AdaptiveAgentDesktop build
xcodebuild -project AdaptiveAgentDesktop.xcodeproj -scheme AdaptiveAgentDesktop test
```

Open `AdaptiveAgentDesktop.xcodeproj` in Xcode to run. Signing defaults to local ad-hoc signing; no Developer ID or development team is configured.

During development, you can skip copying the executable into resources by setting `ADAPTIVE_AGENT_RUNTIME_PATH` in the Xcode scheme to an absolute locally compiled `agent-runtime` path.
Set `ADAPTIVE_AGENT_TRACE_SESSION_PATH` the same way to override the bundled
trace-session helper.

In **Product > Scheme > Edit Scheme > Run > Arguments > Environment Variables**, set `DATABASE_URL` when using Postgres. Provider API keys required by the selected profile must be set there as environment variables as well. A gateway token can be entered in the app's **Workspace Configuration > Gateway Access Token** secure field, or supplied as `ADAPTIVE_AGENT_ACCESS_TOKEN` in the same environment-variable list. Tokens entered in the app are kept only in memory and sent to the runtime with `auth/updateAccessToken`; they are never written to `UserDefaults` or configuration files. Do not place secrets in the agent/settings JSON.

The settings override field may be left blank. During initialization the runtime discovers settings in this order: `ADAPTIVE_AGENT_SETTINGS`, `<workspace>/agent.settings.json`, then `~/.adaptiveAgent/agent.settings.json`. Entering a path in the field takes precedence over those locations. When the app discovers `<workspace>/agent.settings.json` or you select a settings file, its configuration panel seeds editable runtime mode, provider, model, approval, and clarification values from that file. These non-secret values are sent explicitly to `runtime/initialize`; optional inference mode/tier controls remain unset unless you select an override, so runtime defaults stay in effect. Other settings remain runtime-managed. The settings file can select initialization behavior such as the runtime mode:

```json
{
  "version": 1,
  "runtime": {
    "mode": "memory"
  }
}
```

Choose a workspace directory and agent profile JSON, connect, and then start a run or send a session chat message. The event pane receives incremental `agent/event` notifications. Run results expose approval and clarification controls when requested, plus steering and a **Run Actions** menu with inspect, resume, retry, recover, continue, and interrupt operations.

New runs can include generic files, images, and audio when the connected runtime advertises each managed attachment kind. The app validates selected media, imports it into a private Application Support snapshot, sends only relative descriptors over JSON-RPC, and retains submitted snapshots for runtime retry and recovery. Runtime-advertised limits are enforced up to the app's maximums of 10 MiB each, 8 attachments, and 40 MiB total. Text is still required, and chat attachments are not supported.

Runs and drafts open in app-level tabs above the detail pane. Tabs retain their own draft, chat composer, steering text, selected run, and scroll position while sharing the app's single runtime process. Closing a tab does not interrupt or remove its run; select that run in the history sidebar to reopen it. Background tabs continue showing run status and approval or clarification badges.

When no run is selected, use the **Existing Run** field on the new-request screen to enter a run ID and invoke the same actions. The app attaches that ID as a tracked sidebar record so status changes, inspection output, and errors remain visible in the normal run detail. The ID must be available to the initialized runtime: runs from previous launches generally require Postgres, while memory-mode runs are available only for the lifetime of their runtime process.

The standard **About AdaptiveAgent Desktop** panel displays the marketing version and build number configured in `project.yml`.

## Architecture and security boundary

- `RuntimeClient` owns `Process`, separate stdin/stdout/stderr pipes, partial/multiple-line stdout buffering, JSON-RPC request correlation, and clean shutdown.
- `TraceSessionClient` independently supervises the optional read-only
  `trace-session-sidecar` helper over its protocol `1.0`. Its failure disables
  persisted history only and never changes agent execution.
- Startup requires a JSON-RPC `runtime/ready` notification, protocol `1.17` negotiation with `initialize`, and then a separate `runtime/initialize` before agent operations.
- `AppModel` is main-actor isolated and translates UI actions into typed JSON-RPC methods. It reads only the non-secret runtime, model-selection, and interaction fields needed to seed editable `runtime/initialize` overrides.
- The Swift renderer does not read agent profiles or other workspace contents and has no cloud behavior. It ignores secret-related settings fields; native file panels otherwise select paths only, and the runtime process performs runtime and filesystem behavior.
- Runtime stderr is captured separately and displayed as diagnostic event entries; it is never parsed as protocol traffic.

This development slice inherits the complete app process environment. Production distribution should narrow inherited variables and add an explicit secret-management design without moving runtime behavior into the renderer.
