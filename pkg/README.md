# Packages

In-tree build packages used by kata. Each is a self-contained `zig build`
package with its own `build.zig` and `build.zig.zon`, consumed by the root
`build.zig` as a path dependency.

| Package | Produces | Notes |
| --- | --- | --- |
| `gen-embedded-rules` | `gen_embedded_rules` host executable | Build-time codegen: turns the `rules/` tree into `embedded_rules.zig`. |
| `tree-sitter-typescript` | `ts_typescript`, `ts_tsx` static libs | Compiles the upstream TypeScript and TSX grammars. |
| `tree-sitter-go` | `ts_go` static lib | Compiles the upstream Go grammar. |

Each grammar package declares its own upstream grammar tarball as a dependency,
so the C sources are fetched and pinned per package rather than in the root
manifest.
