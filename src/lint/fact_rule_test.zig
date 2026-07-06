const std = @import("std");
const mvzr = @import("mvzr");

const fact_rule = @import("fact_rule.zig");
const lint_diagnostic = @import("diagnostic.zig");
const test_fixture = @import("../test_fixture.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

const Fixture = test_fixture.Fixture;

const comment_rule = "((comment) @match (#set! message \"no comments\"))\n";

const repository_isolation: fact_rule.CompiledFactRule = .{
    .id = "repository-isolation",
    .fact = .call,
    .predicates = &.{
        .{ .op = .ends_with, .args = &.{ .receiver_type, .{ .literal = "Repository" } } },
        .{ .op = .not_ends_with, .args = &.{ .{ .field = .container }, .{ .literal = "Repository" } } },
    },
    .message = &.{
        .{ .literal = "call to " },
        .{ .operand = .receiver_type },
        .{ .literal = "." },
        .{ .operand = .{ .field = .method } },
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

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &.{}, &index);

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

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &.{}, &index);

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

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &.{}, &index);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

const domain_no_infra: fact_rule.CompiledFactRule = .{
    .id = "domain-no-infra",
    .fact = .import,
    .predicates = &.{
        .{ .op = .glob, .args = &.{ .{ .field = .path }, .{ .literal = "src/domain/**" } } },
        .{ .op = .glob, .args = &.{ .resolved_import_source, .{ .literal = "src/infra/**" } } },
    },
    .message = &.{
        .{ .literal = "import \"" },
        .{ .operand = .{ .field = .source } },
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

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{domain_no_infra}, &.{}, &index);

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
            .{ .op = .glob, .args = &.{ .{ .field = .path }, .{ .literal = "**/domain/**" } } },
            .{ .op = .glob, .args = &.{ .resolved_import_source, .{ .literal = "**/infra/**" } } },
        },
        .message = &.{.{ .literal = "infra import from domain" }},
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{boundary}, &.{}, &index);

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

    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{domain_no_infra}, &.{}, &index);

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
            .{ .op = .eq, .args = &.{ .{ .field = .container }, .{ .literal = "" } } },
        },
        .message = &.{.{ .literal = "top-level call" }},
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{top_level_calls}, &.{}, &index);

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
            .{ .op = .ends_with, .args = &.{ .{ .field = .name }, .{ .literal = "Repository" } } },
        },
        .message = &.{
            .{ .literal = "class " },
            .{ .operand = .{ .field = .name } },
            .{ .literal = " is a repository" },
        },
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{repository_classes}, &.{}, &index);

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
            .{
                .op = .match,
                .args = &.{.{ .field = .method }},
                .regex = mvzr.compile("^find").?,
            },
            .{ .op = .any_of, .args = &.{
                .{ .field = .container },
                .{ .literal = "OrderService" },
                .{ .literal = "BillingService" },
            } },
        },
        .message = &.{.{ .literal = "finder call" }},
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{finders}, &.{}, &index);

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
            .{ .operand = .receiver_type },
        },
        .severity = .warn,
    };
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{all_calls}, &.{}, &index);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("receiver type is ?", violations[0].diagnostic.message);
    try std.testing.expectEqual(lint_diagnostic.Severity.warn, violations[0].diagnostic.severity);
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
    const violations = try fact_rule.evaluate(arena_state.allocator(), &.{all_calls}, &.{}, &index);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("src/order-service.ts", violations[0].path);
}

test "fact rule: warnings demote violations to warn severity" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const bare = [_]fact_rule.ScopedId{.{ .lang = null, .id = "repository-isolation" }};
    const demoted = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &bare, &index);
    try std.testing.expectEqual(@as(usize, 1), demoted.len);
    try std.testing.expectEqual(lint_diagnostic.Severity.warn, demoted[0].diagnostic.severity);

    const project_scoped = [_]fact_rule.ScopedId{.{ .lang = null, .id = "repository-isolation", .project = true }};
    const also_demoted = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &project_scoped, &index);
    try std.testing.expectEqual(lint_diagnostic.Severity.warn, also_demoted[0].diagnostic.severity);

    const lang_scoped = [_]fact_rule.ScopedId{.{ .lang = .ts, .id = "repository-isolation" }};
    const untouched = try fact_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &lang_scoped, &index);
    try std.testing.expectEqual(lint_diagnostic.Severity.@"error", untouched[0].diagnostic.severity);
}
