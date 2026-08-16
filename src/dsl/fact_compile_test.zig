const std = @import("std");

const ast = @import("ast.zig");
const dsl_parser = @import("parser.zig");
const fact_compile = @import("fact_compile.zig");

const diagnostic = @import("engine").diagnostic;
const fact_rule = @import("engine").fact_rule;
const rule = @import("engine").rule;
const ScratchMemory = @import("shared").scratch_memory.ScratchMemory;

fn parseDsl(arena: std.mem.Allocator, source: []const u8) !ast.File {
    var diag: dsl_parser.Diagnostic = .{};
    var p = try dsl_parser.Parser.init(arena, source, &diag);

    return p.parseFile();
}

fn compileProject(arena: std.mem.Allocator, source: []const u8) ![]fact_rule.CompiledFactRule {
    const file = try parseDsl(arena, source);
    var diag: rule.Diagnostic = .{};

    return fact_compile.compile(arena, file, &diag);
}

fn expectFactFail(source: []const u8, expected: anyerror, detail: []const u8) !void {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = try parseDsl(arena, source);
    var diag: rule.Diagnostic = .{};

    try std.testing.expectError(expected, fact_compile.compile(arena, file, &diag));
    try std.testing.expectEqualStrings(detail, diag.detail);
}

const repository_isolation_kata =
    \\rule repository-isolation {
    \\  kind project
    \\
    \\  match call @call
    \\
    \\  where {
    \\    endsWith(receiverType(@call), "Repository")
    \\    !endsWith(field(@call, container), "Repository")
    \\  }
    \\
    \\  emit @call {
    \\    message "call to {receiverType(@call)}.{field(@call, method)} is restricted to repository callers"
    \\  }
    \\}
;

test "fact compile: compiles the repository isolation rule" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(), repository_isolation_kata);

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    const compiled = rules[0];
    try std.testing.expectEqualStrings("repository-isolation", compiled.id);
    try std.testing.expectEqual(fact_rule.FactKind.call, compiled.fact);
    try std.testing.expectEqual(@as(usize, 2), compiled.predicates.len);
    try std.testing.expectEqual(fact_rule.Op.ends_with, compiled.predicates[0].scalar.op);
    try std.testing.expectEqual(fact_rule.HelperOperand{ .id = .receiver_type, .capture = 0 }, compiled.predicates[0].scalar.args[0].helper);
    try std.testing.expectEqualStrings("Repository", compiled.predicates[0].scalar.args[1].literal);
    try std.testing.expectEqual(fact_rule.Op.not_ends_with, compiled.predicates[1].scalar.op);
    try std.testing.expectEqual(fact_rule.Field.container, compiled.predicates[1].scalar.args[0].field.field);
    try std.testing.expectEqual(@as(usize, 5), compiled.message.len);
    try std.testing.expectEqualStrings("call to ", compiled.message[0].literal);
    try std.testing.expectEqual(fact_rule.HelperOperand{ .id = .receiver_type, .capture = 0 }, compiled.message[1].operand.helper);
    try std.testing.expectEqualStrings(".", compiled.message[2].literal);
    try std.testing.expectEqual(fact_rule.Field.method, compiled.message[3].operand.field.field);
    try std.testing.expectEqualStrings(" is restricted to repository callers", compiled.message[4].literal);
}

test "fact compile: compiled output survives parse scratch reset" {
    const gpa = std.testing.allocator;
    var output = std.heap.ArenaAllocator.init(gpa);
    defer output.deinit();
    var scratch = ScratchMemory.init(gpa);
    defer scratch.deinit();
    var diag: rule.Diagnostic = .{};
    const raws = [_]rule.RawRule{.{
        .id = "repository-isolation",
        .source = repository_isolation_kata,
        .origin = .project,
    }};

    const compiled = try fact_compile.compileRaws(output.allocator(), scratch.allocator(), &raws, &diag);
    const generation = scratch.generation();
    scratch.reset();
    std.debug.assert(scratch.generation() == generation + 1);
    const overwritten = try scratch.allocator().alloc(u8, repository_isolation_kata.len * 8);
    @memset(overwritten, 0xa5);

    try std.testing.expectEqual(@as(usize, 1), compiled.len);
    try std.testing.expectEqualStrings("repository-isolation", compiled[0].id);
    try std.testing.expectEqualStrings("Repository", compiled[0].predicates[0].scalar.args[1].literal);
    try std.testing.expectEqualStrings("call to ", compiled[0].message[0].literal);
}

const import_boundary_kata =
    \\rule no-infra-from-domain {
    \\  kind project
    \\
    \\  match import @import
    \\
    \\  where {
    \\    glob(field(@import, path), "src/domain/**")
    \\    glob(resolvedImportSource(@import), "src/infra/**")
    \\  }
    \\
    \\  emit @import {
    \\    message "import {field(@import, source)} is denied from the domain layer"
    \\  }
    \\}
;

test "fact compile: compiles the import boundary rule" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(), import_boundary_kata);

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    const compiled = rules[0];
    try std.testing.expectEqual(fact_rule.FactKind.import, compiled.fact);
    try std.testing.expectEqual(fact_rule.Op.glob, compiled.predicates[0].scalar.op);
    try std.testing.expectEqual(fact_rule.Field.path, compiled.predicates[0].scalar.args[0].field.field);
    try std.testing.expectEqualStrings("src/domain/**", compiled.predicates[0].scalar.args[1].literal);
    try std.testing.expectEqual(fact_rule.Op.glob, compiled.predicates[1].scalar.op);
    try std.testing.expectEqual(fact_rule.HelperOperand{ .id = .resolved_import_source, .capture = 0 }, compiled.predicates[1].scalar.args[0].helper);
    try std.testing.expectEqual(fact_rule.Field.source, compiled.message[1].operand.field.field);
}

test "fact compile: or chains fold to any-of" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(),
        \\rule finders {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    field(@call, method) == "find" || field(@call, method) == "get"
        \\    matches(field(@call, receiver), "^repo")
        \\  }
        \\  emit @call { message "finder call" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    const compiled = rules[0];
    try std.testing.expectEqual(fact_rule.Op.any_of, compiled.predicates[0].scalar.op);
    try std.testing.expectEqual(@as(usize, 3), compiled.predicates[0].scalar.args.len);
    try std.testing.expectEqual(fact_rule.Field.method, compiled.predicates[0].scalar.args[0].field.field);
    try std.testing.expectEqualStrings("find", compiled.predicates[0].scalar.args[1].literal);
    try std.testing.expectEqualStrings("get", compiled.predicates[0].scalar.args[2].literal);
    try std.testing.expectEqual(fact_rule.Op.match, compiled.predicates[1].scalar.op);
    try std.testing.expect(compiled.predicates[1].scalar.regex != null);
}

test "fact compile: severity maturity and exclude carry over" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(),
        \\rule no-generated-imports {
        \\  kind project
        \\  severity warn
        \\  maturity experimental
        \\  exclude paths "src/generated/**"
        \\  match import @import
        \\  where {
        \\    field(@import, source) == "legacy"
        \\  }
        \\  emit @import { message "legacy import" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(diagnostic.Severity.warn, rules[0].severity);
    try std.testing.expectEqual(diagnostic.Maturity.experimental, rules[0].maturity);
    try std.testing.expectEqual(@as(usize, 1), rules[0].exclude_paths.len);
    try std.testing.expectEqualStrings("src/generated/**", rules[0].exclude_paths[0]);
}

test "fact compile: local rules are skipped" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(),
        \\rule no-console {
        \\  lang ts
        \\  match identifier @id
        \\  where { text(@id) == "console" }
        \\  emit @id { message "no console" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), rules.len);
}

test "fact compile: unknown fact fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match widget @w
        \\  emit @w { message "bad" }
        \\}
    , error.UnsupportedMatch, "unknown fact (expected class, method, typedDecl, call, or import)");
}

test "fact compile: lang clause fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  lang ts
        \\  match call @call
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedClause, "project rules do not take a lang clause - filter with field(@x, lang)");
}

test "fact compile: fact matchers take no fields" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call {
        \\    receiver: identifier @r
        \\  }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedMatch, "fact matchers take no fields");
}

test "fact compile: fact matchers require a capture" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedMatch, "project rules require match <fact> @capture");
}

test "fact compile: missing match fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedMatch, "project rules require match <fact> @capture");
}

test "fact compile: unknown field fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  where { field(@call, arity) == "3" }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "unknown fact field");
}

test "fact compile: field not defined for the fact fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  where { field(@call, source) == "x" }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "field is not defined for this fact");
}

test "fact compile: receiverType on a non-call fact fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match import @import
        \\  where { endsWith(receiverType(@import), "Repository") }
        \\  emit @import { message "bad" }
        \\}
    , error.UnsupportedPredicate, "receiverType expects the call fact");
}

test "fact compile: resolvedImportSource on a non-import fact fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  where { glob(resolvedImportSource(@call), "src/**") }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "resolvedImportSource expects the import fact");
}

test "fact compile: unknown capture fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  where { field(@other, method) == "find" }
        \\  emit @call { message "bad" }
        \\}
    , error.UnknownCapture, "unknown capture");
}

test "fact compile: composition predicates fail" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    inside @call class_declaration
        \\  }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "tree composition predicates are not supported in project rules");
}

test "fact compile: numeric comparisons fail" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  where { length(@call) > 3 }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "unsupported where expression in a project rule");
}

test "fact compile: text is redirected to field" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  where { text(@call) == "x" }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "text is not available in project rules - use field(@fact, name)");
}

test "fact compile: emit must use the fact capture" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  emit @other { message "bad" }
        \\}
    , error.UnknownCapture, "emit must use the fact capture");
}

test "fact compile: glob requires a literal pattern" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  where { glob(field(@call, method), field(@call, method)) }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "glob expects (value, \"pattern\")");
}

test "fact compile: malformed placeholder fails" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call
        \\  emit @call { message "call {complexity(@call)} is bad" }
        \\}
    , error.UnsupportedPlaceholder, "message placeholder must be {field(@fact, name)} or a project helper");
}

test "fact compile: fix clause fails" {
    try expectFactFail(
        \\rule no-fix {
        \\  kind project
        \\
        \\  match call @call
        \\
        \\  emit @call {
        \\    message "bad"
        \\    fix safe "x"
        \\  }
        \\}
    , error.UnsupportedClause, "fix and suggest are not supported in project rules");
}

test "fact compile: suggest clause fails" {
    try expectFactFail(
        \\rule no-suggest {
        \\  kind project
        \\
        \\  match call @call
        \\
        \\  emit @call {
        \\    message "bad"
        \\    suggest "alt" "x"
        \\  }
        \\}
    , error.UnsupportedClause, "fix and suggest are not supported in project rules");
}

test "fact compile: compiles recursive predicate groups" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(),
        \\rule grouped-calls {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    any {
        \\      field(@call, method) == "find"
        \\      all {
        \\        field(@call, method) == "get"
        \\        field(@call, container) == "Repository"
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "grouped call" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(@as(usize, 1), rules[0].predicates.len);
}

test "fact compile: compiles correlated exists and not exists queries" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(),
        \\rule method-owner {
        \\  kind project
        \\  match method @method
        \\  where {
        \\    exists class @owner {
        \\      where {
        \\        field(@owner, name) == field(@method, container)
        \\      }
        \\    }
        \\    not exists import @ignored {
        \\      where {
        \\        field(@ignored, path) == field(@method, path)
        \\        field(@ignored, source) == "generated"
        \\      }
        \\    }
        \\  }
        \\  emit @method { message "method has an owner" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(@as(usize, 2), rules[0].predicates.len);
}

test "fact compile: compiles correlated fact counts" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(),
        \\rule classes-per-file {
        \\  kind project
        \\  match class @class
        \\  where {
        \\    count class @peer {
        \\      where {
        \\        field(@peer, path) == field(@class, path)
        \\      }
        \\    } > 1
        \\  }
        \\  emit @class { message "more than one class" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(@as(usize, 1), rules[0].predicates.len);
}

test "fact compile: nested queries can reference enclosing captures" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(),
        \\rule resolved-call {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    exists typedDecl @decl {
        \\      where {
        \\        field(@decl, name) == field(@call, receiver)
        \\        exists class @class {
        \\          where {
        \\            field(@class, name) == field(@decl, type)
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "resolved call" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), rules.len);
}

test "fact compile: query captures do not escape their scope" {
    try expectFactFail(
        \\rule escaped-capture {
        \\  kind project
        \\  match method @method
        \\  where {
        \\    exists class @owner
        \\    field(@owner, name) == field(@method, container)
        \\  }
        \\  emit @method { message "bad" }
        \\}
    , error.UnknownCapture, "unknown capture");
}

test "fact compile: fact matchers reject absent fields" {
    try expectFactFail(
        \\rule bad {
        \\  kind project
        \\  match call @call {
        \\    !receiver
        \\  }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedMatch, "fact matchers take no fields");
}

test "fact compile: tree compositions fail inside project groups and queries" {
    try expectFactFail(
        \\rule grouped-tree-query {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    any {
        \\      inside @call function_declaration
        \\      field(@call, method) == "find"
        \\    }
        \\  }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "tree composition predicates are not supported in project rules");

    try expectFactFail(
        \\rule nested-tree-query {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    exists class @class {
        \\      where {
        \\        inside @class source_file
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "bad" }
        \\}
    , error.UnsupportedPredicate, "tree composition predicates are not supported in project rules");
}

test "fact compile: compiled predicates track the captures they require" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rules = try compileProject(arena_state.allocator(),
        \\rule resolved-call {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    exists typedDecl @decl {
        \\      where {
        \\        field(@decl, name) == field(@call, receiver)
        \\        exists class @class {
        \\          where {
        \\            field(@class, name) == field(@decl, type)
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "resolved call" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(@as(usize, 1), rules[0].predicates.len);
    const outer = rules[0].predicates[0].exists;
    try std.testing.expectEqual(@as(usize, 1), outer.capture);
    try std.testing.expectEqual(@as(usize, 2), outer.predicates.len);
    try std.testing.expectEqual(@as(fact_rule.CaptureSet, 0b011), outer.predicates[0].scalar.requires);
    const inner = outer.predicates[1].exists;
    try std.testing.expectEqual(@as(usize, 2), inner.capture);
    try std.testing.expectEqual(@as(fact_rule.CaptureSet, 0b110), inner.predicates[0].scalar.requires);
    try std.testing.expectEqual(@as(fact_rule.CaptureSet, 0b010), inner.requires);
    try std.testing.expectEqual(@as(fact_rule.CaptureSet, 0b001), outer.requires);
}

test "fact compile: the sixty fifth capture fails" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var source: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try source.writer.writeAll("rule too-many-captures {\n  kind project\n  match call @root\n  where {\n");
    for (1..65) |i| try source.writer.print("    exists class @c{d}\n", .{i});
    try source.writer.writeAll("  }\n  emit @root { message \"too many\" }\n}\n");

    try expectFactFail(source.written(), error.TooManyCaptures, "too many captures");
}
