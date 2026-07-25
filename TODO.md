# TODO

## Add `run/list` for Postgres-backed desktop history

The desktop app needs a typed JSON-RPC method that can discover recent runs
after the app and managed runtime process restart. Postgres already persists
runs, but protocol `1.10` currently exposes only operations that require a
known `runId`, so Swift cannot rebuild the History sidebar from the runtime.

### Runtime and protocol requirements

- [ ] Add `run/list` to the protocol `1.10` typed method set. Do not implement
      history through `cli/execute` or a legacy protocol envelope.
- [ ] Permit `run/list` only after protocol negotiation and
      `runtime/initialize` complete.
- [ ] Accept pagination parameters with bounded validation:

  ```json
  {
    "jsonrpc": "2.0",
    "id": "history",
    "method": "run/list",
    "params": {
      "limit": 20,
      "offset": 0
    }
  }
  ```

- [ ] Return root runs only by default so delegated child runs do not appear as
      independent desktop history entries.
- [ ] Order records deterministically by `createdAt` descending and then
      `runId` descending.
- [ ] Return lightweight summaries rather than events, snapshots, full prompts,
      transcripts, tool payloads, or credentials. Each summary must include:
  - `runId`
  - `sessionId`, when present
  - `invocationMode` (`run` or `chat`)
  - title or goal preview
  - status
  - `createdAt`, `updatedAt`, and `completedAt` when present
  - provider and model when present
- [ ] Return pagination information such as `hasMore` or `nextOffset`.
- [ ] Implement recent-run listing in the runtime store and SDK layers, with a
      Postgres query over `agent_runs`. No additional history table should be
      required.
- [ ] Persist an explicit invocation-mode marker when handling `agent/run` and
      `agent/chat`. Existing rows do not reliably distinguish the two; records
      without the marker must remain readable as legacy/unknown entries.
- [ ] Define memory-mode behavior consistently (it may list only runs from the
      current runtime process), while guaranteeing that memory runs are never
      presented as durable across process restarts.
- [ ] Document the request, response, lifecycle constraints, ordering, and
      errors in `docs/agent-runtime-jsonrpc.md`.

### Desktop integration requirements

- [ ] Add an app-specific setting, for example:

  ```json
  {
    "desktop": {
      "postgresHistoryLimit": 20
    }
  }
  ```

- [ ] Treat `0` as disabled and clamp positive values to a safe maximum, such
      as 100.
- [ ] After `runtime/initialize`, call `run/list` only when the effective mode
      returned by the runtime is `postgres`.
- [ ] Populate the sidebar from the returned summaries and call `run/inspect`
      only when a historical record is opened and more detail is needed.
- [ ] Keep restored history separate from tab lifetime: closing a tab must not
      delete its Postgres run, and selecting a sidebar entry must reopen it in a
      tab.
- [ ] Do not persist memory-mode runs or maintain a second Swift disk cache of
      Postgres run IDs. Postgres remains the source of truth across app
      invocations.
- [ ] A failed history request, malformed legacy record, or unavailable run
      must not prevent runtime startup or starting a new run/chat.

### Required tests

- [ ] Protocol parsing and parameter validation for `run/list`.
- [ ] Postgres results survive runtime-process restart and are limited to the
      newest `n` root runs/chats.
- [ ] Ordering and pagination are deterministic.
- [ ] Run/chat invocation mode is persisted and returned.
- [ ] Memory-mode runs do not reappear after process restart.
- [ ] The desktop does not request restored history when the effective runtime
      mode is memory or the configured limit is `0`.
- [ ] Selecting a restored sidebar record reopens it without affecting any
      running tab.
- [ ] History-loading failures degrade to an empty sidebar without failing
      initialization.
