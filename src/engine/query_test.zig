const std = @import("std");

const query = @import("query.zig");
const test_tree = @import("test_tree.zig");

const Node = @import("node.zig").Node;
const Pattern = query.Pattern;

test "query: symbol capture matches every occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "const a = b;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 0 };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].get(0).?.text(src).?);
    try std.testing.expectEqualStrings("b", matches[1].get(0).?.text(src).?);
}

test "query: field relation binds the field child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "const a = 1;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("variable_declarator") },
        .fields = &.{.{
            .relation = .{ .field = t.field("name") },
            .pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 0 },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].get(0).?.text(src).?);
}

test "query: unanchored child yields one match per satisfying child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "class C { foo() {} bar() {} }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("class_body") },
        .fields = &.{.{
            .relation = .child,
            .pattern = .{ .kind = .{ .symbol = t.sym("method_definition") }, .capture = 0 },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expect(std.mem.startsWith(u8, matches[0].get(0).?.text(src).?, "foo"));
    try std.testing.expect(std.mem.startsWith(u8, matches[1].get(0).?.text(src).?, "bar"));
}

test "query: alternation matches any branch kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "function f() {} const g = () => {};";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = t.sym("function_declaration") } },
            .{ .kind = .{ .symbol = t.sym("arrow_function") } },
        } },
        .capture = 0,
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "query: anonymous token under a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "const c = a && b;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("binary_expression") },
        .capture = 0,
        .fields = &.{.{
            .relation = .{ .field = t.field("operator") },
            .pattern = .{ .kind = .{ .anonymous = t.tok("&&") } },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a && b", matches[0].get(0).?.text(src).?);
}

test "query: symbols set matches any member kind with fields applied once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "class C {} abstract class D {} function f() {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    var members = [_]u16{ t.sym("class_declaration"), t.sym("abstract_class_declaration") };
    std.mem.sort(u16, &members, {}, std.sort.asc(u16));

    const pattern: Pattern = .{
        .kind = .{ .symbols = &members },
        .capture = 0,
        .fields = &.{.{
            .relation = .{ .field = t.field("name") },
            .pattern = .{ .kind = .{ .symbol = t.sym("type_identifier") }, .capture = 1 },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 2, t.root());

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expect(std.mem.startsWith(u8, matches[0].get(0).?.text(src).?, "class C"));
    try std.testing.expectEqualStrings("C", matches[0].get(1).?.text(src).?);
    try std.testing.expect(std.mem.startsWith(u8, matches[1].get(0).?.text(src).?, "abstract class D"));
    try std.testing.expectEqualStrings("D", matches[1].get(1).?.text(src).?);
}

test "query: absent field excludes nodes that have it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "let x; let y = 1;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("variable_declarator") },
        .capture = 0,
        .absent_fields = &.{t.field("value")},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("x", matches[0].get(0).?.text(src).?);
}

test "query: children relation rejects a child failing its nested constraint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "function f() { return 1; }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("statement_block") },
        .fields = &.{.{
            .relation = .children,
            .pattern = .{
                .kind = .{ .symbol = t.sym("return_statement") },
                .capture = 0,
                .fields = &.{.{
                    .relation = .child,
                    .pattern = .{ .kind = .{ .symbol = t.sym("call_expression") } },
                }},
            },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expect(matches[0].get(0) == null);
}

test "query: children relation binds a later child when an earlier one fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "function f() { return 1; return g(); }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("statement_block") },
        .fields = &.{.{
            .relation = .children,
            .pattern = .{
                .kind = .{ .symbol = t.sym("return_statement") },
                .capture = 0,
                .fields = &.{.{
                    .relation = .child,
                    .pattern = .{ .kind = .{ .symbol = t.sym("call_expression") } },
                }},
            },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("return g();", matches[0].get(0).?.text(src).?);
}

test "query: a repeated capture keeps its first binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "a + b;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("binary_expression") },
        .fields = &.{
            .{
                .relation = .{ .field = t.field("left") },
                .pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 0 },
            },
            .{
                .relation = .{ .field = t.field("right") },
                .pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 0 },
            },
        },
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].get(0).?.text(src).?);
}

test "query: stream stops enumeration when the sink requests it" {
    const src = "a; b; c;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 0 };

    const FirstOnly = struct {
        emits: usize = 0,

        pub fn emit(self: *@This(), bindings: []const ?Node) std.mem.Allocator.Error!query.ScanControl {
            _ = bindings;
            self.emits += 1;
            return .stop;
        }
    };
    var sink: FirstOnly = .{};
    try query.stream(std.testing.allocator, &pattern, 1, t.root(), &sink);

    try std.testing.expectEqual(@as(usize, 1), sink.emits);
}

test "query: stop exits alternation before the next branch" {
    const src = "a;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = t.sym("identifier") } },
            .{ .kind = .{ .symbol = t.sym("identifier") } },
        } },
        .capture = 0,
    };
    const FirstOnly = struct {
        emits: usize = 0,

        pub fn emit(self: *@This(), bindings: []const ?Node) std.mem.Allocator.Error!query.ScanControl {
            _ = bindings;
            self.emits += 1;
            return .stop;
        }
    };
    var sink: FirstOnly = .{};
    try query.stream(std.testing.allocator, &pattern, 1, t.root(), &sink);

    try std.testing.expectEqual(@as(usize, 1), sink.emits);
}

test "query: stop exits child enumeration before the next child" {
    const src = "class C { foo() {} bar() {} }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("class_body") },
        .fields = &.{.{
            .relation = .child,
            .pattern = .{ .kind = .{ .symbol = t.sym("method_definition") }, .capture = 0 },
        }},
    };
    const FirstOnly = struct {
        emits: usize = 0,

        pub fn emit(self: *@This(), bindings: []const ?Node) std.mem.Allocator.Error!query.ScanControl {
            _ = bindings;
            self.emits += 1;
            return .stop;
        }
    };
    var sink: FirstOnly = .{};
    try query.stream(std.testing.allocator, &pattern, 1, t.root(), &sink);

    try std.testing.expectEqual(@as(usize, 1), sink.emits);
}

test "query: streamAt only offers the anchored node" {
    const src = "a; b;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 0 };

    const Counter = struct {
        emits: usize = 0,

        pub fn emit(self: *@This(), bindings: []const ?Node) std.mem.Allocator.Error!query.ScanControl {
            _ = bindings;
            self.emits += 1;
            return .continue_scan;
        }
    };

    var root_sink: Counter = .{};
    try query.streamAt(std.testing.allocator, &pattern, 1, t.root(), &root_sink);
    try std.testing.expectEqual(@as(usize, 0), root_sink.emits);

    var nodes = t.root().preorder();
    var identifier: ?Node = null;
    while (nodes.next()) |candidate| {
        if (candidate.kindId() == t.sym("identifier")) {
            identifier = candidate;
            break;
        }
    }

    var identifier_sink: Counter = .{};
    try query.streamAt(std.testing.allocator, &pattern, 1, identifier.?, &identifier_sink);
    try std.testing.expectEqual(@as(usize, 1), identifier_sink.emits);
}
