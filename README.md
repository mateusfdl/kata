# kata

Tree-sitter-based linter that enforces coding-style rules from `.scm` query files.
Built to run as a hook on AI coding agents so style is enforced by tooling, not by
relying on the model.

Rules live under `rules/<lang>/<id>.scm` (embedded at build time) and may be
extended at runtime via `KATA_RULES_DIR`. Supported languages: `ts`, `tsx`, `go`.

## Build

```
make build            # debug
make release-native   # optimized, stripped
make test             # unit tests
```

## Commands

| Command | Behavior |
| --- | --- |
| `kata` | Start the daemon (foreground). Accepts `--socket=<path>`. |
| `kata check <path>` | Lint a file or, recursively, a directory. `kata check .` for the whole tree. |
| `kata stop` | Tell a running daemon to shut down. |
| `kata --lang=<ts\|tsx\|go> < src` | One-shot: read source on stdin, emit a JSON report. `--filename=<path>` infers the language. |

Exit codes: `0` clean, `2` violations, `64` usage, `70` internal error.

```
make daemon           # kata
make stop             # kata stop
kata check src/
kata --filename=src/app.tsx < app.tsx
```

## Daemon

A long-lived process that keeps tree-sitter parsers and compiled queries warm,
so per-edit hook calls skip process startup and query compilation. It is a
stateless request/response server over a unix socket; it does not implement LSP
document sync.

Socket path resolution (server and clients agree on this order):

1. `--socket <path>` / `KATA_SOCKET`
2. `$XDG_RUNTIME_DIR/kata.sock`
3. `/tmp/kata.sock`

Protocol: one `Content-Length: <n>\r\n\r\n<json>` framed request and response
per connection.

Request:

```
{ "binary_mtime": <ms>, "shutdown": false,
  "language": "ts"|null, "filename": <path>|null, "source": <text>|null }
```

Response:

```
{ "status": "ok"|"stale"|"fail", "binary_mtime": <ms>,
  "report": { "language", "diagnostics", "clean" }|null, "message": <text>|null }
```

`binary_mtime` is the modification time in milliseconds of the kata executable.
A client sends the mtime it expects; if it differs from the running daemon's own
executable, the daemon replies `stale` without linting so the client can restart
it after a rebuild. Sending `0` skips the check.

The opencode hook at `harness/opencode/hooks/kata.ts` connects to the socket,
autostarts the daemon if absent, and restarts it on a `stale` reply.
