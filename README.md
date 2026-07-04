# kata

Tree-sitter-based linter that enforces coding-style rules from `.scm` query files.
Built to run as a hook on AI coding agents so style is enforced by tooling, not by
relying on the model.

Rules live under `rules/<lang>/<id>.scm` (embedded at build time) and may be
extended with user rules under `$XDG_CONFIG_HOME/kata/rules/` and per-project
rules under `<project>/.kata/rules/`. A rule file makes a rule available; it
only runs once declared under `enabled:` in `rules.yaml`. Supported languages:
`ts`, `tsx`, `go`.

## Build

```
make build            # debug
make release-native   # optimized, stripped
make test             # unit tests
```

## Commands

| Command | Behavior |
| --- | --- |
| `kata` | Start the daemon (foreground). Socket path from `KATA_SOCKET` (see Daemon). |
| `kata check <path>` | Lint a file or, recursively, a directory. `kata check .` for the whole tree. |
| `kata query '<scm>' [path] --lang=<lang>` | Evaluate an inline rule against a file or directory (default `.`). Ignores configured rules. |
| `kata stop` | Tell a running daemon to shut down. |
| `kata new-rule <lang> <id>` | Scaffold a `.scm` template under `$XDG_CONFIG_HOME/kata/rules/<lang>/<id>.scm`. Refuses to overwrite. |
| `kata --lang=<ts\|tsx\|go> < src` | One-shot: read source on stdin, emit a JSON report. `--filename=<path>` infers the language. |

When checking a directory, `kata` skips `.git` and any folder named in the target's
`.gitignore` (plain directory entries only; globs, negations, and nested paths are ignored).

Exit codes: `0` clean, `2` violations, `64` usage, `70` internal error.

```
make daemon           # kata
make stop             # kata stop
kata check src/
kata --filename=src/app.tsx < app.tsx
```

## Ad-hoc queries

`kata query` evaluates a single inline rule without touching the configured
rule set: embedded rules, user rules, and `rules.yaml` are all ignored.

```
kata query '((function_declaration) @match
  (#where? "(> (complexity @match) 10)")
  (#set! message "complexity {complexity @match} exceeds 10"))' src/ --lang=ts
```

The query uses the same syntax as a `.scm` rule file (see Rule syntax),
including `#where?`, `#set!`, and message interpolation. Diagnostics report
under the rule id `query`.

`--lang` is required and declares which grammar(s) the query is written for;
a comma list (`--lang=ts,tsx`) applies it to several languages in one walk.
Files of other languages are skipped. Wrap the query in single quotes, since
predicates contain double quotes.

Exit codes follow `check`: `0` no matches, `2` matches, `64` for a query
that does not compile.

## Daemon

A long-lived process that keeps tree-sitter parsers and compiled queries warm,
so per-edit hook calls skip process startup and query compilation. It is a
stateless request/response server over a unix socket; it does not implement LSP
document sync.

Socket path resolution (server and clients agree on this order):

1. `KATA_SOCKET`
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

No rule runs by default. Activation is opt-in: declare rules under `enabled:`
in `$XDG_CONFIG_HOME/kata/rules.yaml` (or `$HOME/.config/kata/rules.yaml`).
Without a config, `kata check` is a clean no-op.

```yaml
enabled:
  - go/no-panic
  - no-comments
disabled:
  - tsx/no-comments
```

The active set is `enabled` minus `disabled`. `disabled` exists for pruning:
a project that inherits the global `enabled` list can subtract single rules
without redeclaring everything.

Schema:

- Top-level keys: `enabled`, `disabled`, `warnings`, `metrics`,
  `project-rules`, `ratchet`.
- `enabled:` and `disabled:` take lists of rule ids.
- Scoped form `lang/id` targets that rule in one language.
- Bare form `id` targets every rule with that id across all languages.
- Entries matching no available rule are ignored.
- `warnings:` demotes active rules to warnings; it does not activate them.
- `#` starts a comment to end of line. Blank lines are ignored.
- Indentation is exactly two spaces. Tabs are rejected.
- Unknown top-level keys are rejected to prevent silent typos.

Errors are reported with a line number and abort startup:

```
kata: rules.yaml: line 1: unknown top-level key (expected 'enabled', 'disabled', 'warnings', 'metrics', 'project-rules', or 'ratchet')
```

The daemon reads the global `rules.yaml` once at startup. Edit the file then
`kata stop` and relaunch to apply changes. Project configuration under `.kata/`
is picked up without a restart.

### Project configuration

kata discovers a project by walking up from the file being linted (or from the
`kata check` target) until it finds a `.kata/` directory, the same way biome
and similar tools discover their config. The nearest `.kata/` wins.

A project directory may contain:

```
.kata/
  rules.yaml          # same schema as the global file
  rules/<lang>/<id>.scm
```

Precedence:

- Rules load embedded → user (`$XDG_CONFIG_HOME/kata/rules/`) → project
  (`.kata/rules/`). A later tier silently shadows an earlier one by rule id.
- Config keys resolve per key: a key defined in the project `rules.yaml`
  replaces the global value wholesale; omitted keys fall through to the global
  file. A project `enabled:` therefore replaces the global active set entirely,
  an empty one deactivates every rule for that project, and `ratchet` can be
  turned on for a single project.
- Activation is opt-in at every tier: a `.scm` file under `.kata/rules/` does
  nothing until an `enabled:` entry (project or inherited global) names it.

The daemon resolves the project per request from the file path, so one daemon
serves every project. Edits under `.kata/` (rule files added, changed, or
removed, `rules.yaml` included) are detected per request and rebuild that
project's context on the fly.

### Custom rules

Drop `.scm` files under `$XDG_CONFIG_HOME/kata/rules/<lang>/` (or
`$HOME/.config/kata/rules/<lang>/`) to add your own rules. The basename of the
file is the rule id; the layout mirrors the embedded `rules/` tree. Like every
rule, a custom rule stays inactive until listed under `enabled:` in
`rules.yaml`.

A user or project rule that shares an id with an earlier tier shadows it
silently. Two rule files with the same id in the same tier (for example
`rules/ts/x.scm` and `rules/ts+tsx/x.scm`) keep the last one and print a
warning:

```
kata: warning: user rule ts/no-console overrides previous definition
```

To bootstrap a new custom rule, use:

```
kata new-rule ts no-throw-literal
```

It creates the parent directory if needed, refuses to overwrite an existing
file, and prints the path of the new `.scm` file ready for editing, plus a
reminder to add the rule to `enabled:`.

### Rule syntax

A rule is a tree-sitter query. The node to flag is captured as `@match`; its
position drives the diagnostic. Matches can be filtered with predicates and
annotated with `#set!` directives.

Predicates (all take a capture as the first argument):

- `#eq? @cap "str"` / `#eq? @a @b` — keep the match when the capture text equals
  the string (or the other capture's text). `#not-eq?` negates.
- `#any-of? @cap "a" "b" ...` — keep when the capture text equals any of the
  strings. `#not-any-of?` negates.
- `#match? @cap "regex"` — keep when the capture text matches the regular
  expression. `#not-match?` negates. Matching is **unanchored** (a substring
  search); use `^` / `$` to anchor.

`#match?` is what lets a rule carve out exceptions by content. For example, a
Go `no-comments` rule that still allows compiler directives:

```scheme
((comment) @match
 (#not-match? @match "^//go:")
 (#set! message "comments are not allowed - code should be self-documenting"))
```

Directives (`#set!`):

- `(#set! message "...")` — the diagnostic message (defaults to the rule id).
- `(#set! exclude-paths "<glob> <glob> ...")` — skip this rule for files whose
  path matches any of the space-separated globs.

Path globs are matched against the file path **relative to the check target**,
anchored to the whole path:

- `*` matches within a single path segment (does not cross `/`).
- `**` matches across segments, so `**/` matches any number of leading dirs.
- `?` matches one non-`/` character.
- A trailing `/` is a directory prefix: `vendor/` matches everything under a
  top-level `vendor/`; use `**/vendor/` to match a `vendor/` at any depth.

So `(#set! exclude-paths "**/*_test.go vendor/")` skips the rule in every
`_test.go` file and anywhere under a top-level `vendor/`. Path guards are a
no-op when no filename is available (the `--lang` one-shot reading stdin without
`--filename`).

Unknown predicate names and unknown `#set!` keys are rejected at startup, naming
the offending rule, so a typo never silently disables a check:

```
kata: rule go/no-comments: unsupported predicate, #set! key, or regex
```
