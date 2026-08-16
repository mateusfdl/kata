const std = @import("std");
const mvzr = @import("mvzr");

const fact_rule = @import("engine").fact_rule;
const lint_diagnostic = @import("engine").diagnostic;
const lint_rule = @import("engine").rule;
const test_fixture = @import("../test_fixture.zig");

const ProjectIndex = @import("engine").ProjectIndex;

const Fixture = test_fixture.Fixture;

fn rootField(field: fact_rule.Field) fact_rule.Operand {
    return .{ .field = .{ .capture = 0, .field = field } };
}

fn scalar(op: fact_rule.Op, args: []const fact_rule.Operand) fact_rule.Predicate {
    return .{ .scalar = .{ .op = op, .args = args } };
}

test "fact rule: fact kinds expose the exact field matrix" {
    const expected = [5][8]bool{
        .{ true, false, false, false, false, false, true, true },
        .{ true, true, false, false, false, false, true, true },
        .{ true, false, true, false, false, false, true, true },
        .{ false, true, false, true, true, false, true, true },
        .{ true, false, false, false, false, true, true, true },
    };

    inline for (std.meta.fields(fact_rule.FactKind)) |kind_field| {
        const kind: fact_rule.FactKind = @enumFromInt(kind_field.value);
        inline for (std.meta.fields(fact_rule.Field)) |field_field| {
            const field: fact_rule.Field = @enumFromInt(field_field.value);
            try std.testing.expectEqual(expected[kind_field.value][field_field.value], fact_rule.factHasField(kind, field));
        }
    }
}

const comment_rule =
    \\rule no-comments {
    \\  lang ts, tsx, go
    \\  match comment @match
    \\  emit @match { message "no comments" }
    \\}
;

const repository_isolation: fact_rule.CompiledFactRule = .{
    .id = "repository-isolation",
    .fact = .call,
    .predicates = &.{
        scalar(.ends_with, &.{ .{ .helper = .{ .id = .receiver_type, .capture = 0 } }, .{ .literal = "Repository" } }),
        scalar(.not_ends_with, &.{ rootField(.container), .{ .literal = "Repository" } }),
    },
    .message = &.{
        .{ .literal = "call to " },
        .{ .operand = .{ .helper = .{ .id = .receiver_type, .capture = 0 } } },
        .{ .literal = "." },
        .{ .operand = rootField(.method) },
        .{ .literal = " is restricted to repository callers" },
    },
};

const user_repository_ts =
    "export class UserRepository {\n" ++
    "  find(id: number) {\n" ++
    "    return id;\n" ++
    "  }\n" ++
    "}\n";

const order_service_ts =
    "import { UserRepository } from \"./user-repository\";\n" ++
    "class OrderService {\n" ++
    "  constructor(private repo: UserRepository) {}\n" ++
    "  create() {\n" ++
    "    this.repo.find(1);\n" ++
    "  }\n" ++
    "}\n";

const audit_repository_ts =
    "import { UserRepository } from \"./user-repository\";\n" ++
    "class AuditRepository {\n" ++
    "  constructor(private repo: UserRepository) {}\n" ++
    "  audit() {\n" ++
    "    this.repo.find(2);\n" ++
    "  }\n" ++
    "}\n";

const seed_script_ts =
    "import { UserRepository } from \"./user-repository\";\n" ++
    "const repo: UserRepository = makeRepo();\n" ++
    "function seed() {\n" ++
    "  repo.find(1);\n" ++
    "}\n";

test "fact rule: repository isolation flags service and top-level callers" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));
    try index.put(try f.engine.extractFacts(gpa, audit_repository_ts, .ts, "src/audit-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, seed_script_ts, .ts, "scripts/seed.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 2), violations.len);
    try std.testing.expectEqualStrings("scripts/seed.ts", violations[0].path);
    try std.testing.expectEqualStrings("repository-isolation", violations[0].diagnostic.rule_id);
    try std.testing.expectEqualStrings("ts", violations[0].diagnostic.language);
    try std.testing.expectEqualStrings(
        "call to UserRepository.find is restricted to repository callers",
        violations[0].diagnostic.message,
    );
    try std.testing.expectEqual(@as(u32, 3), violations[0].diagnostic.range.start.line);
    try std.testing.expectEqual(@as(u32, 2), violations[0].diagnostic.range.start.column);
    try std.testing.expectEqual(lint_diagnostic.Severity.@"error", violations[0].diagnostic.severity);
    try std.testing.expectEqualStrings("src/order-service.ts", violations[1].path);
    try std.testing.expectEqualStrings(
        "call to UserRepository.find is restricted to repository callers",
        violations[1].diagnostic.message,
    );
    try std.testing.expectEqual(@as(u32, 4), violations[1].diagnostic.range.start.line);
    try std.testing.expectEqual(@as(u32, 4), violations[1].diagnostic.range.start.column);
}

test "fact rule: path filter keeps cross-file context but reports one file" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));
    try index.put(try f.engine.extractFacts(gpa, seed_script_ts, .ts, "scripts/seed.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &.{}, &index, "src/order-service.ts");

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/order-service.ts", violations[0].path);

    const missing = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &.{}, &index, "src/unknown.ts");
    try std.testing.expectEqual(@as(usize, 0), missing.len);
}

test "fact rule: ambiguous receivers emit nothing" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const ambiguous_ts =
        "class OrderService {\n" ++
        "  handle(repo: UserRepository) {\n" ++
        "    repo.find(1);\n" ++
        "  }\n" ++
        "  other(repo: CacheClient) {\n" ++
        "    repo.get(1);\n" ++
        "  }\n" ++
        "}\n";
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, ambiguous_ts, .ts, "src/order-service.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "fact rule: receiver types not defined in the project emit nothing" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const external_ts =
        "import { ExternalRepository } from \"some-lib\";\n" ++
        "class OrderService {\n" ++
        "  constructor(private repo: ExternalRepository) {}\n" ++
        "  create() {\n" ++
        "    this.repo.find(1);\n" ++
        "  }\n" ++
        "}\n";
    try index.put(try f.engine.extractFacts(gpa, external_ts, .ts, "src/order-service.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

const domain_no_infra: fact_rule.CompiledFactRule = .{
    .id = "domain-no-infra",
    .fact = .import,
    .predicates = &.{
        scalar(.glob, &.{ rootField(.path), .{ .literal = "src/domain/**" } }),
        scalar(.glob, &.{ .{ .helper = .{ .id = .resolved_import_source, .capture = 0 } }, .{ .literal = "src/infra/**" } }),
    },
    .message = &.{
        .{ .literal = "import \"" },
        .{ .operand = rootField(.source) },
        .{ .literal = "\" is denied from the domain layer" },
    },
};

test "fact rule: import boundary resolves relative specifiers" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const domain_user =
        "import { Db } from \"../infra/db\";\n" ++
        "import { Money } from \"./money\";\n" ++
        "export class User {}\n";
    const app_main =
        "import { Db } from \"../infra/db\";\n" ++
        "export const main = 1;\n";
    try index.put(try f.engine.extractFacts(gpa, domain_user, .ts, "src/domain/user.ts"));
    try index.put(try f.engine.extractFacts(gpa, app_main, .ts, "src/app/main.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{domain_no_infra}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/domain/user.ts", violations[0].path);
    try std.testing.expectEqualStrings("domain-no-infra", violations[0].diagnostic.rule_id);
    try std.testing.expectEqualStrings(
        "import \"../infra/db\" is denied from the domain layer",
        violations[0].diagnostic.message,
    );
    try std.testing.expectEqual(@as(u32, 0), violations[0].diagnostic.range.start.line);
}

test "fact rule: go import specifiers pass through verbatim" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const domain_order =
        "package domain\n" ++
        "import \"example.com/shop/infra/db\"\n" ++
        "var _ = db.Conn\n";
    try index.put(try f.engine.extractFacts(gpa, domain_order, .go, "internal/domain/order.go"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const boundary: fact_rule.CompiledFactRule = .{
        .id = "domain-no-infra",
        .fact = .import,
        .predicates = &.{
            scalar(.glob, &.{ rootField(.path), .{ .literal = "**/domain/**" } }),
            scalar(.glob, &.{ .{ .helper = .{ .id = .resolved_import_source, .capture = 0 } }, .{ .literal = "**/infra/**" } }),
        },
        .message = &.{.{ .literal = "infra import from domain" }},
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{boundary}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("internal/domain/order.go", violations[0].path);
    try std.testing.expectEqualStrings("go", violations[0].diagnostic.language);
    try std.testing.expectEqual(@as(u32, 1), violations[0].diagnostic.range.start.line);
}

test "fact rule: relative imports escaping the root emit nothing" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const domain_user =
        "import { Db } from \"../../../src/infra/db\";\n" ++
        "export class User {}\n";
    try index.put(try f.engine.extractFacts(gpa, domain_user, .ts, "src/domain/user.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{domain_no_infra}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "fact rule: empty fields compare as empty strings" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));
    try index.put(try f.engine.extractFacts(gpa, seed_script_ts, .ts, "scripts/seed.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const top_level_calls: fact_rule.CompiledFactRule = .{
        .id = "top-level-calls",
        .fact = .call,
        .predicates = &.{
            scalar(.eq, &.{ rootField(.container), .{ .literal = "" } }),
        },
        .message = &.{.{ .literal = "top-level call" }},
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{top_level_calls}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("scripts/seed.ts", violations[0].path);
    try std.testing.expectEqualStrings("top-level call", violations[0].diagnostic.message);
}

test "fact rule: class facts expose name and range" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const repository_classes: fact_rule.CompiledFactRule = .{
        .id = "repository-classes",
        .fact = .class,
        .predicates = &.{
            scalar(.ends_with, &.{ rootField(.name), .{ .literal = "Repository" } }),
        },
        .message = &.{
            .{ .literal = "class " },
            .{ .operand = rootField(.name) },
            .{ .literal = " is a repository" },
        },
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_classes}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/user-repository.ts", violations[0].path);
    try std.testing.expectEqualStrings("class UserRepository is a repository", violations[0].diagnostic.message);
    try std.testing.expectEqual(@as(u32, 0), violations[0].diagnostic.range.start.line);
    try std.testing.expectEqual(@as(u32, 7), violations[0].diagnostic.range.start.column);
}

test "fact rule: regex and any-of predicates filter facts" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));
    try index.put(try f.engine.extractFacts(gpa, audit_repository_ts, .ts, "src/audit-repository.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const finders: fact_rule.CompiledFactRule = .{
        .id = "finders",
        .fact = .call,
        .predicates = &.{
            .{ .scalar = .{
                .op = .match,
                .args = &.{rootField(.method)},
                .regex = mvzr.compile("^find").?,
            } },
            scalar(.any_of, &.{
                rootField(.container),
                .{ .literal = "OrderService" },
                .{ .literal = "BillingService" },
            }),
        },
        .message = &.{.{ .literal = "finder call" }},
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{finders}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/order-service.ts", violations[0].path);
}

test "fact rule: missing message operands render as question marks" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const untyped_ts =
        "function run(client) {\n" ++
        "  client.send(1);\n" ++
        "}\n";
    try index.put(try f.engine.extractFacts(gpa, untyped_ts, .ts, "src/run.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const all_calls: fact_rule.CompiledFactRule = .{
        .id = "all-calls",
        .fact = .call,
        .predicates = &.{},
        .message = &.{
            .{ .literal = "receiver type is " },
            .{ .operand = .{ .helper = .{ .id = .receiver_type, .capture = 0 } } },
        },
        .severity = .warn,
        .maturity = .experimental,
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{all_calls}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("receiver type is ?", violations[0].diagnostic.message);
    try std.testing.expectEqual(lint_diagnostic.Severity.warn, violations[0].diagnostic.severity);
    try std.testing.expectEqual(lint_diagnostic.Maturity.experimental, violations[0].diagnostic.maturity);
}

test "fact rule: exclude paths skip matching files" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/generated/order-service.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const all_calls: fact_rule.CompiledFactRule = .{
        .id = "all-calls",
        .fact = .call,
        .predicates = &.{},
        .message = &.{.{ .literal = "call" }},
        .exclude_paths = &.{"src/generated/**"},
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{all_calls}, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/order-service.ts", violations[0].path);
}

test "fact rule: setting exclude glob suppresses violations for matching files" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const excluding = [_]lint_rule.RuleSetting{.{ .lang = null, .id = "repository-isolation", .project = true, .exclude = &.{"src/order-*.ts"} }};
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &excluding, &index, null);
    try std.testing.expectEqual(@as(usize, 0), violations.len);

    const other_glob = [_]lint_rule.RuleSetting{.{ .lang = null, .id = "repository-isolation", .project = true, .exclude = &.{"test/**"} }};
    const kept = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &other_glob, &index, null);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
}

test "fact rule: config severity overrides violation severity" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const demoting = [_]lint_rule.RuleSetting{.{ .lang = null, .id = "repository-isolation", .project = true, .severity = .warn }};
    const demoted = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &demoting, &index, null);
    try std.testing.expectEqual(@as(usize, 1), demoted.len);
    try std.testing.expectEqual(lint_diagnostic.Severity.warn, demoted[0].diagnostic.severity);

    const without_severity = [_]lint_rule.RuleSetting{.{ .lang = null, .id = "repository-isolation", .project = true }};
    const default_severity = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &without_severity, &index, null);
    try std.testing.expectEqual(lint_diagnostic.Severity.@"error", default_severity[0].diagnostic.severity);

    const lang_scoped = [_]lint_rule.RuleSetting{.{ .lang = .ts, .id = "repository-isolation", .severity = .warn }};
    const untouched = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &lang_scoped, &index, null);
    try std.testing.expectEqual(lint_diagnostic.Severity.@"error", untouched[0].diagnostic.severity);
}

fn compileProjectRule(f: *Fixture, id: []const u8, source: []const u8) ![]const fact_rule.CompiledFactRule {
    try f.rule_set.upsertProject(.{ .id = id, .source = source }, .project);

    return f.engine.ensureCompiledFact();
}

test "fact rule: exists correlates facts across files and emits once per root" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "method-owner",
        \\rule method-owner {
        \\  kind project
        \\  match method @method
        \\  where {
        \\    exists class @owner {
        \\      where {
        \\        field(@owner, name) == field(@method, container)
        \\      }
        \\    }
        \\  }
        \\  emit @method { message "method has an owner" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, "package domain\ntype User struct{}\n", .go, "domain/user.go"));
    try index.put(try f.engine.extractFacts(gpa, "package domain\ntype User struct{}\n", .go, "domain/user_copy.go"));
    try index.put(try f.engine.extractFacts(gpa, "package domain\nfunc (u *User) Save() {}\n", .go, "domain/user_methods.go"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, "domain/user_methods.go");

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("domain/user_methods.go", violations[0].path);
    try std.testing.expectEqualStrings("method has an owner", violations[0].diagnostic.message);
}

test "fact rule: not exists emits only roots without a correlated fact" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "missing-method-owner",
        \\rule missing-method-owner {
        \\  kind project
        \\  match method @method
        \\  where {
        \\    not exists class @owner {
        \\      where {
        \\        field(@owner, name) == field(@method, container)
        \\      }
        \\    }
        \\  }
        \\  emit @method { message "method has no owner" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, "package domain\ntype User struct{}\n", .go, "domain/user.go"));
    try index.put(try f.engine.extractFacts(gpa, "package domain\nfunc (u *User) Save() {}\nfunc (o *Orphan) Save() {}\n", .go, "domain/methods.go"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqual(@as(u32, 2), violations[0].diagnostic.range.start.line);
}

test "fact rule: count correlates candidates with each root file" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "classes-per-file",
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

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, "package domain\ntype User struct{}\ntype Address struct{}\n", .go, "domain/user.go"));
    try index.put(try f.engine.extractFacts(gpa, "package domain\ntype Order struct{}\n", .go, "domain/order.go"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 2), violations.len);
    try std.testing.expectEqualStrings("domain/user.go", violations[0].path);
    try std.testing.expectEqualStrings("domain/user.go", violations[1].path);
}

test "fact rule: nested exists queries retain enclosing captures" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "resolved-call",
        \\rule resolved-call {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    exists typedDecl @decl {
        \\      where {
        \\        field(@decl, path) == field(@call, path)
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

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/order-service.ts", violations[0].path);
}

test "fact rule: groups short circuit recursive project predicates" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "selected-methods",
        \\rule selected-methods {
        \\  kind project
        \\  match method @method
        \\  where {
        \\    any {
        \\      field(@method, name) == "Save"
        \\      all {
        \\        field(@method, name) == "Delete"
        \\        exists class @owner {
        \\          where {
        \\            field(@owner, name) == field(@method, container)
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\  emit @method { message "selected method" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, "package domain\ntype User struct{}\nfunc (u *User) Save() {}\nfunc (u *User) Delete() {}\nfunc (u *User) Ignore() {}\n", .go, "domain/user.go"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 2), violations.len);
}

test "fact rule: not exists fails closed when candidate helpers are unknown" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "unknown-receiver",
        \\rule unknown-receiver {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    not exists call @candidate {
        \\      where {
        \\        receiverType(@candidate) == receiverType(@call)
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "receiver has no peer" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, "function run(client) { client.send(1); }\n", .ts, "src/run.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "fact rule: empty queries fail closed when outer helpers are unknown" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "unknown-empty-query",
        \\rule unknown-empty-query {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    not exists class @owner {
        \\      where {
        \\        field(@owner, name) == receiverType(@call)
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "missing owner" }
        \\}
        \\rule unknown-empty-query {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    count class @owner {
        \\      where {
        \\        field(@owner, name) == receiverType(@call)
        \\      }
        \\    } == 0
        \\  }
        \\  emit @call { message "zero owners" }
        \\}
        \\rule unknown-empty-query {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    not exists class @owner {
        \\      where {
        \\        exists class @peer {
        \\          where {
        \\            field(@peer, name) == receiverType(@call)
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "nested missing owner" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, "function run(client) { client.send(1); }\n", .ts, "src/run.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "fact rule: ordered scan stays definite when an earlier conjunct fails" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "ordered-scan",
        \\rule ordered-scan {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    not exists class @owner {
        \\      where {
        \\        field(@owner, name) == "DefinitelyMissing"
        \\        receiverType(@call) == field(@owner, name)
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "call has no definitely-missing owner" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    const source =
        "class Foo {}\n" ++
        "function run(client) {\n" ++
        "  client.send(1);\n" ++
        "}\n";
    try index.put(try f.engine.extractFacts(gpa, source, .ts, "src/run.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/run.ts", violations[0].path);
    try std.testing.expectEqualStrings("ordered-scan", violations[0].diagnostic.rule_id);
    try std.testing.expectEqualStrings("call has no definitely-missing owner", violations[0].diagnostic.message);
}

test "fact rule: a definite outer miss stays definite when another operand is unknown" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "definite-outer-miss",
        \\rule definite-outer-miss {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    not exists class @owner {
        \\      where {
        \\        field(@call, method) == "neverMatches"
        \\        receiverType(@call) == "Whatever"
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "missing owner" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, "function run(client) { client.send(1); }\n", .ts, "src/run.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/run.ts", violations[0].path);
    try std.testing.expectEqualStrings("definite-outer-miss", violations[0].diagnostic.rule_id);
    try std.testing.expectEqualStrings("missing owner", violations[0].diagnostic.message);
}

test "fact rule: outer only definite miss passes without candidates" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "outer-only-miss",
        \\rule outer-only-miss {
        \\  kind project
        \\  match call @call
        \\  where {
        \\    not exists class @owner {
        \\      where {
        \\        field(@call, method) == "neverMatches"
        \\      }
        \\    }
        \\  }
        \\  emit @call { message "call has no matching owner" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    const source =
        "function run(client: Client) {\n" ++
        "  client.send(1);\n" ++
        "}\n";
    try index.put(try f.engine.extractFacts(gpa, source, .ts, "src/run.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/run.ts", violations[0].path);
    try std.testing.expectEqualStrings("outer-only-miss", violations[0].diagnostic.rule_id);
    try std.testing.expectEqualStrings("call has no matching owner", violations[0].diagnostic.message);
}

test "fact rule: count uses known bounds when some candidates are unknown" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "partial-count",
        \\rule partial-count {
        \\  kind project
        \\  match class @class
        \\  where {
        \\    count import @import {
        \\      where {
        \\        resolvedImportSource(@import) == "src/a"
        \\      }
        \\    } > 0
        \\  }
        \\  emit @class { message "definite match" }
        \\}
        \\rule partial-count {
        \\  kind project
        \\  match class @class
        \\  where {
        \\    count import @import {
        \\      where {
        \\        resolvedImportSource(@import) == "src/a"
        \\      }
        \\    } == 1
        \\  }
        \\  emit @class { message "uncertain exact count" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    const source = "import { A } from \"./a\";\nimport { B } from \"../../outside\";\nclass Root {}\n";
    try index.put(try f.engine.extractFacts(gpa, source, .ts, "src/root.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("definite match", violations[0].diagnostic.message);
}

test "fact rule: count supports every comparison operator" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();

    const rules = try compileProjectRule(f, "count-comparisons",
        \\rule count-comparisons {
        \\  kind project
        \\  match method @method
        \\  where { count class @class > 1 }
        \\  emit @method { message "gt" }
        \\}
        \\rule count-comparisons {
        \\  kind project
        \\  match method @method
        \\  where { count class @class >= 2 }
        \\  emit @method { message "ge" }
        \\}
        \\rule count-comparisons {
        \\  kind project
        \\  match method @method
        \\  where { count class @class < 3 }
        \\  emit @method { message "lt" }
        \\}
        \\rule count-comparisons {
        \\  kind project
        \\  match method @method
        \\  where { count class @class <= 2 }
        \\  emit @method { message "le" }
        \\}
        \\rule count-comparisons {
        \\  kind project
        \\  match method @method
        \\  where { count class @class == 2 }
        \\  emit @method { message "eq" }
        \\}
        \\rule count-comparisons {
        \\  kind project
        \\  match method @method
        \\  where { count class @class != 1 }
        \\  emit @method { message "ne" }
        \\}
    );

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, "package domain\ntype User struct{}\ntype Order struct{}\nfunc (u *User) Save() {}\n", .go, "domain/types.go"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const violations = try fact_rule.evaluate(arena_state.allocator(), rules, &.{}, &index, null);

    try std.testing.expectEqual(@as(usize, 6), violations.len);
}
