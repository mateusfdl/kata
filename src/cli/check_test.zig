const std = @import("std");

const check = @import("check.zig");
const reports = @import("../reports.zig");
const lint = @import("../lint.zig");
const test_fixture = @import("../test_fixture.zig");

test "check: run skips .git and gitignored folders" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.initFormat(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule, .kata);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const violating = "const x = foo as any;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = violating });
    try tmp.dir.createDirPath(io, "node_modules");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/dep.ts", .data = violating });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/hook.ts", .data = violating });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "node_modules\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, rel, &.{}, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "a.ts") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, "node_modules"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, ".git"));
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 1 files, 1 violations, 0 warnings") != null);
}

test "check: warn severity counts separately and exits clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const warn_rule =
        \\rule no-as-any {
        \\  lang ts
        \\  severity warn
        \\  match as_expression @match {
        \\    child: predefined_type @t
        \\  }
        \\  where { text(@t) == "any" }
        \\  emit @match { message "as any is not allowed" }
        \\}
    ;
    var f = try test_fixture.Fixture.initFormat(gpa, &.{.ts}, "no-as-any", warn_rule, .kata);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, rel, &.{}, &reporter);

    try std.testing.expectEqual(check.Outcome.clean, outcome);
    const expected = try std.fmt.allocPrint(
        gpa,
        "{s}/a.ts:1:11 warn [no-as-any] as any is not allowed\nchecked 1 files, 0 violations, 1 warnings\n",
        .{rel},
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "check: project rules report cross-file violations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.initFormat(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule, .kata);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "user-repository.ts", .data = "export class UserRepository {\n  find(id: number) {}\n}\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "order-service.ts",
        .data = "import { UserRepository } from \"./user-repository\";\n" ++
            "class OrderService {\n" ++
            "  constructor(private repo: UserRepository) {}\n" ++
            "  create() {\n" ++
            "    this.repo.find(1);\n" ++
            "  }\n" ++
            "}\n",
    });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const rules = [_]lint.project_rule.ProjectRule{.{
        .id = "repository-isolation",
        .kind = .{ .restricted_callers = .{
            .callee_suffix = "Repository",
            .caller_suffix = "Repository",
        } },
    }};
    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, rel, &rules, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "order-service.ts:5:5 [repository-isolation] call to UserRepository.find is restricted to *Repository callers") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 1 violations, 0 warnings") != null);
}

test "check: warnings demote project violations and exit clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.initFormat(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule, .kata);
    defer f.deinit();
    f.engine.warnings = &.{.{ .lang = null, .id = "domain-no-infra" }};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "domain");
    try tmp.dir.createDirPath(io, "infra");
    try tmp.dir.writeFile(io, .{ .sub_path = "domain/user.ts", .data = "import { Db } from \"../infra/db\";\nexport class User {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "infra/db.ts", .data = "export const Db = 1;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const rules = [_]lint.project_rule.ProjectRule{.{
        .id = "domain-no-infra",
        .kind = .{ .import_boundary = .{
            .from = "**/domain/**",
            .deny = "**/infra/**",
        } },
    }};
    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, rel, &rules, &reporter);

    try std.testing.expectEqual(check.Outcome.clean, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "domain/user.ts:1:21 warn [domain-no-infra] import \"../infra/db\" is denied from **/domain/**") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 0 violations, 1 warnings") != null);
}

test "check: import-boundary project rules report violations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.initFormat(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule, .kata);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "domain");
    try tmp.dir.createDirPath(io, "infra");
    try tmp.dir.writeFile(io, .{ .sub_path = "domain/user.ts", .data = "import { Db } from \"../infra/db\";\nexport class User {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "infra/db.ts", .data = "export const Db = 1;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const rules = [_]lint.project_rule.ProjectRule{.{
        .id = "domain-no-infra",
        .kind = .{ .import_boundary = .{
            .from = "**/domain/**",
            .deny = "**/infra/**",
        } },
    }};
    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, rel, &rules, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "domain/user.ts:1:21 [domain-no-infra] import \"../infra/db\" is denied from **/domain/**") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 1 violations, 0 warnings") != null);
}

const fact_repository_isolation = [_]lint.fact_rule.CompiledFactRule{.{
    .id = "repository-isolation",
    .fact = .call,
    .predicates = &.{
        .{ .op = .ends_with, .args = &.{ .receiver_type, .{ .literal = "Repository" } } },
        .{ .op = .not_ends_with, .args = &.{ .{ .field = .container }, .{ .literal = "Repository" } } },
    },
    .message = &.{.{ .literal = "repositories can only be called by repositories" }},
}};

test "check: project kata rules report at the yaml rule positions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.initFormat(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule, .kata);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "user-repository.ts", .data = "export class UserRepository {\n  find(id: number) {}\n}\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "order-service.ts",
        .data = "import { UserRepository } from \"./user-repository\";\n" ++
            "class OrderService {\n" ++
            "  constructor(private repo: UserRepository) {}\n" ++
            "  create() {\n" ++
            "    this.repo.find(1);\n" ++
            "  }\n" ++
            "}\n",
    });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    f.engine.compiled_fact = &fact_repository_isolation;
    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, rel, &.{}, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "order-service.ts:5:5 [repository-isolation] repositories can only be called by repositories") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 1 violations, 0 warnings") != null);
}

test "check: kata import rules report at the yaml rule positions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.initFormat(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule, .kata);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "domain");
    try tmp.dir.createDirPath(io, "infra");
    try tmp.dir.writeFile(io, .{ .sub_path = "domain/user.ts", .data = "import { Db } from \"../infra/db\";\nexport class User {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "infra/db.ts", .data = "export const Db = 1;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const fact_rules = [_]lint.fact_rule.CompiledFactRule{.{
        .id = "domain-no-infra",
        .fact = .import,
        .predicates = &.{
            .{ .op = .glob, .args = &.{ .{ .field = .path }, .{ .literal = "**/domain/**" } } },
            .{ .op = .glob, .args = &.{ .resolved_import_source, .{ .literal = "**/infra/**" } } },
        },
        .message = &.{.{ .literal = "infra imports are denied from the domain layer" }},
    }};
    f.engine.compiled_fact = &fact_rules;
    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, rel, &.{}, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "domain/user.ts:1:21 [domain-no-infra] infra imports are denied from the domain layer") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 1 violations, 0 warnings") != null);
}
