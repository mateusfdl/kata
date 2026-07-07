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
| `kata check --text\|--json <path>` | Select the report format (see Reports). |
| `kata query '<scm>' [path] --lang=<lang>` | Evaluate an inline rule against a file or directory (default `.`). Ignores configured rules. |
| `kata stop` | Tell a running daemon to shut down. |
| `kata new-rule <lang> <id>` | Scaffold a `.scm` template under `$XDG_CONFIG_HOME/kata/rules/<lang>/<id>.scm`. Refuses to overwrite. |
| `kata --lang=<ts\|tsx\|go> < src` | One-shot: read source on stdin, emit a JSON report. `--filename=<path>` infers the language. |

When checking a directory, `kata` skips `.git` and any folder named in the target's
`.gitignore` (plain directory entries only; globs, negations, and nested paths are ignored).

Exit codes: `0` clean, `2` violations, `64` usage, `70` internal error.

## Reports

`kata check` and `kata query` render diagnostics in one of three formats,
selected by flag (the last format flag wins):

- default: code frames with the offending span underlined, two context lines
  on each side, and ANSI colors when stdout is a terminal. Cross-file project
  rule violations render as plain one-liners.
- `--text`: one line per diagnostic
  (`path:line:col [rule-id] message`), followed by a summary line.
- `--json`: a single JSON object,
  `{"files":[{"path":...,"diagnostics":[...]},...],"summary":{"files":N,"violations":N,"warnings":N}}`.
  Only files with diagnostics appear under `files`; the diagnostic shape
  matches the one-shot report.

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

Drop `.scm` or `.kata` files under `$XDG_CONFIG_HOME/kata/rules/<lang>/` (or
`$HOME/.config/kata/rules/<lang>/`) to add your own rules. The basename of the
file is the rule id; the layout mirrors the embedded `rules/` tree. Like every
rule, a custom rule stays inactive until listed under `enabled:` in
`rules.yaml`.

A user or project rule that shares an id with an earlier tier shadows it
silently, regardless of format: a user `no-console.kata` overrides the embedded
`no-console.scm`. Two rule files with the same id in the same tier (for example
`rules/ts/x.scm` and `rules/ts+tsx/x.scm`) keep the last one and print a
warning:

```
kata: warning: user rule ts/no-console overrides previous definition
```

The same id in both formats in one tier is an error, not a guess:

```
kata: rule ts/no-console exists as both .scm and .kata
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

### Kata DSL rules

Rules can also be written in the kata DSL as `.kata` files:

```kata
rule no-console {
  lang ts

  match call_expression @match {
    function: member_expression {
      object: identifier @receiver
    }
  }

  where { text(@receiver) == "console" }

  emit @match { message "console is not allowed" }
}
```

Every rule block in a `.kata` file carries the id of the file name, and the
`lang` clause must include the language directory the file sits in. A file may
repeat the rule block to bundle pattern variants under one id. Everything else
works exactly like `.scm` rules: same tiers, same shadowing, same `enabled:`
opt-in, same fixture harness under `tests/`.

Matchers accept alternations of node kinds, and a field block on an
alternation is distributed into every branch:

```kata
match [function_declaration, method_declaration, func_literal] {
  parameters: parameter_list {
    child: parameter_declaration @match
  }
}
```

matches the parameters of any of the three kinds. Branches share the same
fields and captures; when variants need different fields or messages, repeated
rule blocks remain the tool.

`where` blocks also take composition predicates - `inside`, `not inside`,
`has`, `not has`, `parent`, `not parent`, and `count` - to express containment
rules that a single query cannot:

```kata
rule no-empty-catch {
  lang ts

  match catch_clause @match {
    body: statement_block @body
  }

  where {
    not has @body [throw_statement, call_expression]
  }

  emit @match { message "catch block must handle or rethrow the error" }
}
```

`inside` and `has` search the whole ancestor and descendant chains; `parent`
is the direct-parent form, true only when the subject's immediate parent
matches. `not parent @match expression_statement`, for example, keeps a `void`
operator flagged as a sub-expression while exempting one used as a bare
statement, which `not inside` (transitive) could not express.

A nested matcher may bind its own captures and filter them with a trailing
`where` block; those captures stay scoped to the nested matcher. `count`
compares the number of nested matches: `count @match return_statement > 3`.
A node never contains itself: matches spanning exactly the subject node's
range do not count for `inside`, `has`, or `count`.

String predicates cover exact and pattern matching: `==`, `!=`, `matches`
(regex), `startsWith`, `endsWith`, `contains`, and `glob`, which matches paths
and path-like text against `*`/`**` patterns:

```kata
where { glob(text(@src), "**/internal/**") }
```

Set membership - "is one of these literals" - is spelled with the `anyOf` and
`noneOf` helpers, which lower to the same `#any-of?` predicate that a chain of
`text(@x) == "a" || text(@x) == "b"` folds into:

```kata
where { anyOf(text(@name), "toBeNull", "toBeTruthy", "toContain") }
```

`noneOf(...)` (equivalently `!anyOf(...)`) is the negated form.

Syntax and compile errors fail at startup with the rule id and position:

```
kata: rule ts/no-x: line 3, column 1: invalid rule syntax
```

### Project DSL rules

Rules with `kind project` lint the whole project instead of one syntax tree.
They live in `rules/project/<id>.kata` (project tier: `.kata/rules/project/`),
are opt-in via the `project` scope, and evaluate against facts extracted from
every checked file:

```yaml
enabled:
  - project/repository-isolation
```

```kata
rule repository-isolation {
  kind project

  match call @call

  where {
    endsWith(receiverType(@call), "Repository")
    !endsWith(field(@call, container), "Repository")
  }

  emit @call {
    message "call to {receiverType(@call)}.{field(@call, method)} is restricted to repository callers"
  }
}
```

A project rule matches exactly one fact and binds it to a capture. The facts
and their fields:

| Fact | Fields |
| --- | --- |
| `class` | `name` |
| `method` | `name`, `container` |
| `typedDecl` | `name`, `type` |
| `call` | `receiver`, `method`, `container` |
| `import` | `name`, `source` |

Every fact also has `path` and `lang`. `field(@x, name)` reads a field;
fields the extractor could not attribute are empty strings, never missing.
There is no `lang` clause on project rules - filter with
`field(@x, lang) == "go"`.

Two helpers derive values a raw field cannot give:

- `receiverType(@call)` resolves the call receiver through same-file typed
  declarations and returns the type only when it is a class defined in the
  project; ambiguous or unknown receivers are missing and the predicate fails.
- `resolvedImportSource(@import)` resolves `./` and `../` specifiers against
  the importing file (`src/domain/user.ts` + `../infra/db` gives
  `src/infra/db`); Go and non-relative specifiers pass through verbatim.

```kata
rule no-infra-from-domain {
  kind project

  match import @import

  where {
    glob(field(@import, path), "src/domain/**")
    glob(resolvedImportSource(@import), "src/infra/**")
  }

  emit @import {
    message "import {field(@import, source)} is denied from the domain layer"
  }
}
```

`disabled:` and `warnings:` accept the same `project/<id>` scope; bare ids
match project rules too. The yaml `project-rules:` config keeps working
unchanged next to DSL project rules. Compile errors report the project scope:

```
kata: rule project/bad-rule: project rules do not take a lang clause - filter with field(@x, lang)
```
