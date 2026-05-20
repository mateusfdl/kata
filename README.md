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
| `kata new-rule <lang> <id>` | Scaffold a `.scm` template under `$XDG_CONFIG_HOME/kata/rules/<lang>/<id>.scm`. Refuses to overwrite. |
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

## Configuration

Builtin rules are all active by default. To disable specific rules, create
`$XDG_CONFIG_HOME/kata/rules.yaml` (or `$HOME/.config/kata/rules.yaml`):

```yaml
disabled:
  - ts/no-console
  - tsx/no-any
  - no-comments
```

Schema:

- One top-level key `disabled:` whose value is a list of rule ids.
- Scoped form `lang/id` disables that rule in one language.
- Bare form `id` disables every rule with that id across all languages.
- `#` starts a comment to end of line. Blank lines are ignored.
- Indentation is exactly two spaces. Tabs are rejected.
- Unknown top-level keys are rejected to prevent silent typos.

Errors are reported with a line number and abort startup:

```
kata: rules.yaml: line 1: unknown top-level key (expected 'disabled')
```

The daemon reads `rules.yaml` once at startup. Edit the file then `kata stop`
and relaunch to apply changes.

### Custom rules

Drop `.scm` files under `$XDG_CONFIG_HOME/kata/rules/<lang>/` (or
`$HOME/.config/kata/rules/<lang>/`) to add your own rules. The basename of the
file is the rule id; the layout mirrors the embedded `rules/` tree.

If a user rule shares an id with a builtin (or with a rule from
`KATA_RULES_DIR`), the user rule wins and kata prints a warning on startup:

```
kata: warning: user rule ts/no-console overrides previous definition
```

`KATA_RULES_DIR` is still honored as an additional source. Unlike the
auto-discovered user dir, an explicit `KATA_RULES_DIR` that points at a
missing directory is an error. Load order is embedded → `KATA_RULES_DIR` →
user dir, so the later sources always win.

To bootstrap a new custom rule, use:

```
kata new-rule ts no-throw-literal
```

It creates the parent directory if needed, refuses to overwrite an existing
file, and prints the path of the new `.scm` file ready for editing.
