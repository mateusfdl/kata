const std = @import("std");

const project_rule = @import("project_rule.zig");
const test_fixture = @import("../test_fixture.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

const Fixture = test_fixture.Fixture;

const comment_rule = "((comment) @match (#set! message \"no comments\"))\n";

const repository_isolation: project_rule.ProjectRule = .{
    .id = "repository-isolation",
    .kind = .{ .restricted_callers = .{
        .callee_suffix = "Repository",
        .caller_suffix = "Repository",
    } },
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

fn indexTsFiles(f: *Fixture, gpa: std.mem.Allocator, index: *ProjectIndex) !void {
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, order_service_ts, .ts, "src/order-service.ts"));
    try index.put(try f.engine.extractFacts(gpa, audit_repository_ts, .ts, "src/audit-repository.ts"));
}

test "project rule: restricted-callers flags non-repository callers only" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();
    try indexTsFiles(f, gpa, &index);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &index);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    const v = violations[0];
    try std.testing.expectEqualStrings("src/order-service.ts", v.path);
    try std.testing.expectEqualStrings("repository-isolation", v.diagnostic.rule_id);
    try std.testing.expectEqualStrings("ts", v.diagnostic.language);
    try std.testing.expectEqualStrings(
        "call to UserRepository.find is restricted to *Repository callers",
        v.diagnostic.message,
    );
    try std.testing.expectEqual(@as(u32, 4), v.diagnostic.range.start.line);
    try std.testing.expectEqual(@as(u32, 4), v.diagnostic.range.start.column);
}

test "project rule: go constructor channel resolves receivers" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const repository_go =
        "package repo\n" ++
        "type UserRepository struct{}\n" ++
        "func (r *UserRepository) Find(id int) {}\n";
    const service_go =
        "package service\n" ++
        "type OrderService struct{}\n" ++
        "func (s *OrderService) Create() {\n" ++
        "\tr := NewUserRepository()\n" ++
        "\tr.Find(1)\n" ++
        "}\n";
    try index.put(try f.engine.extractFacts(gpa, repository_go, .go, "internal/repo/user.go"));
    try index.put(try f.engine.extractFacts(gpa, service_go, .go, "internal/service/order.go"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &index);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("internal/service/order.go", violations[0].path);
    try std.testing.expectEqualStrings(
        "call to UserRepository.Find is restricted to *Repository callers",
        violations[0].diagnostic.message,
    );
    try std.testing.expectEqual(@as(u32, 4), violations[0].diagnostic.range.start.line);
}

test "project rule: top-level callers are not repositories" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const script_ts =
        "import { UserRepository } from \"./user-repository\";\n" ++
        "const repo: UserRepository = makeRepo();\n" ++
        "function seed() {\n" ++
        "  repo.find(1);\n" ++
        "}\n";
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, script_ts, .ts, "scripts/seed.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &index);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("scripts/seed.ts", violations[0].path);
}

test "project rule: ambiguous receivers are skipped" {
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

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &index);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "project rule: callee types not defined in the project are skipped" {
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

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &index);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "project rule: violations are sorted by path and position" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const caller_template =
        "import { UserRepository } from \"./user-repository\";\n" ++
        "class Caller {\n" ++
        "  constructor(private repo: UserRepository) {}\n" ++
        "  go() {\n" ++
        "    this.repo.find(1);\n" ++
        "  }\n" ++
        "}\n";
    try index.put(try f.engine.extractFacts(gpa, user_repository_ts, .ts, "src/user-repository.ts"));
    try index.put(try f.engine.extractFacts(gpa, caller_template, .ts, "src/zz-caller.ts"));
    try index.put(try f.engine.extractFacts(gpa, caller_template, .ts, "src/aa-caller.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{repository_isolation}, &index);

    try std.testing.expectEqual(@as(usize, 2), violations.len);
    try std.testing.expectEqualStrings("src/aa-caller.ts", violations[0].path);
    try std.testing.expectEqualStrings("src/zz-caller.ts", violations[1].path);
}

const domain_no_infra: project_rule.ProjectRule = .{
    .id = "domain-no-infra",
    .kind = .{ .import_boundary = .{
        .from = "src/domain/**",
        .deny = "src/infra/**",
    } },
};

test "project rule: import-boundary resolves ts relative specifiers" {
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

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{domain_no_infra}, &index);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    const v = violations[0];
    try std.testing.expectEqualStrings("src/domain/user.ts", v.path);
    try std.testing.expectEqualStrings("domain-no-infra", v.diagnostic.rule_id);
    try std.testing.expectEqualStrings("ts", v.diagnostic.language);
    try std.testing.expectEqualStrings(
        "import \"../infra/db\" is denied from src/domain/**",
        v.diagnostic.message,
    );
    try std.testing.expectEqual(@as(u32, 0), v.diagnostic.range.start.line);
}

test "project rule: import-boundary matches go import strings" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const domain_order =
        "package domain\n" ++
        "import \"example.com/shop/infra/db\"\n" ++
        "var _ = db.Conn\n";
    const infra_db =
        "package db\n" ++
        "import \"example.com/shop/domain\"\n" ++
        "var Conn = 1\n";
    try index.put(try f.engine.extractFacts(gpa, domain_order, .go, "internal/domain/order.go"));
    try index.put(try f.engine.extractFacts(gpa, infra_db, .go, "internal/infra/db/db.go"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rule: project_rule.ProjectRule = .{
        .id = "domain-no-infra",
        .kind = .{ .import_boundary = .{
            .from = "**/domain/**",
            .deny = "**/infra/**",
        } },
    };
    const violations = try project_rule.evaluate(arena_state.allocator(), &.{rule}, &index);

    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("internal/domain/order.go", violations[0].path);
    try std.testing.expectEqual(@as(u32, 1), violations[0].diagnostic.range.start.line);
}

test "project rule: import-boundary never denies relative imports escaping the root" {
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

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{domain_no_infra}, &index);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "project rule: import-boundary judges relative imports by resolved path only" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const domain_user =
        "import { Db } from \"../infra/../shared/db\";\n" ++
        "export class User {}\n";
    try index.put(try f.engine.extractFacts(gpa, domain_user, .ts, "src/domain/user.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rule: project_rule.ProjectRule = .{
        .id = "domain-no-infra",
        .kind = .{ .import_boundary = .{
            .from = "src/domain/**",
            .deny = "**/infra/**",
        } },
    };
    const violations = try project_rule.evaluate(arena_state.allocator(), &.{rule}, &index);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "project rule: import-boundary ignores imports outside the deny glob" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    const domain_user =
        "import { Money } from \"./money\";\n" ++
        "import { uuid } from \"uuid\";\n" ++
        "export class User {}\n";
    try index.put(try f.engine.extractFacts(gpa, domain_user, .ts, "src/domain/user.ts"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const violations = try project_rule.evaluate(arena_state.allocator(), &.{domain_no_infra}, &index);

    try std.testing.expectEqual(@as(usize, 0), violations.len);
}
