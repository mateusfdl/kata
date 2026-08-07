const std = @import("std");

const query = @import("query.zig");
const test_fixture = @import("../test_fixture.zig");

const as_any_query =
    \\rule query {
    \\  lang ts, tsx
    \\  match as_expression @match {
    \\    child: predefined_type @t
    \\  }
    \\  where { text(@t) == "any" }
    \\  emit @match { message "found as any" }
    \\}
;

const complexity_query =
    \\rule query {
    \\  lang ts
    \\  match function_declaration @match
    \\  where { complexity(@match) > 2 }
    \\  emit @match { message "complexity {complexity(@match)} exceeds 2" }
    \\}
;

const Result = struct {
    outcome: query.Outcome,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runQuery(allocator: std.mem.Allocator, opts: query.Options) !Result {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(allocator);
    errdefer err_out.deinit();

    const outcome = try query.run(std.testing.io, allocator, opts, &out.writer, &err_out.writer);

    return .{
        .outcome = outcome,
        .stdout = try out.toOwnedSlice(),
        .stderr = try err_out.toOwnedSlice(),
    };
}

test "query: inline rule matches in a file target" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const target = try std.fmt.allocPrint(gpa, "{s}/a.ts", .{rel});
    defer gpa.free(target);

    const r = try runQuery(gpa, .{ .text = as_any_query, .target = target, .lang = "ts", .format = .text });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.matches, r.outcome);
    const expected = try std.fmt.allocPrint(
        gpa,
        "{s}:1:11 [query] found as any\nchecked 1 files, 1 violations, 0 warnings\n",
        .{target},
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, r.stdout);
}

test "query: where predicate and interpolation across a directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "complex.ts",
        .data = "function f(a: number) {\n" ++
            "  if (a > 1) { return 1; }\n" ++
            "  if (a > 2) { return 2; }\n" ++
            "  if (a > 3) { return 3; }\n" ++
            "  return 0;\n" ++
            "}\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "simple.ts", .data = "function g() { return 0; }\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    const r = try runQuery(gpa, .{ .text = complexity_query, .target = rel, .lang = "ts", .format = .text });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.matches, r.outcome);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "complex.ts:1:1 [query] complexity 4 exceeds 2") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, r.stdout, "simple.ts"));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "checked 2 files, 1 violations, 0 warnings") != null);
}

test "query: clean when nothing matches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x: string = \"ok\";\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const target = try std.fmt.allocPrint(gpa, "{s}/a.ts", .{rel});
    defer gpa.free(target);

    const r = try runQuery(gpa, .{ .text = as_any_query, .target = target, .lang = "ts", .format = .text });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.clean, r.outcome);
    try std.testing.expectEqualStrings("checked 1 files, 0 violations, 0 warnings\n", r.stdout);
}

test "query: comma-separated languages apply to each" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.tsx", .data = "const y = bar as any;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    const r = try runQuery(gpa, .{ .text = as_any_query, .target = rel, .lang = "ts,tsx", .format = .text });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.matches, r.outcome);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a.ts:1:11 [query] found as any") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "b.tsx:1:11 [query] found as any") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "checked 2 files, 2 violations, 0 warnings") != null);
}

test "query: duplicate languages are deduplicated" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const x = foo as any;\n" });

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    const r = try runQuery(gpa, .{ .text = as_any_query, .target = rel, .lang = "ts,ts", .format = .text });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.matches, r.outcome);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "checked 1 files, 1 violations, 0 warnings") != null);
}

test "query: unsupported language in a list is usage" {
    const gpa = std.testing.allocator;

    const r = try runQuery(gpa, .{ .text = as_any_query, .target = ".", .lang = "ts,python" });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.usage, r.outcome);
    try std.testing.expectEqualStrings("kata query: unsupported language: \"python\" (expected ts, tsx, or go)\n", r.stderr);
}

test "query: missing --lang is usage" {
    const gpa = std.testing.allocator;

    const r = try runQuery(gpa, .{ .text = as_any_query, .target = ".", .lang = "" });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.usage, r.outcome);
    try std.testing.expectEqualStrings("kata query: --lang is required (expected ts, tsx, or go)\n", r.stderr);
}

test "query: unsupported --lang is usage" {
    const gpa = std.testing.allocator;

    const r = try runQuery(gpa, .{ .text = as_any_query, .target = ".", .lang = "python" });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.usage, r.outcome);
    try std.testing.expectEqualStrings("kata query: unsupported language: \"python\" (expected ts, tsx, or go)\n", r.stderr);
}

test "query: empty query text is usage" {
    const gpa = std.testing.allocator;

    const r = try runQuery(gpa, .{ .text = "", .target = ".", .lang = "ts" });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.usage, r.outcome);
    try std.testing.expectEqualStrings("usage: kata query '<kata rule>' [path] --lang=<ts|tsx|go>\n", r.stderr);
}

test "query: invalid query text is usage" {
    const gpa = std.testing.allocator;

    const r = try runQuery(gpa, .{
        .text =
        \\rule query {
        \\  lang ts
        \\  match nonexistent_node @match
        \\  emit @match { message "x" }
        \\}
        ,
        .target = ".",
        .lang = "ts",
    });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.usage, r.outcome);
    try std.testing.expectEqualStrings("kata: rule ts/query: node kind or field is invalid for the grammar\n", r.stderr);
}

test "query: stray argument reports a quoting hint" {
    const gpa = std.testing.allocator;

    const r = try runQuery(gpa, .{ .text = "((comment)", .target = ".", .lang = "ts", .invalid_arg = "@match)" });
    defer r.deinit(gpa);

    try std.testing.expectEqual(query.Outcome.usage, r.outcome);
    try std.testing.expectEqualStrings("kata query: unexpected argument \"@match)\" (is the query quoted?)\n", r.stderr);
}
