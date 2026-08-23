const std = @import("std");

const lint = @import("engine");
const gitignore = @import("git").ignore;
const source = @import("../fs/source.zig");
const test_fixture = @import("../test_fixture.zig");

const FileSpec = struct {
    path: []const u8,
    data: []const u8 = "",
};

fn buildTree(io: std.Io, tmp: *std.testing.TmpDir, files: []const FileSpec) !void {
    for (files) |f| {
        if (std.mem.lastIndexOfScalar(u8, f.path, '/')) |idx| {
            try tmp.dir.createDirPath(io, f.path[0..idx]);
        }
        try tmp.dir.writeFile(io, .{ .sub_path = f.path, .data = f.data });
    }
}

fn runGit(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    argv: []const []const u8,
) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .dir = dir } }) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,

        else => err,
    };
}

fn gitInit(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    const result = try runGit(gpa, io, dir, &.{ "git", "init", "-q" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

fn containsLine(haystack: []const u8, needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, haystack, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, needle)) return true;
    }

    return false;
}

fn queryWithAncestors(
    stack: *const gitignore.Stack,
    path: []const u8,
    is_dir: bool,
) gitignore.Verdict {
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, idx, '/')) |slash| {
        if (stack.decide(path[0..slash], true) == .ignored) return .ignored;
        idx = slash + 1;
    }

    return stack.decide(path, is_dir);
}

fn expectMatcherParity(gitignore_bytes: []const u8, files: []const FileSpec) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, &tmp, files);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = gitignore_bytes });
    try gitInit(gpa, io, tmp.dir);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-c", "core.excludesfile=", "check-ignore" });
    for (files) |f| try argv.append(gpa, f.path);

    const result = try runGit(gpa, io, tmp.dir, argv.items);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited <= 1);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var stack = try gitignore.Stack.init(arena.allocator());
    try stack.pushScope("", gitignore_bytes);

    var git_view: std.Io.Writer.Allocating = .init(gpa);
    defer git_view.deinit();
    var kata_view: std.Io.Writer.Allocating = .init(gpa);
    defer kata_view.deinit();

    for (files) |f| {
        const git_ignored = containsLine(result.stdout, f.path);
        const kata_ignored = queryWithAncestors(&stack, f.path, false) == .ignored;
        try git_view.writer.print("{s} ignored={}\n", .{ f.path, git_ignored });
        try kata_view.writer.print("{s} ignored={}\n", .{ f.path, kata_ignored });
    }

    try std.testing.expectEqualStrings(git_view.written(), kata_view.written());
}

const Collector = struct {
    gpa: std.mem.Allocator,
    prefix_len: usize,
    paths: *std.ArrayList([]const u8),
};

fn collectPath(
    ctx: Collector,
    lang: lint.language.Name,
    bytes: []const u8,
    path: []const u8,
) anyerror!void {
    _ = lang;
    _ = bytes;
    try ctx.paths.append(ctx.gpa, try ctx.gpa.dupe(u8, path[ctx.prefix_len..]));
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn expectWalkerParity(files: []const FileSpec) !void {
    try expectWalkerParityUnder(files, "");
}

fn expectWalkerParityUnder(files: []const FileSpec, sub: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try buildTree(io, &tmp, files);
    try gitInit(gpa, io, tmp.dir);

    const status = try runGit(gpa, io, tmp.dir, &.{
        "git", "-c", "core.excludesfile=", "status", "--porcelain", "-uall",
    });
    defer gpa.free(status.stdout);
    defer gpa.free(status.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, status.term);

    var git_paths: std.ArrayList([]const u8) = .empty;
    defer git_paths.deinit(gpa);
    var lines = std.mem.splitScalar(u8, status.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "?? ")) continue;
        var path = line[3..];
        if (!std.mem.endsWith(u8, path, ".ts")) continue;
        if (sub.len > 0) {
            if (!std.mem.startsWith(u8, path, sub) or path[sub.len] != '/') continue;
            path = path[sub.len + 1 ..];
        }
        try git_paths.append(gpa, path);
    }

    var path_buf: [256]u8 = undefined;
    const tmp_rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    var sub_buf: [256]u8 = undefined;
    const rel = if (sub.len == 0)
        tmp_rel
    else
        try std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ tmp_rel, sub });

    var kata_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (kata_paths.items) |p| gpa.free(p);
        kata_paths.deinit(gpa);
    }
    const ctx = Collector{ .gpa = gpa, .prefix_len = rel.len + 1, .paths = &kata_paths };
    _ = try source.walkFiles(io, gpa, rel, ctx, collectPath);

    std.mem.sort([]const u8, git_paths.items, {}, pathLessThan);
    std.mem.sort([]const u8, kata_paths.items, {}, pathLessThan);

    var git_view: std.Io.Writer.Allocating = .init(gpa);
    defer git_view.deinit();
    var kata_view: std.Io.Writer.Allocating = .init(gpa);
    defer kata_view.deinit();
    for (git_paths.items) |p| try git_view.writer.print("{s}\n", .{p});
    for (kata_paths.items) |p| try kata_view.writer.print("{s}\n", .{p});

    try std.testing.expectEqualStrings(git_view.written(), kata_view.written());
}

test "parity: character classes and question marks" {
    try expectMatcherParity("te[sm]?.ts\n[!a]x.ts\n[0-9]*.ts\n", &.{
        .{ .path = "tesa.ts" },
        .{ .path = "temz.ts" },
        .{ .path = "tes.ts" },
        .{ .path = "bx.ts" },
        .{ .path = "ax.ts" },
        .{ .path = "5foo.ts" },
        .{ .path = "afoo.ts" },
    });
}

test "parity: anchoring and double-star variants" {
    try expectMatcherParity("/top.ts\nsub/*.gen.ts\n**/deep/\na/**/b.ts\n", &.{
        .{ .path = "top.ts" },
        .{ .path = "x/top.ts" },
        .{ .path = "sub/a.gen.ts" },
        .{ .path = "sub/x/a.gen.ts" },
        .{ .path = "q/deep/f.ts" },
        .{ .path = "a/b.ts" },
        .{ .path = "a/m/n/b.ts" },
        .{ .path = "a/m/c.ts" },
    });
}

test "parity: last-match-wins with negations and escapes" {
    try expectMatcherParity("logs/*.ts\n!logs/keep.ts\n\\!bang.ts\nstar\\*.ts\n", &.{
        .{ .path = "logs/a.ts" },
        .{ .path = "logs/keep.ts" },
        .{ .path = "!bang.ts" },
        .{ .path = "bang.ts" },
        .{ .path = "star*.ts" },
        .{ .path = "starx.ts" },
    });
}

test "parity: walker matches git status with nested gitignore" {
    try expectWalkerParity(&.{
        .{ .path = ".gitignore", .data = "gen/\n" },
        .{ .path = "pkg/.gitignore", .data = "!gen/\n" },
        .{ .path = "gen/a.ts" },
        .{ .path = "pkg/gen/b.ts" },
        .{ .path = "ok.ts" },
    });
}

test "parity: walker suppresses negations under excluded directories" {
    try expectWalkerParity(&.{
        .{ .path = ".gitignore", .data = "a/\n!a/b/keep.ts\n" },
        .{ .path = "a/b/keep.ts" },
        .{ .path = "a/b/drop.ts" },
        .{ .path = "ok.ts" },
    });
}

test "parity: walker subdirectory target consults ancestor gitignore" {
    try expectWalkerParityUnder(&.{
        .{ .path = ".gitignore", .data = "app/gen/\n*.skip.ts\n" },
        .{ .path = "app/gen/x.ts" },
        .{ .path = "app/a.skip.ts" },
        .{ .path = "app/nested/b.skip.ts" },
        .{ .path = "app/ok.ts" },
        .{ .path = "top.ts" },
    }, "app");
}

test "parity: walker built-in defaults mirror an explicit gitignore" {
    try expectWalkerParity(&.{
        .{ .path = ".gitignore", .data = gitignore.default_patterns },
        .{ .path = "node_modules/x.ts" },
        .{ .path = "dist/y.ts" },
        .{ .path = "src/ok.ts" },
    });
}
