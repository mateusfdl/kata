# kata

Tree-sitter-based linter that enforces coding-style rules written in the kata DSL.
Built to run as a hook on AI coding agents so style is enforced by tooling, not by
relying on the model.

Rules live under `rules/<lang>/<id>.kata` (embedded at build time) and may be
extended with user rules under `$XDG_CONFIG_HOME/kata/rules/` and per-project
rules under `<project>/.kata/rules/`. A rule file makes a rule available; it
only runs once declared under `rules:` in `rules.yaml`. Supported languages:
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
| `kata --version` | Print the binary version. |
| `kata check <path>` | Lint a file or, recursively, a directory. `kata check .` for the whole tree. |
| `kata check --text\|--json\|--sarif <path>` | Select the report format (see Reports). |
| `kata check --baseline <git-ref> <path>` | Demote errors already present at the ref to warnings (see Baseline). |
| `kata check --fix\|--fix-unsafe <path>` | Apply safe fixes (or safe and unsafe) in place, then report what remains (see Autofix). |
| `kata query '<kata rule>' [path] --lang=<lang>` | Evaluate an inline rule against a file or directory (default `.`). Ignores configured rules. |
| `kata stop` | Tell a running daemon to shut down. |
| `kata new-rule <lang> <id>` | Scaffold a `.kata` template under `$XDG_CONFIG_HOME/kata/rules/<lang>/<id>.kata`. Refuses to overwrite. |
| `kata --lang=<ts\|tsx\|go> < src` | One-shot: read source on stdin, emit a JSON report. `--filename=<path>` infers the language. |

When checking a directory, `kata` honors full gitignore semantics: globs, character
classes, `**`, negations, anchoring, dir-only patterns, and nested `.gitignore` files
(deeper files override shallower ones, last matching pattern wins). Scopes are loaded
from the enclosing worktree root (the nearest ancestor with a `.git` marker) down, so
checking a subdirectory still applies the repository's root `.gitignore`; patterns that
would exclude the target itself are not applied to it. A built-in default
set applies at lowest precedence and can be re-enabled by a user negation such as `!dist/`:

```
.git/  node_modules/  vendor/  dist/  build/  out/  coverage/  *.min.js  *.min.css
```

Not consulted: `core.excludesFile`, `$GIT_DIR/info/exclude`, and the git index, so a
tracked-but-ignored file is still skipped. Explicit targets win: `kata check path/to/file.ts`
lints the file even if ignored; ignore rules apply only to walk-discovered files. The
daemon's `--root` pre-indexing uses the same walker, so project facts no longer index
gitignored generated code.

Exit codes: `0` clean, `2` violations, `64` usage, `70` internal error.

## Reports

`kata check` and `kata query` render diagnostics in one of four formats,
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
- `--sarif`: a SARIF 2.1.0 document. Each diagnostic becomes a `result` with
  `ruleId`, `ruleIndex`, `level` (`error` or `warning`, post-demotion, so
  `--baseline` composes: demoted findings report `warning`), `message.text`,
  one physical location (the reported path verbatim; lines and columns are
  1-based with an exclusive `endColumn`), and the fingerprint under
  `partialFingerprints."kataFingerprint/v1"` (omitted when empty). Each rule
  that produced a result gets a `tool.driver.rules[]` descriptor in first
  appearance order whose `defaultConfiguration.level` is `error` if any of its
  results was an error. `tool.driver.semanticVersion` is the kata version.
  One-shot stdin mode keeps its own JSON report and has no SARIF variant.

  A diagnostic with a safe fix (see Autofix) also carries `fixes[]` with one
  `artifactChanges` replacement (`deletedRegion` plus `insertedContent`,
  omitted for deletions), so SARIF consumers can offer the edit. Unsafe fixes
  and suggestions stay out of SARIF: it has no safety or alternatives concept,
  and emitting only safe fixes keeps auto-appliers honest.

  Omitted SARIF properties: `helpUri` (rules have no docs URL) and
  `columnKind` (kata columns are byte offsets, which SARIF cannot declare;
  identical to code-point columns for ASCII).

  For GitHub PR annotations:

  ```yaml
  - run: kata check --sarif . > kata.sarif
    continue-on-error: true
  - uses: github/codeql-action/upload-sarif@v3
    with:
      sarif_file: kata.sarif
  ```

Diagnostics within a file are ordered by source position (an enclosing node
before its descendants), then rule id for findings on the same node. The order
is stable run to run and independent of rule registration order. Under the
hood, rules are indexed by their feasible root kinds at load time and each
file is walked exactly once, offering every node only to the rules registered
for its kind, so lint cost stays flat as the active rule count grows. A rule
whose root kinds cannot be derived fails loudly at load naming the rule; there
is no silent fallback to full-tree scanning.

Every JSON diagnostic and daemon diagnostic carries a lowercase 64-character
`fingerprint`. Kata computes version 1 as:

```
kataFingerprint/v1 = hex(sha256(rule_id + "\0" + path + "\0"
                                + normalized_span_text + "\0" + occurrence_index))
```

`path` is the path printed in the report, verbatim. Run `kata check` from the
repository root for repository-relative CI identity. Daemon requests hash the
provided filename, so absolute editor paths intentionally produce machine-local
fingerprints.

`normalized_span_text` is the diagnostic range with leading and trailing
whitespace removed and every internal run of spaces, tabs, carriage returns, or
newlines collapsed to one space. Other bytes are hashed unchanged.
`occurrence_index` is the decimal source-order ordinal among diagnostics in the
same file with the same rule id and normalized span. This distinguishes repeated
identical findings without putting line numbers in the identity.

The fingerprint survives edits elsewhere in the file and whitespace-only edits
inside the diagnostic span. It changes when the rule id, reported path, or
violating code changes. Any recipe change creates `kataFingerprint/v2`; v1 must
continue emitting alongside it for one release so consumers can migrate.

Diagnostics also carry an always-present `context` array. Each entry has this
shape:

```
{"kind":"method","name":"render","range":{"start":{"line":1,"column":2},"end":{"line":3,"column":3}}}
```

`kind` is one of `function`, `method`, `class`, or `namespace`. Entries are
ordered outermost first. Kata keeps at most four, dropping outer entries before
inner entries when nesting is deeper. Anonymous functions use the name
`<anonymous>`; arrows and function expressions assigned directly to a variable
use that variable's name.

The default pretty report appends the innermost two entries to the location,
for example `in method render of class Editor`, and dims the suffix when color
is active. `--text` remains unchanged. Project-rule diagnostics have no syntax
node and therefore carry `"context":[]`.

Context is presentation data and never participates in `kataFingerprint/v1`.
Renaming an enclosing function, method, class, or namespace does not change the
finding identity.

Every diagnostic also carries `"demoted":false|true`. It is `true` only when a
baseline demoted the diagnostic from error to warning (see Baseline); severity
and demotion never participate in the fingerprint.

Every diagnostic also carries `"fix"` and `"suggestions"` (see Autofix):

```
"fix":{"range":{...},"replacement":"Number.parseInt","safety":"safe"},
"suggestions":[{"label":"use unknown","range":{...},"replacement":"unknown"}]
```

`fix` is `null` and `suggestions` is `[]` when the rule declares none. Ranges
are the replaced span in the same shape as the diagnostic range; an empty
`replacement` means delete the span. The pretty report renders a dimmed
`fix: <replacement>` line (with ` (unsafe)` when applicable, `remove` for
deletions) and one `suggest <label>: <replacement>` line each under the
message. `--text` remains unchanged. Fix data never participates in
`kataFingerprint/v1`.

## Baseline

`kata check --baseline <git-ref> <path>` demotes pre-existing errors to
warnings so CI can gate on new violations only. The ref is anything
`git rev-parse` accepts: `HEAD`, `origin/main`, a tag, a sha. Without the flag,
`KATA_BASELINE` supplies the ref; the flag wins. The command must run inside a
git work tree; an unknown ref or a missing work tree exits `64`. Baseline
composes with every report format.

For each checked file with at least one error, kata reads the file's content at
the ref via `git show`, lints it with the current rules and configuration, and
matches current errors against the baseline findings in three tiers, each
consuming only still-unmatched findings:

1. fingerprint equality,
2. same rule id and normalized span text, which catches reordered duplicates,
3. same rule id and enclosing-block hash: the sha256 of the normalized text of
   the innermost `context` entry's range, applied only when that hash is
   unique among the unmatched findings on both sides.

Each baseline finding matches at most one current error. A matched error is
reported as a warning with `"demoted":true`; unmatched errors stand, and
baseline findings without a current counterpart expire silently. Warnings are
never demoted further. Exit codes reflect post-demotion severities, so a tree
whose only errors are demoted exits `0`. Files absent at the ref are never
demoted and no rename tracking is attempted. This is demotion, not
suppression: every finding stays visible in the report.

Configuration changes are backdated. A rule whose `.kata/rules/` file is
absent at the ref, or one the ref's `.kata/rules.yaml` disabled or set to
`warn`, has all its current errors demoted, so the commit that enables or
raises a rule passes warning-first. One approximation: a rule file's own
`severity` clause is read from the working tree, not the ref, so flipping it
inside an existing rule file is not backdated; use an explicit `rules.yaml`
severity entry when that matters.

Parse and engine failures are never grandfathered: a baseline pass that fails
to lint aborts the run loudly instead of silently keeping or dropping errors.
Project-rule and fact-rule diagnostics are out of scope; only per-file lint
diagnostics demote.

The daemon's `ratchet: true` applies the same matching with the on-disk file
content as the baseline, so the edit-time hook and CI agree on what counts as
a new violation.

```
make daemon           # kata
make stop             # kata stop
kata check src/
kata --filename=src/app.tsx < app.tsx
```

## Autofix

A rule may attach a mechanical remediation to its diagnostics with optional
clauses after `message` in the emit block:

```kata
emit @match {
  message "Prefer Number.parseInt over parseInt"
  fix safe @fn "Number.parseInt"
  suggest "use unknown" @t "unknown"
}
```

- `fix safe|unsafe [@cap] "template"`: at most one per emit block, and the
  safety keyword is mandatory. `safe` claims the replacement preserves
  behavior for every match the rule can produce; `unsafe` claims it is the
  right fix but may need review. The target capture defaults to the emitted
  one; naming `@cap` replaces that capture's span instead. `fix safe ""`
  deletes exactly the span.
- `suggest "label" [@cap] "template"`: repeatable alternatives that are never
  applied under any flag; the label says what each option trades.

Templates reuse the message engine (`{text(@cap)}`, measure placeholders,
`{{`/`}}` escapes) and render at diagnostic time. The target and every
referenced capture must be bound in every alternation branch; the compiler
rejects the rule otherwise. Project (`kind project`) rules do not take fix or
suggest clauses.

`kata check --fix` applies safe fixes in place; `--fix-unsafe` applies safe
and unsafe ones. Suggestions are never applied. Per file, kata collects the
applicable edits, sorts them by start byte, applies them greedily skipping any
edit overlapping an already applied one, re-lints, and repeats up to 8 passes
or until no applicable fixes remain; skipped edits resurface on the next pass.
A pass whose result no longer parses is rolled back and reported on stderr as
a rule defect naming the contributing rules. Changed files are rewritten in
place with no backup: run `--fix` on a tree under version control. Remaining
diagnostics report normally, so exit codes keep their meaning, and
`--baseline` demotion runs on the fixed content. The daemon, one-shot mode,
and `kata query` never write files.

Per-rule application policy lives in `rules.yaml`: `fix: never` keeps a rule's
fixes in reports but never applies them; `fix: unsafe-ok` applies that rule's
unsafe fix under plain `--fix`.

Fixture files assert rendered fixes with a `// kata-expect-fix:` line bound to
the next source line like `kata-expect`; the text after the marker (trimmed,
empty for deletions) must equal the rendered replacement. For every fixture
that produces fixes, `kata test` also applies them (safe and unsafe), fails if
the result stops parsing or does not re-lint to a fixpoint within 8 passes,
and warns when a rule declares a fix that no fixture asserts.

Not every remediation is expressible: templates splice capture text verbatim,
so rewrites that transform the text itself (stripping a `.0` fraction,
editing inside a string literal) stay message-only.

## Ad-hoc queries

`kata query` evaluates a single inline rule without touching the configured
rule set: embedded rules, user rules, and `rules.yaml` are all ignored.

```
kata query 'rule query {
  lang ts
  match function_declaration @match
  where { complexity(@match) > 10 }
  emit @match { message "complexity {complexity(@match)} exceeds 10" }
}' src/ --lang=ts
```

The query is a rule block in the kata DSL (see Rule syntax) and must be
spelled `rule query { ... }`. Diagnostics report under the rule id `query`.

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

1. `KATA_SOCKET` (explicit override, no version stamp, the user owns compatibility)
2. `$XDG_RUNTIME_DIR/kata-<version>-<binary mtime ms>.sock`
3. `/tmp/kata-<version>-<binary mtime ms>.sock`

The version and mtime stamp make staleness structurally impossible: a rebuilt
binary computes a path no old daemon listens on, so cross-version requests
cannot happen. On startup the daemon sweeps its socket directory: every other
`kata-*.sock` (and the legacy `kata.sock`) is probed, live daemons receive a
`shutdown` request, dead socket files are unlinked. At most one daemon per
build survives.

Protocol: one `Content-Length: <n>\r\n\r\n<json>` framed request and response
per connection.

Request:

```
{ "shutdown": false,
  "language": "ts"|null, "filename": <path>|null, "source": <text>|null }
```

Response:

```
{ "status": "ok"|"fail",
  "report": { "language", "diagnostics", "clean" }|null, "message": <text>|null }
```

Hook clients resolve the same stamped path (version from `kata --version`,
mtime from the executable), autostart the daemon if the socket is absent, and
fall back to one-shot mode when neither is possible. No staleness handling is
needed: after a rebuild the old socket simply no longer matches.

The daemon replays lint results for unchanged content: per project context it
keeps an in-memory cache of up to 2048 files keyed by path and content hash,
storing the raw fingerprinted diagnostics. A hit skips parsing and matching
entirely; ratchet demotion, project analysis, and match caps always re-run, so
a replayed response is byte-identical to a fresh one. The cache dies with the
daemon and is dropped whenever a project's `.kata` configuration changes; it
never applies to `kata check`, `kata test`, or `kata query`.

## Configuration

No rule runs by default. Activation is opt-in: declare rules under `rules:`
in `$XDG_CONFIG_HOME/kata/rules.yaml` (or `$HOME/.config/kata/rules.yaml`).
Without a config, `kata check` is a clean no-op.

```yaml
rules:
  go:
    no-panic:
    max-nesting:
      enabled: false
  typescript:
    no-comments:
      severity: warn
    simple-repositories:
      exclude:
        - 'test/**/*.ts'
ratchet: true
```

Schema:

- Top-level keys: `rules`, `project-rules`, `ratchet`, `max-matches-per-file`.
- `rules:` nests scope keys, each scope nests rule ids: `go`, `ts`, `tsx`,
  `typescript` (both `ts` and `tsx`), and `project` (DSL project rules).
- A listed rule is active. `enabled: false` deactivates it; `enabled: true`
  is accepted but redundant.
- `severity: error | warn` overrides the rule's own severity in both
  directions.
- `exclude:` takes a list of glob patterns; the rule skips matching paths on
  top of any `exclude paths` clause in the rule itself.
- `fix: never | unsafe-ok` controls `--fix` application for language rules only
  (see Autofix); reported fixes are unaffected. Project rules reject `fix` because
  they do not produce edits.
- `max-matches-per-file: N` (top-level, default 25) caps how many diagnostics a
  single rule may report per file; `max-matches: N` on a rule overrides the
  default, `0` disables the cap for that rule. A rule over its cap renders its
  first 3 findings plus one summary diagnostic (`capped: true` in JSON) naming
  the flood, because hundreds of hits from one rule usually mean a broken
  pattern, and they drown the findings that matter for an agent hook consumer.
  Capping bounds output only: suppressed error-severity findings still count
  toward the exit code and the report summary.
- Listing the same rule twice for one scope is an error, including a
  `typescript` entry overlapping a `ts` or `tsx` entry for the same id.
- Entries matching no available rule are ignored.
- An entry naming a rule's former id (see `former-ids` below) activates the
  renamed rule, applies the entry's `severity` and `exclude` to it, and prints
  `kata: warning: rule id 'old' was renamed to 'new'; update rules.yaml`.
- An entry naming a retired id follows the retired registry: a `replaced-by`
  id redirects with the same rename warning; a removed id aborts startup with
  the recorded reason.
- Experimental rules (see `maturity` below) activate only with an explicit
  `enabled: true`; a bare entry prints a warning and skips the rule.
- `#` starts a comment to end of line. Blank lines are ignored.
- Indentation is two spaces per level. Tabs are rejected.
- Unknown top-level keys are rejected to prevent silent typos.

Errors are reported with a line number and abort startup:

```
kata: rules.yaml: line 1: unknown top-level key (expected 'rules', 'project-rules', 'ratchet', or 'max-matches-per-file')
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
  rules/<lang>/<id>.kata
```

Precedence:

- Rules load embedded → user (`$XDG_CONFIG_HOME/kata/rules/`) → project
  (`.kata/rules/`). A later tier silently shadows an earlier one by rule id.
- The `rules:` tree merges per rule: a project entry replaces the global
  entry for that scope and rule; unlisted rules inherit from the global file.
  A project prunes one inherited rule with `enabled: false` and can override
  just its `severity` or `exclude`.
- `project-rules:` and `ratchet:` resolve per key: defined in the project
  `rules.yaml` they replace the global value wholesale; omitted they fall
  through, so `ratchet` can be turned on for a single project.
- Activation is opt-in at every tier: a rule file under `.kata/rules/` does
  nothing until a `rules:` entry (project or inherited global) names it.

The daemon resolves the project per request from the file path, so one daemon
serves every project. Edits under `.kata/` (rule files added, changed, or
removed, `rules.yaml` included) are detected per request and rebuild that
project's context on the fly.

### Custom rules

Drop `.kata` files under `$XDG_CONFIG_HOME/kata/rules/<lang>/` (or
`$HOME/.config/kata/rules/<lang>/`) to add your own rules. The basename of the
file is the rule id; the layout mirrors the embedded `rules/` tree. Like every
rule, a custom rule stays inactive until listed under `rules:` in
`rules.yaml`.

A user or project rule that shares an id with an earlier tier shadows it
silently: a user `no-console.kata` overrides the embedded one. Two rule files
with the same id in the same tier (for example `rules/ts/x.kata` and
`rules/ts+tsx/x.kata`) keep the last one and print a warning:

```
kata: warning: user rule ts/no-console overrides previous definition
```

To bootstrap a new custom rule, use:

```
kata new-rule ts no-throw-literal
```

It creates the parent directory if needed, refuses to overwrite an existing
file, and prints the path of the new `.kata` file ready for editing, plus a
reminder to add the rule under `rules:`.

### Retired ids

Renames are resolved through `former-ids` while the rule still exists. When a
rule is deleted outright, its id moves to a retired registry so configs that
reference it fail loudly instead of going silently inert. kata ships an
embedded registry and reads an optional `retired.yaml` next to each rules dir
(`$XDG_CONFIG_HOME/kata/retired.yaml`, `.kata/retired.yaml`); later tiers
override earlier ones per id. Ids are global across scopes:

```yaml
old-id:
  replaced-by: new-id
gone-id:
  reason: "superseded by the no-any family"
```

`replaced-by` redirects a config entry to the new id with a rename warning.
An entry with only `reason` turns any config reference into a startup error
carrying that reason. Live ids and `former-ids` aliases resolve first; the
registry is consulted last.

### Rule syntax

Rules are written in the kata DSL as `.kata` files:

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
repeat the rule block to bundle pattern variants under one id. The node the
`emit` clause names drives the diagnostic position. The emit block may also
carry `fix` and `suggest` clauses after `message` (see Autofix).

A rule block may skip files by glob with an `exclude paths` clause:

```kata
rule no-comments {
  lang go

  exclude paths "**/*_test.go", "vendor/"

  match comment @match

  emit @match { message "comments are not allowed" }
}
```

Path globs are matched against the file path **relative to the check target**,
anchored to the whole path:

- `*` matches within a single path segment (does not cross `/`).
- `**` matches across segments, so `**/` matches any number of leading dirs.
- `?` matches one non-`/` character.
- A trailing `/` is a directory prefix: `vendor/` matches everything under a
  top-level `vendor/`; use `**/vendor/` to match a `vendor/` at any depth.

So `exclude paths "**/*_test.go", "vendor/"` skips the rule in every `_test.go`
file and anywhere under a top-level `vendor/`. Path guards are a no-op when no
filename is available (the `--lang` one-shot reading stdin without
`--filename`).

A rule declares its lifecycle with two optional clauses:

```kata
rule no-console-call {
  maturity experimental
  former-ids no-console-log, "old-no-console"

  lang ts

  match call_expression @match

  emit @match { message "no console" }
}
```

- `maturity experimental | stable | deprecated` defaults to `stable`.
  Experimental rules need an explicit `enabled: true` in `rules.yaml` to
  activate. Deprecated rules run normally and print a deprecation warning at
  startup. Every diagnostic carries the rule's maturity in the JSON report and
  daemon protocol (`"maturity":"stable"`), so downstream tooling can filter on
  it.
- `former-ids` lists ids the rule was previously published under. Config
  entries and `kata-expect` fixture annotations naming a former id resolve to
  the renamed rule, each with a warning naming the new id. A former id that
  collides with a live rule id in the same scope, or is claimed by two rules,
  fails startup.

Matchers accept alternations, and a field block on an alternation is
distributed into every branch:

```kata
match [function_declaration, method_declaration, func_literal] {
  parameters: parameter_list {
    child: parameter_declaration @match
  }
}
```

matches the parameters of any of the three kinds. A branch is a full node
pattern, not just a kind name: it may bind its own capture and carry its own
field block, so structural variants collapse into one rule block:

```kata
match method_declaration @match {
  receiver: parameter_list {
    child: parameter_declaration {
      type: [type_identifier @recv, pointer_type { child: type_identifier @recv }]
    }
  }
}
```

Branch fields render before distributed fields, alternations nest, the list
tolerates a trailing comma, and anonymous tokens make valid branches in field
position (`operator: ["void", "delete"]`). The emit capture must be bound in
every branch of an alternation it appears in - a match through a branch
without it would have no diagnostic anchor, so the compiler rejects the rule.
Other captures may be bound in only some branches: a predicate referencing a
capture the matched branch did not bind fails closed (the match is dropped,
even for negated forms like `!=`), and `capture(@x)` tests presence
explicitly. When variants need different messages, repeated rule blocks
remain the tool.

A field block line may also assert a field's absence with `!name`:

```kata
match function_declaration @match {
  name: identifier @name
  !result
}
```

matches only functions without a return type. Negated fields mix with
positive fields in any order, distribute over alternation branches, and take
grammar field names only - `!child` and `!children` are rejected at parse
time, and a field name the grammar does not define fails compilation like any
other invalid field.

A file may name a pattern once and reference it from any matcher position
with `$name`:

```kata
pattern repoReceiver = [type_identifier @recv, pointer_type { child: type_identifier @recv }]

rule repo-only {
  lang go

  match method_declaration @match {
    receiver: parameter_list {
      child: parameter_declaration {
        type: $repoReceiver
      }
    }
  }

  where { matches(text(@recv), "Repository$") }

  emit @match { message "repo method" }
}
```

Fragments expand inline at parse time: captures inside one bind exactly as if
written out, and rule blocks in the same file share it. A reference may add a
capture (`match $callable @match`) and a field block, which merge onto the
fragment; a capture on both the fragment root and the reference is a
conflict. Fragments are file-local, must be declared before use, may
reference earlier fragments, and an unused or redeclared fragment is a
compile error.

`where` blocks also take composition predicates - `inside`, `not inside`,
`has`, `not has`, `parent`, `not parent`, `follows`, `not follows`,
`precedes`, `not precedes`, and `count` - to express containment and ordering
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

`inside` takes an optional `until` boundary - a comma-separated list of kinds
(concrete or supertypes) that stop the ancestor search. The enclosing match
only counts when no node strictly between the subject and the candidate has a
boundary kind:

```kata
where {
  inside @match for_statement until func_literal
}
```

Here a `defer` nested anywhere in a loop body matches, but one wrapped in a
closure inside the loop does not, because the `func_literal` sits between the
`defer` and the `for_statement`. `not inside` negates the bounded result.

`follows` and `precedes` reach sideways instead of up or down. Their candidate
set is the named children of the subject's own parent, in source order:
`follows @a P` is true when at least one sibling starting at or after `@a`'s
end matches `P`, and `precedes @a P` is the mirror image. The nested pattern is
matched anchored at the sibling itself, with no descent into it, so a rule that
wants a statement must name a statement kind:

```kata
rule unlock-follows-lock {
  lang go

  match expression_statement @match {
    child: call_expression {
      function: selector_expression {
        field: field_identifier @method
      }
    }
  }

  where {
    text(@method) == "Lock"
    not follows @match [
      expression_statement {
        child: call_expression {
          function: selector_expression { field: field_identifier @unlock }
        }
      },
      defer_statement {
        child: call_expression {
          function: selector_expression { field: field_identifier @unlock }
        }
      },
    ] {
      where { text(@unlock) in ["Unlock", "RUnlock"] }
    }
  }

  emit @match { message "Lock without a following Unlock in the same block" }
}
```

Two consequences follow from siblings-only, anchored matching. Capture the
statement, not the expression inside it: both grammars wrap a call statement
(`block` - `expression_statement` - `call_expression` in go), so a rule that
captures the `call_expression` sees the wrapper as its parent and an empty
sibling set. And a match nested deeper in a later sibling does not count: an
`Unlock` inside a closure in a following statement leaves the `Lock` flagged,
because `follows` never descends. Neither predicate takes an `until` boundary.

A subject with no parent, or one whose siblings are all on the wrong side,
makes `follows` and `precedes` false and their negated forms true. A subject
capture that is unbound in the matched alternation branch makes the predicate
false in both polarities, the same fail-closed rule the other compositions
follow.

A nested matcher may bind its own captures and filter them with a trailing
`where` block; those captures stay scoped to the nested matcher. `count`
compares the number of nested matches: `count @match return_statement > 3`.
A node never contains itself: matches spanning exactly the subject node's
range do not count for `inside`, `has`, `count`, `follows`, or `precedes`.

Predicates in a `where` block are conjoined. `any { }` groups predicates into
a disjunction - the match survives when at least one member passes - and
`all { }` groups them back into a conjunction, useful inside an `any`. Groups
nest, take any predicate as a member (expressions, compositions, `count`, or
other groups), and are the only way composition predicates participate in an
OR:

```kata
where {
  text(@fn) == "panic"
  any {
    inside @match if_statement
    inside @match for_statement
  }
}
```

flags a `panic` call under an `if` or a `for`, but not a bare one. An `&&`
expression as a member of `any` stays one disjunct. Empty groups are
rejected at parse time.

String predicates cover exact and pattern matching: `==`, `!=`, `matches`
(regex), `startsWith`, `endsWith`, `contains`, and `glob`, which matches paths
and path-like text against `*`/`**` patterns:

```kata
where { glob(text(@src), "**/internal/**") }
```

Set membership - "is one of these literals" - has two interchangeable
spellings, both lowering to the same `#any-of?` predicate that a chain of
`text(@x) == "a" || text(@x) == "b"` folds into. The `anyOf`/`noneOf` helpers
follow the function-call style; the `in`/`not in` infix operator reuses the
`[...]` any-of bracket from node-kind alternation and reads best for long,
multi-line lists:

```kata
where { anyOf(text(@name), "toBeNull", "toBeTruthy", "toContain") }
where {
  text(@name) in [
    "toBeNull",
    "toBeTruthy",
    "toContain",
  ]
}
```

The left side of `in` is any text expression (`text(@x)`); the right side is a
bracketed list of string literals and tolerates a trailing comma. `noneOf(...)`,
`text(@name) not in [...]`, and `!anyOf(...)` are the negated forms.

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
rules:
  project:
    repository-isolation:
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

Entries under the `project` scope take the same `enabled`, `severity`, and
`exclude` keys as language rules. The yaml `project-rules:` config keeps
working unchanged next to DSL project rules. Compile errors report the
project scope:

```
kata: rule project/bad-rule: project rules do not take a lang clause - filter with field(@x, lang)
```
