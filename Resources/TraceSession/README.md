# Trace-session helper

Install the compiled `trace-session-sidecar` executable in this directory before
building the app:

```sh
Scripts/install-local-trace-session.sh /absolute/path/to/trace-session-sidecar
```

The executable is intentionally gitignored. During development it may instead be
selected with `ADAPTIVE_AGENT_TRACE_SESSION_PATH` in the Xcode scheme.
