const std = @import("std");

const check = @import("check.zig");
const reports = @import("../reports.zig");
const lint = @import("engine");
const test_fixture = @import("../test_fixture.zig");

fn runGit(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8) !void {
    const result = std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .dir = dir } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,

        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

const TreeFile = struct {
    path: []const u8,
    data: []const u8,
};

fn commitTree(gpa: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir, files: []const TreeFile) !void {
    var mirrored = false;
    for (files) |file| {
        if (std.mem.lastIndexOfScalar(u8, file.path, '/')) |idx| {
            try tmp.dir.createDirPath(io, file.path[0..idx]);
            mirrored = true;
        }
        try tmp.dir.writeFile(io, .{ .sub_path = file.path, .data = file.data });
    }
    try runGit(gpa, io, tmp.dir, &.{ "git", "init", "-q" });
    try runGit(gpa, io, tmp.dir, &.{ "git", "add", "." });
    try runGit(gpa, io, tmp.dir, &.{
        "git",                  "-c",                   "user.name=kata",
        "-c",                   "user.email=kata@test", "-c",
        "commit.gpgsign=false", "commit",               "-q",
        "-m",                   "base",
    });
    if (mirrored) try tmp.dir.deleteTree(io, ".zig-cache");
}

fn commitBaseline(gpa: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir, rel: []const u8, data: ?[]const u8) !void {
    if (data) |bytes| {
        const mirror = try std.fmt.allocPrint(gpa, "{s}/a.ts", .{rel});
        defer gpa.free(mirror);
        try commitTree(gpa, io, tmp, &.{.{ .path = mirror, .data = bytes }});
    } else {
        try commitTree(gpa, io, tmp, &.{.{ .path = "seed.md", .data = "seed\n" }});
    }
}

test "check: baseline demotes committed errors and keeps new ones" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    try commitBaseline(gpa, io, &tmp, rel, "const x = foo as any;\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\nconst y = bar as any;\n" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir } }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "a.ts:1:11 warn [no-as-any]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "a.ts:2:11 [no-as-any]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 1 files, 1 violations, 1 warnings") != null);
}

test "check: baseline exits clean when every error is committed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    try commitBaseline(gpa, io, &tmp, rel, "const x = foo as any;\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir } }, &reporter);

    try std.testing.expectEqual(check.Outcome.clean, outcome);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "checked 1 files, 0 violations, 1 warnings") != null);
}

test "check: baseline keeps errors in files absent at the ref" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    try commitBaseline(gpa, io, &tmp, rel, null);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir } }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "checked 1 files, 1 violations, 0 warnings") != null);
}

test "check: baseline backdates a rule enabled after the ref" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();
    f.rule_set.by_lang.getPtr(.ts).items[0].origin = .project;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    try commitBaseline(gpa, io, &tmp, rel, null);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const base: check.Baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir };
    const backdated = try check.backdatedRules(io, arena.allocator(), base, rel, &f.rule_set);

    try std.testing.expectEqual(@as(usize, 1), backdated.len);
    try std.testing.expectEqualStrings("no-as-any", backdated[0]);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir, .backdated = backdated } }, &reporter);

    try std.testing.expectEqual(check.Outcome.clean, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "a.ts:1:11 warn [no-as-any]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 1 files, 0 violations, 1 warnings") != null);
}

test "check: baseline backdates a severity raise in rules.yaml" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();
    f.rule_set.by_lang.getPtr(.ts).items[0].origin = .project;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    const rule_path = try std.fmt.allocPrint(gpa, "{s}/.kata/rules/ts/no-as-any.kata", .{rel});
    defer gpa.free(rule_path);
    const yaml_path = try std.fmt.allocPrint(gpa, "{s}/.kata/rules.yaml", .{rel});
    defer gpa.free(yaml_path);
    try commitTree(gpa, io, &tmp, &.{
        .{ .path = rule_path, .data = test_fixture.no_as_any_rule },
        .{ .path = yaml_path, .data = "rules:\n  ts:\n    no-as-any:\n      severity: warn\n" },
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const base: check.Baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir };
    const backdated = try check.backdatedRules(io, arena.allocator(), base, rel, &f.rule_set);

    try std.testing.expectEqual(@as(usize, 1), backdated.len);
    try std.testing.expectEqualStrings("no-as-any", backdated[0]);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir, .backdated = backdated } }, &reporter);

    try std.testing.expectEqual(check.Outcome.clean, outcome);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "checked 1 files, 0 violations, 1 warnings") != null);
}

test "check: baseline does not backdate an unchanged error rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();
    f.rule_set.by_lang.getPtr(.ts).items[0].origin = .project;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    const rule_path = try std.fmt.allocPrint(gpa, "{s}/.kata/rules/ts/no-as-any.kata", .{rel});
    defer gpa.free(rule_path);
    try commitTree(gpa, io, &tmp, &.{.{ .path = rule_path, .data = test_fixture.no_as_any_rule }});
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const base: check.Baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir };
    const backdated = try check.backdatedRules(io, arena.allocator(), base, rel, &f.rule_set);

    try std.testing.expectEqual(@as(usize, 0), backdated.len);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .baseline = .{ .ref = "HEAD", .prefix = "", .dir = tmp.dir, .backdated = backdated } }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "checked 1 files, 1 violations, 0 warnings") != null);
}

test "check: run skips .git and gitignored folders" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
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
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "a.ts") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, "node_modules"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, ".git"));
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 1 files, 1 violations, 0 warnings") != null);
}

test "check: rule fixtures are skipped while other tests dirs are linted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const violating = "const x = foo as any;\n";
    try tmp.dir.createDirPath(io, "ts+tsx/tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "ts+tsx/no-as-any.kata", .data = "rule no-as-any {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ts+tsx/tests/no-as-any.ts", .data = violating });
    try tmp.dir.createDirPath(io, "src/tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/tests/app.ts", .data = violating });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "src/tests/app.ts") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, "ts+tsx/tests/no-as-any.ts"));
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
    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", warn_rule);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel }, &reporter);

    try std.testing.expectEqual(check.Outcome.clean, outcome);
    const expected = try std.fmt.allocPrint(
        gpa,
        "{s}/a.ts:1:11 warn [no-as-any] as any is not allowed\nchecked 1 files, 0 violations, 1 warnings\n",
        .{rel},
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "check: interleaved rules report in source position order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const aaa_const_rule =
        \\rule aaa-const {
        \\  lang ts
        \\  match lexical_declaration @match
        \\  emit @match { message "declaration" }
        \\}
    ;
    const zzz_call_rule =
        \\rule zzz-call {
        \\  lang ts
        \\  match call_expression @match
        \\  emit @match { message "call" }
        \\}
    ;
    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "aaa-const", aaa_const_rule);
    defer f.deinit();
    try f.add(.ts, "zzz-call", zzz_call_rule);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "foo();\nconst x = 1;\nbar();\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const expected = try std.fmt.allocPrint(
        gpa,
        "{s}/a.ts:1:1 [zzz-call] call\n" ++
            "{s}/a.ts:2:1 [aaa-const] declaration\n" ++
            "{s}/a.ts:3:1 [zzz-call] call\n" ++
            "checked 1 files, 3 violations, 0 warnings\n",
        .{ rel, rel, rel },
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "check: project rules report cross-file violations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
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
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .project_rules = &rules }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "order-service.ts:5:5 [repository-isolation] call to UserRepository.find is restricted to *Repository callers") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 1 violations, 0 warnings") != null);
}

test "check: json diagnostics carry fingerprints for file and project rules" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source = "import { Db } from \"./infra/db\";\nconst value = source as any;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "app.ts", .data = source });
    try tmp.dir.createDirPath(io, "infra");
    try tmp.dir.writeFile(io, .{ .sub_path = "infra/db.ts", .data = "export const Db = 1;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const rules = [_]lint.project_rule.ProjectRule{.{
        .id = "no-infra",
        .kind = .{ .import_boundary = .{
            .from = "**/app.ts",
            .deny = "**/infra/**",
        } },
    }};
    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .project_rules = &rules }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);

    const JsonReport = struct {
        files: []const struct {
            path: []const u8,
            diagnostics: []const struct {
                rule_id: []const u8,
                range: lint.diagnostic.Range,
                fingerprint: []const u8,
            },
        },
    };
    const parsed = try std.json.parseFromSlice(JsonReport, gpa, out.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var diagnostic_count: usize = 0;
    for (parsed.value.files) |file| {
        for (file.diagnostics) |d| {
            var expected = [_]lint.diagnostic.Diagnostic{.{
                .rule_id = d.rule_id,
                .language = "ts",
                .message = "message",
                .range = d.range,
            }};
            try lint.fingerprint.assign(gpa, file.path, source, &expected);
            defer gpa.free(expected[0].fingerprint);

            try std.testing.expectEqualStrings(expected[0].fingerprint, d.fingerprint);
            diagnostic_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), diagnostic_count);
}

test "check: setting severity warn demotes project violations and exits clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.initWithSettings(
        gpa,
        &.{.ts},
        "no-as-any",
        test_fixture.no_as_any_rule,
        &.{.{ .lang = null, .id = "domain-no-infra", .project = true, .severity = .warn }},
    );
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
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .project_rules = &rules }, &reporter);

    try std.testing.expectEqual(check.Outcome.clean, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "domain/user.ts:1:21 warn [domain-no-infra] import \"../infra/db\" is denied from **/domain/**") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 0 violations, 1 warnings") != null);
}

test "check: import-boundary project rules report violations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
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
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .project_rules = &rules }, &reporter);

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

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
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
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "order-service.ts:5:5 [repository-isolation] repositories can only be called by repositories") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 1 violations, 0 warnings") != null);
}

test "check: kata import rules report at the yaml rule positions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
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
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "domain/user.ts:1:21 [domain-no-infra] infra imports are denied from the domain layer") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 1 violations, 0 warnings") != null);
}

const parseint_fix_rule =
    \\rule prefer-number-parseint {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @fn
    \\  }
    \\  where { text(@fn) == "parseInt" }
    \\  emit @match {
    \\    message "Prefer Number.parseInt"
    \\    fix safe @fn "Number.parseInt"
    \\  }
    \\}
;

const parseint_unsafe_fix_rule =
    \\rule prefer-number-parseint {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @fn
    \\  }
    \\  where { text(@fn) == "parseInt" }
    \\  emit @match {
    \\    message "Prefer Number.parseInt"
    \\    fix unsafe @fn "Number.parseInt"
    \\  }
    \\}
;

const parseint_broken_fix_rule =
    \\rule prefer-number-parseint {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @fn
    \\  }
    \\  where { text(@fn) == "parseInt" }
    \\  emit @match {
    \\    message "Prefer Number.parseInt"
    \\    fix safe @fn ")("
    \\  }
    \\}
;

const FixRun = struct {
    outcome: check.Outcome,
    contents: []const u8,
    report: []const u8,
    errors: []const u8,

    fn deinit(self: FixRun, gpa: std.mem.Allocator) void {
        gpa.free(self.contents);
        gpa.free(self.report);
        gpa.free(self.errors);
    }
};

fn runFix(
    gpa: std.mem.Allocator,
    io: std.Io,
    rule_source: []const u8,
    settings: []const lint.rule.RuleSetting,
    level: check.FixLevel,
) !FixRun {
    var f = try test_fixture.Fixture.initWithSettings(gpa, &.{.ts}, "prefer-number-parseint", rule_source, settings);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const n = parseInt(\"5\", 10);\n" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .fixing = .{ .level = level, .stderr = &err.writer } }, &reporter);

    const contents = try tmp.dir.readFileAlloc(io, "a.ts", gpa, .limited(4096));
    errdefer gpa.free(contents);

    return .{
        .outcome = outcome,
        .contents = contents,
        .report = try out.toOwnedSlice(),
        .errors = try err.toOwnedSlice(),
    };
}

test "check: --fix applies safe fixes and reports clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const r = try runFix(gpa, io, parseint_fix_rule, &.{}, .safe);
    defer r.deinit(gpa);

    try std.testing.expectEqual(check.Outcome.clean, r.outcome);
    try std.testing.expectEqualStrings("const n = Number.parseInt(\"5\", 10);\n", r.contents);
    try std.testing.expect(std.mem.indexOf(u8, r.report, "checked 1 files, 0 violations, 0 warnings") != null);
    try std.testing.expectEqualStrings("", r.errors);
}

test "check: --fix leaves unsafe fixes and the file untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const r = try runFix(gpa, io, parseint_unsafe_fix_rule, &.{}, .safe);
    defer r.deinit(gpa);

    try std.testing.expectEqual(check.Outcome.violations, r.outcome);
    try std.testing.expectEqualStrings("const n = parseInt(\"5\", 10);\n", r.contents);
}

test "check: --fix-unsafe applies unsafe fixes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const r = try runFix(gpa, io, parseint_unsafe_fix_rule, &.{}, .unsafe);
    defer r.deinit(gpa);

    try std.testing.expectEqual(check.Outcome.clean, r.outcome);
    try std.testing.expectEqualStrings("const n = Number.parseInt(\"5\", 10);\n", r.contents);
}

test "check: fix never override blocks application" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const settings = [_]lint.rule.RuleSetting{.{ .lang = .ts, .id = "prefer-number-parseint", .fix = .never }};
    const r = try runFix(gpa, io, parseint_fix_rule, &settings, .safe);
    defer r.deinit(gpa);

    try std.testing.expectEqual(check.Outcome.violations, r.outcome);
    try std.testing.expectEqualStrings("const n = parseInt(\"5\", 10);\n", r.contents);
}

test "check: fix unsafe-ok override applies an unsafe fix under --fix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const settings = [_]lint.rule.RuleSetting{.{ .lang = .ts, .id = "prefer-number-parseint", .fix = .unsafe_ok }};
    const r = try runFix(gpa, io, parseint_unsafe_fix_rule, &settings, .safe);
    defer r.deinit(gpa);

    try std.testing.expectEqual(check.Outcome.clean, r.outcome);
    try std.testing.expectEqualStrings("const n = Number.parseInt(\"5\", 10);\n", r.contents);
}

test "check: a fix that breaks parsing rolls back and reports the defect" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const r = try runFix(gpa, io, parseint_broken_fix_rule, &.{}, .safe);
    defer r.deinit(gpa);

    try std.testing.expectEqual(check.Outcome.violations, r.outcome);
    try std.testing.expectEqualStrings("const n = parseInt(\"5\", 10);\n", r.contents);
    try std.testing.expect(std.mem.indexOf(u8, r.errors, "fix for [prefer-number-parseint] introduces a syntax error") != null);
}

test "check: a flooding rule renders three findings plus a capped summary and still fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", test_fixture.no_as_any_rule);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const a = v as any;\n" ++
        "const b = v as any;\n" ++
        "const c = v as any;\n" ++
        "const d = v as any;\n" ++
        "const e = v as any;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    const outcome = try check.run(io, gpa, &f.engine, .{ .target = rel, .max_matches = 1 }, &reporter);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"capped\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "rule no-as-any fired 5 times in this file; showing 3, suppressed 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"violations\":5") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, written, "\"rule_id\":\"no-as-any\""));
}
