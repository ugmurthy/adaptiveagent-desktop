# Run Progress, Input, and History UX Specification

Status: implementation-ready proposal  
Scope: AdaptiveAgent Desktop for macOS 14+  
Related implementation: `ContentView.swift`, `AppModel.swift`, `RuntimeClient.swift`

## 1. Goals

This change must:

1. Keep long-running tool activity compact while retaining access to every
   activity item.
2. Make chat input and steering obvious, comfortable actions without reducing
   the space available for the conversation or run result.
3. Populate the left sidebar with persisted historical runs from
   `@adaptive-agent/trace-session`, not only records observed by the current app
   process.

The three changes should feel like one coherent run workspace: current state is
easy to follow, intervention is easy to find, and past work is easy to reopen.

## 2. Current behavior and causes

- `RunActivityFeed` renders every assistant and tool activity in one
  `LazyVStack`. A tool-heavy run can therefore consume most of the detail pane.
- `RunDetailView` asks `ScrollViewReader` to scroll to each new activity, while
  also persisting a `scrollPosition`. There is no explicit distinction between
  “the user is reading older content” and “follow the live run.”
- Chat input and steering use low-profile fields in 14-point footers. They have
  the same visual weight as passive chrome even though they are the primary ways
  to continue a conversation or intervene in an active run.
- The sidebar reads only `AppModel.runs`, an in-memory collection created by the
  current app process.
- The trace-session executable already exposes a separate, read-only NDJSON
  JSON-RPC 2.0 interface. Its protocol is `1.0`; this must not be confused with
  the agent runtime process, whose only supported protocol remains `1.17`.

## 3. Proposed experience

### 3.1 Compact live activity

#### Default presentation

Keep assistant narrative and the final assistant response in the main document.
Collapse **tool activity only** into one compact “Activity” row:

```text
Activity  8 of 11 complete   web_search · Nvidia earnings…   Running    ›
```

The row has a fixed one-line height. It shows the newest tool activity. Because
events with the same tool-call ID update the existing activity, a running item
changes in place to its terminal state (`failed`, `skipped`, or `succeeded`).

When a new tool starts, the row updates in place instead of appending another
visible tool row. The count is derived from all tool activities; data is not
discarded. Failed and approval-required states use red/orange emphasis.

When no tool has run, do not show the compact row. Keep the existing “Thinking…”
row and elapsed timer. When the run finishes, the compact row remains available
and displays the terminal count and total run duration.

#### Expanded presentation

Clicking the compact row or pressing Return while it has keyboard focus expands
an inline activity panel immediately below it. The panel contains the existing
`ToolActivityRow` list in chronological order.

- Default: collapsed for each run tab.
- Expanded height: minimum 120 points, maximum 40% of the detail pane.
- The expanded list has its own vertical scrolling after reaching its maximum
  height, so it cannot push the final result or steering control off screen.
- A chevron and accessibility value announce “Expanded” or “Collapsed.”
- `⌥⌘A` toggles the panel while a run detail is selected.
- Expansion is presentation state keyed by tab ID; it does not modify
  `RunRecord.activities`.

Assistant narrative remains outside this panel because it is part of the
readable result, not mechanical progress.

#### Main-pane scrolling policy

Replace unconditional scrolling on every activity mutation with an explicit
follow state:

- Start each newly opened active run in **Follow Live** mode.
- While Follow Live is on, scroll only when a new assistant narrative item,
  interaction card, error, or final result is inserted. Tool updates do not move
  the main document because the compact row updates in place.
- If the user scrolls more than 80 points away from the bottom, turn Follow Live
  off and preserve their reading position.
- Show a floating **Jump to Latest** button when Follow Live is off and newer
  content arrives. Clicking it scrolls to the bottom and re-enables Follow Live.
- Reaching the bottom manually also re-enables Follow Live.
- Changing activity state in place must never reset the user's scroll position.

This policy fixes both failure modes: the main page remains bounded during
tool-heavy runs, and auto-scroll no longer fights a user reading earlier output.

### 3.2 Prominent chat and steering composers

Chat and steering must use one shared visual component with mode-specific copy,
action, and availability. This prevents the primary input from becoming subtle
when the user moves between run and chat tabs.

#### Steering

Replace the single-line footer with a compact composer card pinned below the
scrolling run content:

```text
┌──────────────────────────────────────────────────────────────┐
│ STEER ACTIVE RUN                                             │
│ Add a correction or new priority…                            │
│                                                     [Steer]  │
└──────────────────────────────────────────────────────────────┘
```

Requirements:

- Use a vertically growing editor with 2 visible lines by default and a maximum
  of 5 lines before the editor scrolls internally.
- Add the label **Steer active run** and helper text
  **The agent will apply this at the next safe point.**
- Use an accent-colored leading icon or 2-point focus ring and a bordered
  prominent **Steer** button.
- `⌘Return` sends. Plain Return inserts a newline.
- Preserve the draft per tab using the existing `RunTab.steerMessage` state.
- Disable send for trimmed empty text and while a steer request is pending.
- While sending, retain the typed text and show progress on the button. Clear it
  only after `run/steer` succeeds; on failure retain it and place the existing
  redacted error next to the composer.
- Give the editor an accessibility label, hint, and a predictable tab order.
- Keep the composer visible only while the selected root run accepts steering.
  The first implementation may preserve the current `status == .running`
  eligibility rule.

The composer remains pinned and does not participate in the main run scroll.
Its total default height should be approximately 96–116 points, large enough to
be noticed without dominating the result.

#### Chat

Replace the current chat footer with the same composer card treatment:

```text
┌──────────────────────────────────────────────────────────────┐
│ MESSAGE NEWS AGENT                                           │
│ Continue the conversation…                                   │
│                                          [Dictate]   [Send]  │
└──────────────────────────────────────────────────────────────┘
```

- Use the same accent treatment, typography, spacing, 2-to-5-line editor, and
  prominent action button as steering.
- Use the embedded heading **Message <agent name>** and placeholder
  **Continue the conversation…** so the purpose remains obvious even when the
  transcript is long.
- Preserve the existing per-tab `RunTab.chatMessage` draft and dictation action.
- `⌘Return` sends; plain Return inserts a newline.
- Disable send for trimmed empty text or while the chat request is pending.
- Clear the visible editor when the message is submitted, but retain a pending
  copy until the request succeeds. On failure, restore that copy if the user has
  not entered a replacement draft, and show the redacted error in or immediately
  above the card.
- Keep the card pinned below the transcript. It must remain visually distinct
  from assistant output in light mode, dark mode, active window, and inactive
  window states.
- Expose mode-specific accessibility labels: **Message <agent name>** for chat
  and **Steer active run** for steering.

### 3.3 Persisted run history

#### Sidebar information architecture

Use these sections:

```text
ACTIVE
  current in-process runs requiring attention

HISTORY
  completed/current records from the trace store, newest first
```

Rules:

- Active live records always appear in **Active**.
- Flatten each `trace/listSessions` session into one history row per root goal.
- Use `rootRunId` as the stable identity for deduplication.
- If a root run exists in both `AppModel.runs` and trace history, show one row.
  Live state wins while active; persisted trace metadata fills missing start
  time, goal, type, and terminal status.
- Preserve run/chat icons using trace `type`; use a generic run icon when old
  persisted data cannot identify invocation type.
- Each history row shows goal/title, status, and relative start time. The
  accessibility label includes the full status and absolute timestamp.
- Request the newest 100 sessions after trace initialization, then flatten their
  roots. (`trace/listSessions.limit` is a session limit, not a root limit.)
  Provide **Load Older** rather than unbounded startup loading.
- Add a small refresh button and refresh automatically after a live root reaches
  a terminal state. Debounce automatic refreshes so a burst of terminal events
  produces one query.
- While loading, retain existing rows and show an inline progress indicator.
  A trace failure shows **History unavailable — Retry** without affecting run,
  chat, approval, steering, or runtime controls.
- Memory runtime mode shows **History requires SQLite or Postgres** and does not
  launch the trace process.

#### History search

Place a search field directly above the History rows. It must communicate its
purpose without depending on a separate “Search” or “History” label:

```text
┌─ 🔍  Search run history…                                  ⓧ ─┐
```

- Always show an embedded magnifying-glass icon and the placeholder **Search
  run history…**. Do not use the generic placeholder **Search**.
- Use the native search-field clear button. `⌘F` focuses the field when the
  sidebar is visible; Escape clears a non-empty query, then releases focus.
- Give the control the accessibility label **Search run history** even though no
  external visible label is rendered.
- Match goal/title, root run ID, session ID, status, and type case-insensitively
  against already loaded history rows.
- After a 250 ms debounce, query `trace/listSessions` with
  `{ "goals": ["<query>"], "limit": 100 }`. The server applies goal filtering
  before its session limit, so goal matches are not restricted to the currently
  loaded page. Merge those results with local ID/status/type matches and
  deduplicate by root run ID.
- A query that exactly matches a known root or session ID must surface that row
  even when its goal does not match.
- While a remote search is pending, retain local matches and show a small
  progress indicator inside the search field trailing edge.
- Empty query restores the normal paginated History list and scroll position.
- No matches shows **No historical runs match “<query>”** with a **Clear Search**
  action. Trace failure retains local matches and presents a non-blocking retry.
- Search never filters the Active section. Advanced status/type/date filter
  controls are deferred.

#### Historical selection and detail

Do not coerce a historical trace into `RunRecord`. A live record is mutable and
owns execution controls; a historical item is a read-only persisted projection.
Introduce a separate sidebar selection enum:

```swift
enum SidebarItemID: Hashable {
    case live(UUID)
    case history(rootRunId: String)
}
```

Selecting a history row opens a read-only tab and lazily calls:

```json
{
  "jsonrpc": "2.0",
  "id": "trace-…",
  "method": "trace/get",
  "params": {
    "target": { "kind": "root-run", "rootRunId": "…" },
    "include": {
      "plans": false,
      "messages": false,
      "reasoning": false,
      "rawToolPayloads": false
    }
  }
}
```

The initial historical detail displays:

- identity: goal, root run ID, session ID when present, type, start/end time;
- verdict/status and trace warnings;
- usage: tokens and estimated model/tool-output cost;
- performance durations when available;
- safe chronological timeline with the same compact/expandable tool treatment;
- run tree/delegates when present.

Historical tabs must not show steering, approvals, clarification, interrupt, or
recovery controls. An explicit **Open in Runtime** action may attach the root ID
through the existing protocol-1.17 flow and invoke `run/inspect`; only then may
runtime-owned actions appear.

Important contract: the current trace-session projection intentionally removes
`RootRun.result`, detailed root errors, raw tool payloads, diagnostics, and
messages by default. Therefore:

- trace-session owns history discovery and read-only trace presentation;
- `run/inspect` on the agent runtime remains authoritative for a final result,
  detailed execution error, and executable run state;
- the desktop must not infer a final answer from trace events;
- a future product requirement to show historical final answers without
  attaching to the runtime requires an explicit privacy-reviewed trace protocol
  addition, not renderer SQL or accidental use of raw payloads.

## 4. Architecture

```diagram
┌──────────────────────── SwiftUI application ─────────────────────────┐
│                                                                     │
│  Sidebar/RunDetail ───────▶ AppModel live run state                 │
│          │                            │                              │
│          │                            ▼ protocol 1.17                │
│          │                   ┌─────────────────────┐                 │
│          │                   │ agent runtime       │                 │
│          │                   │ execute/control     │                 │
│          │                   └─────────────────────┘                 │
│          │                                                          │
│          └────────▶ TraceHistoryModel                               │
│                               ┃ protocol 1.0, read-only              │
│                               ▼                                     │
│                      ┌─────────────────────┐                         │
│                      │ trace-session       │                         │
│                      │ helper process      │                         │
│                      └─────────────────────┘                         │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                      Runtime SQLite/Postgres
```

The trace-session helper is an optional inspection process, not a replacement,
fallback, or compatibility layer for the agent runtime. No trace request may
start, steer, approve, recover, or otherwise execute an agent operation.

### 4.1 New Swift ownership

Add these focused types rather than expanding `RuntimeClient`:

- `TraceSessionClient`: process lifecycle, NDJSON buffering, request IDs,
  response correlation, protocol-`1.0` initialization, stderr diagnostics,
  bounded timeouts, and graceful `shutdown`.
- `TraceHistoryModel`: list loading, flattening, deduplication, pagination,
  selection-safe detail loading, and non-fatal health state.
- Codable trace DTOs containing only fields used by the UI. Unknown fields must
  be ignored for forward compatibility.
- `CompactToolActivityView`: shared compact/expanded rendering for live and
  historical activity sources.

Keep `RuntimeClient` exclusively responsible for agent-runtime protocol `1.17`.
Do not share protocol-version constants between the two clients.

### 4.2 Process startup and target selection

Bundle `trace-session-sidecar` as a second executable under a distinct resource
directory, with a development override such as
`ADAPTIVE_AGENT_TRACE_SESSION_PATH`. Add install/build scripts analogous to the
existing agent-runtime scripts and generate the Xcode project from
`project.yml` after resource changes.

Start order:

1. Start and initialize agent runtime protocol `1.17`.
2. Complete `runtime/initialize`.
3. Read the resolved runtime mode from `runtime/info`.
4. For SQLite, decode `connections.sqlite.path` and launch trace-session with
   `--sqlite-path <exact resolved path>`.
5. For Postgres, launch with `--database-url-env DATABASE_URL` so the credential
   remains in the inherited process environment and never enters JSON-RPC,
   diagnostics, or UI state.
6. Send trace `initialize` with protocol version string `"1.0"`; verify
   `backend.readOnly == true` and the expected backend kind.
7. Load history.

If deployments support a Postgres environment variable other than
`DATABASE_URL`, add a non-secret resolved environment-variable name to the
runtime configuration contract and pass that name to
`--database-url-env`. Never request or expose the connection string itself.

Shutdown trace first with its `shutdown` request, close stdin after the
response, and then continue the existing agent-runtime shutdown sequence.
Unexpected trace termination changes only history health and may offer Retry.

### 4.3 Privacy and diagnostics

- Launch with no sensitive-data flags in the first implementation.
- Do not request messages, reasoning, or raw tool payloads.
- Apply the existing recursive protocol redaction rules to trace diagnostics.
- Never display Postgres URLs, access tokens, authorization values, API keys, or
  raw process environment values.
- Keep trace stderr separate from protocol stdout.
- Enforce the sidecar's 1 MiB request, 8 MiB response, and 30-second query
  expectations in the client. An oversized or timed-out response fails only the
  affected history operation.

## 5. State and event rules

### Live compact activity

- Continue storing up to the current 250 activity items in `RunRecord`.
- Derive compact counts and current tool from that collection; do not create a
  second event ledger.
- Existing tool-call ID correlation remains authoritative for in-place state
  changes and out-of-order completions.
- Store `activityExpanded` and Follow Live per tab, not per run record, so two
  tabs can present the same run independently.

### Trace history

- Represent loading as `idle`, `loading`, `loaded`, or `failed(message)`.
- Store the history query and pre-search scroll position independently from live
  run selection and tab drafts.
- Cancel or supersede a debounced search request when its query changes; ignore
  a response whose query no longer matches the current field value.
- Key detail requests by root run ID and ignore a response if selection changed
  before it arrived.
- Cache successful detail reports for the app session. Manual refresh invalidates
  the selected report and list entry.
- Paginated responses are merged and deduplicated by root run ID.
- Never overwrite a newer live status with an older persisted status.

## 6. Implementation phases

### Phase 1 — Compact activity and reliable follow behavior

1. Split assistant and tool presentation in `RunActivityFeed`.
2. Add the compact tool summary and bounded expanded list.
3. Add per-tab expansion and Follow Live state.
4. Replace mutation-based unconditional scrolling with bottom-distance logic and
   **Jump to Latest**.
5. Add accessibility and keyboard behavior.

This phase is independent of trace-session and should ship first.

### Phase 2 — Chat and steering composers

1. Extract the shared pinned multiline composer presentation.
2. Replace both `chatComposer` and `steerComposer` with mode-specific instances.
3. Make steering clear on success; make chat clear visibly on submission while
   retaining a pending copy that can be restored after failure.
4. Add pending and inline failure states plus `⌘Return`.
5. Verify chat, steering, and dictation layouts at the minimum supported window
   size and with long text.

### Phase 3 — Trace client substrate

1. Build/package the trace-session executable.
2. Add DTOs and `TraceSessionClient` with protocol and lifecycle tests.
3. Decode the resolved SQLite path from `runtime/info`.
4. Start trace only for SQLite/Postgres and surface independent health.
5. Shut it down cleanly without changing agent-runtime behavior.

### Phase 4 — Sidebar history and historical detail

1. Add `TraceHistoryModel` and load/flatten `trace/listSessions`.
2. Merge/deduplicate live and persisted rows in the two sidebar sections.
3. Add the self-identifying history search field, local matching, debounced
   server goal search, cancellation, and empty/error states.
4. Add lazy `trace/get`, read-only tabs, loading, retry, and stale-response
   protection.
5. Reuse compact timeline presentation.
6. Add **Open in Runtime** for users who need runtime-owned inspection/actions.

## 7. Tests and acceptance criteria

### Activity and scrolling

- A run with 100 completed tools occupies one compact row when collapsed.
- Clicking the row reveals all 100 in a bounded, independently scrollable list.
- Running, failed, skipped, approval, and completed summaries have correct
  labels, color-independent accessibility values, and counts.
- Updating an existing tool call does not append a duplicate row.
- Tool updates do not move the main pane.
- New narrative/final output follows only while Follow Live is enabled.
- Scrolling upward prevents auto-scroll and shows **Jump to Latest**.
- The result and pinned chat/steering composer remain reachable at a 980×680
  window.

### Chat and steering

- Both modes use the same prominent card and an editor that grows from 2 through
  5 lines before scrolling internally.
- Return inserts a newline; `⌘Return` sends exactly once.
- Empty/whitespace input cannot send.
- Pending send disables duplicate submission.
- Successful steering clears its draft; failed steering retains it. Failed chat
  restores its pending message when no replacement draft was entered. Both show
  a redacted error.
- Switching tabs preserves independent chat and steer drafts.
- Chat retains dictation and exposes **Message <agent name>**; steering exposes
  **Steer active run**.

### Trace client

- The bundled executable is found and is independently overrideable in tests.
- Every request is JSON-RPC 2.0 with a string or finite-number ID.
- Initialization sends trace protocol `"1.0"` as a string and rejects any other
  selected version.
- Fragmented and combined NDJSON responses decode correctly.
- Out-of-order responses correlate by ID even though the current server limits
  itself to one concurrent query.
- JSON-RPC errors decode `error.data.protocolCode`.
- stderr is diagnostic-only and recursively redacted.
- Timeout, oversized response, malformed response, and unexpected termination
  fail history only.
- Shutdown waits for its response before closing stdin.
- No trace client code emits or accepts agent-runtime protocol `1.17` messages,
  and no `RuntimeClient` code emits trace protocol `1.0` messages.

### History

- SQLite and Postgres list persisted roots from earlier app launches.
- Session goals flatten to distinct rows and sessionless roots are included.
- A live/persisted duplicate appears once and live active state wins.
- Newest 100 sessions load initially; their roots are flattened and **Load
  Older** merges without duplicates.
- The field visibly says **Search run history…** with an embedded search icon and
  no external visible label.
- `⌘F`, Escape, clear, no-results, loading, and trace-error states behave as
  specified.
- Search matches loaded goal/title, root ID, session ID, status, and type; remote
  goal matches are returned beyond the loaded page.
- A stale response from an earlier query never replaces current search results.
- Clearing search restores the unfiltered list and prior scroll position.
- Selection changes do not display a stale detail response.
- Terminal live runs become visible in History after the debounced refresh.
- Memory mode and trace failure leave execution and current-run UI functional.
- Historical tabs expose no execution controls until **Open in Runtime**
  successfully attaches through agent-runtime.
- Default requests do not include messages, reasoning, plans, or raw tool
  payloads.

## 8. Completion definition

The work is complete when all acceptance criteria above pass, project generation
and Swift tests succeed, the trace-session package typecheck/tests succeed for
the bundled revision, and a manual macOS pass verifies the minimum window size,
VoiceOver labels, keyboard chat/steering, history search, expansion,
scroll-follow behavior, and history restoration after relaunch.
