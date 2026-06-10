const std = @import("std");

const check = @import("check.zig");
const lint = @import("../lint.zig");
const test_fixture = @import("../test_fixture.zig");

test "check: appendIgnoredDirs keeps folder entries and skips globs, negation, comments, nested paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    const gitignore =
        "# build artifacts\n" ++
        "node_modules\n" ++
        "dist/\n" ++
        "/build\n" ++
        "  coverage  \n" ++
        "*.log\n" ++
        "!keep-me\n" ++
        "src/generated\n" ++
        "\n";

    try check.appendIgnoredDirs(arena.allocator(), gitignore, &out);

    const expected = [_][]const u8{ "node_modules", "dist", "build", "coverage" };
    try std.testing.expectEqual(expected.len, out.items.len);
    for (expected, out.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "check: appendIgnoredDirs on empty input adds nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    try check.appendIgnoredDirs(arena.allocator(), "", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
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

    const outcome = try check.run(io, gpa, &f.engine, rel, &.{}, &out.writer);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "a.ts") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, "node_modules"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, ".git"));
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 1 files, 1 violations") != null);
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
        .kind = .restricted_callers,
        .callee_suffix = "Repository",
        .caller_suffix = "Repository",
    }};
    const outcome = try check.run(io, gpa, &f.engine, rel, &rules, &out.writer);

    try std.testing.expectEqual(check.Outcome.violations, outcome);
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "order-service.ts:5:5 [repository-isolation] call to UserRepository.find is restricted to *Repository callers") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "checked 2 files, 1 violations") != null);
}
