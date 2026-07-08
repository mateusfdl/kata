const std = @import("std");

const facts = @import("facts.zig");
const test_fixture = @import("../test_fixture.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

const Fixture = test_fixture.Fixture;

const comment_rule =
    \\rule no-comments {
    \\  lang ts, tsx, go
    \\  match comment @match
    \\  emit @match { message "no comments" }
    \\}
;

test "facts: ts extraction covers classes, methods, decls, calls, and imports" {
    const gpa = std.testing.allocator;
    var f = try Fixture.initFormat(gpa, &.{.ts}, "no-comments", comment_rule, .kata);
    defer f.deinit();

    const src =
        "import { UserRepository } from \"./user-repository\";\n" ++
        "\n" ++
        "class OrderService {\n" ++
        "  private repo: UserRepository;\n" ++
        "\n" ++
        "  constructor(repo: UserRepository) {\n" ++
        "    this.repo = repo;\n" ++
        "    this.cache = new Cache();\n" ++
        "  }\n" ++
        "\n" ++
        "  create(order: Order) {\n" ++
        "    this.repo.save(order);\n" ++
        "    const local = new UserRepository();\n" ++
        "    local.find(1);\n" ++
        "  }\n" ++
        "}\n" ++
        "\n" ++
        "function helper(repo: UserRepository) {\n" ++
        "  repo.find(2);\n" ++
        "}\n";

    var ff = try f.engine.extractFacts(gpa, src, .ts, "src/order-service.ts");
    defer ff.deinit();

    try std.testing.expectEqualStrings("src/order-service.ts", ff.path);

    try std.testing.expectEqual(@as(usize, 1), ff.classes.len);
    try std.testing.expectEqualStrings("OrderService", ff.classes[0].name);
    try std.testing.expectEqual(@as(u32, 2), ff.classes[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 0), ff.classes[0].range.start.column);

    try std.testing.expectEqual(@as(usize, 2), ff.methods.len);
    try std.testing.expectEqualStrings("constructor", ff.methods[0].name);
    try std.testing.expectEqualStrings("OrderService", ff.methods[0].container);
    try std.testing.expectEqual(@as(u32, 5), ff.methods[0].range.start.line);
    try std.testing.expectEqualStrings("create", ff.methods[1].name);
    try std.testing.expectEqualStrings("OrderService", ff.methods[1].container);
    try std.testing.expectEqual(@as(u32, 10), ff.methods[1].range.start.line);

    const expected_decls = [_]struct { name: []const u8, type_name: []const u8, line: u32 }{
        .{ .name = "repo", .type_name = "UserRepository", .line = 3 },
        .{ .name = "repo", .type_name = "UserRepository", .line = 5 },
        .{ .name = "cache", .type_name = "Cache", .line = 7 },
        .{ .name = "order", .type_name = "Order", .line = 10 },
        .{ .name = "local", .type_name = "UserRepository", .line = 12 },
        .{ .name = "repo", .type_name = "UserRepository", .line = 17 },
    };
    try std.testing.expectEqual(expected_decls.len, ff.typed_decls.len);
    for (expected_decls, ff.typed_decls) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.type_name, got.type_name);
        try std.testing.expectEqual(want.line, got.range.start.line);
    }

    const expected_calls = [_]struct { receiver: []const u8, method: []const u8, container: []const u8, line: u32 }{
        .{ .receiver = "repo", .method = "save", .container = "OrderService", .line = 11 },
        .{ .receiver = "local", .method = "find", .container = "OrderService", .line = 13 },
        .{ .receiver = "repo", .method = "find", .container = "", .line = 18 },
    };
    try std.testing.expectEqual(expected_calls.len, ff.calls.len);
    for (expected_calls, ff.calls) |want, got| {
        try std.testing.expectEqualStrings(want.receiver, got.receiver);
        try std.testing.expectEqualStrings(want.method, got.method);
        try std.testing.expectEqualStrings(want.container, got.container);
        try std.testing.expectEqual(want.line, got.range.start.line);
    }

    try std.testing.expectEqual(@as(usize, 1), ff.imports.len);
    try std.testing.expectEqualStrings("UserRepository", ff.imports[0].name);
    try std.testing.expectEqualStrings("./user-repository", ff.imports[0].source);
    try std.testing.expectEqual(@as(u32, 0), ff.imports[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 32), ff.imports[0].range.start.column);
}

test "facts: go extraction covers types, methods, decls, calls, and imports" {
    const gpa = std.testing.allocator;
    var f = try Fixture.initFormat(gpa, &.{.go}, "no-comments", comment_rule, .kata);
    defer f.deinit();

    const src =
        "package main\n" ++
        "\n" ++
        "import \"example.com/repo\"\n" ++
        "\n" ++
        "type UserRepository struct{}\n" ++
        "\n" ++
        "func (r *UserRepository) Find(id int) {}\n" ++
        "\n" ++
        "type OrderService struct {\n" ++
        "\trepo UserRepository\n" ++
        "}\n" ++
        "\n" ++
        "func (s *OrderService) Create() {\n" ++
        "\ts.repo.Save()\n" ++
        "\tr := NewUserRepository()\n" ++
        "\tr.Find(1)\n" ++
        "\tu := &UserRepository{}\n" ++
        "\tu.Find(2)\n" ++
        "}\n";

    var ff = try f.engine.extractFacts(gpa, src, .go, "internal/order/service.go");
    defer ff.deinit();

    try std.testing.expectEqual(@as(usize, 2), ff.classes.len);
    try std.testing.expectEqualStrings("UserRepository", ff.classes[0].name);
    try std.testing.expectEqual(@as(u32, 4), ff.classes[0].range.start.line);
    try std.testing.expectEqualStrings("OrderService", ff.classes[1].name);
    try std.testing.expectEqual(@as(u32, 8), ff.classes[1].range.start.line);

    try std.testing.expectEqual(@as(usize, 2), ff.methods.len);
    try std.testing.expectEqualStrings("Find", ff.methods[0].name);
    try std.testing.expectEqualStrings("UserRepository", ff.methods[0].container);
    try std.testing.expectEqualStrings("Create", ff.methods[1].name);
    try std.testing.expectEqualStrings("OrderService", ff.methods[1].container);

    const expected_decls = [_]struct { name: []const u8, type_name: []const u8, line: u32 }{
        .{ .name = "r", .type_name = "UserRepository", .line = 6 },
        .{ .name = "id", .type_name = "int", .line = 6 },
        .{ .name = "repo", .type_name = "UserRepository", .line = 9 },
        .{ .name = "s", .type_name = "OrderService", .line = 12 },
        .{ .name = "r", .type_name = "UserRepository", .line = 14 },
        .{ .name = "u", .type_name = "UserRepository", .line = 16 },
    };
    try std.testing.expectEqual(expected_decls.len, ff.typed_decls.len);
    for (expected_decls, ff.typed_decls) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.type_name, got.type_name);
        try std.testing.expectEqual(want.line, got.range.start.line);
    }

    const expected_calls = [_]struct { receiver: []const u8, method: []const u8, container: []const u8, line: u32 }{
        .{ .receiver = "repo", .method = "Save", .container = "OrderService", .line = 13 },
        .{ .receiver = "r", .method = "Find", .container = "OrderService", .line = 15 },
        .{ .receiver = "u", .method = "Find", .container = "OrderService", .line = 17 },
    };
    try std.testing.expectEqual(expected_calls.len, ff.calls.len);
    for (expected_calls, ff.calls) |want, got| {
        try std.testing.expectEqualStrings(want.receiver, got.receiver);
        try std.testing.expectEqualStrings(want.method, got.method);
        try std.testing.expectEqualStrings(want.container, got.container);
        try std.testing.expectEqual(want.line, got.range.start.line);
    }

    try std.testing.expectEqual(@as(usize, 1), ff.imports.len);
    try std.testing.expectEqualStrings("", ff.imports[0].name);
    try std.testing.expectEqualStrings("example.com/repo", ff.imports[0].source);
}

test "facts: multi-name short var declarations bind only the first name" {
    const gpa = std.testing.allocator;
    var f = try Fixture.initFormat(gpa, &.{.go}, "no-comments", comment_rule, .kata);
    defer f.deinit();

    const src =
        "package main\n" ++
        "func f() {\n" ++
        "\tr, err := NewUserRepository()\n" ++
        "\t_ = err\n" ++
        "\t_ = r\n" ++
        "}\n";

    var ff = try f.engine.extractFacts(gpa, src, .go, "main.go");
    defer ff.deinit();

    try std.testing.expectEqual(@as(usize, 1), ff.typed_decls.len);
    try std.testing.expectEqualStrings("r", ff.typed_decls[0].name);
    try std.testing.expectEqualStrings("UserRepository", ff.typed_decls[0].type_name);
}

test "facts: non-constructor call initializers are not typed decls" {
    const gpa = std.testing.allocator;
    var f = try Fixture.initFormat(gpa, &.{.go}, "no-comments", comment_rule, .kata);
    defer f.deinit();

    const src =
        "package main\n" ++
        "func f() {\n" ++
        "\tx := compute()\n" ++
        "\t_ = x\n" ++
        "}\n";

    var ff = try f.engine.extractFacts(gpa, src, .go, "main.go");
    defer ff.deinit();

    try std.testing.expectEqual(@as(usize, 0), ff.typed_decls.len);
}

test "facts: project index replaces entries by path" {
    const gpa = std.testing.allocator;
    var f = try Fixture.initFormat(gpa, &.{.ts}, "no-comments", comment_rule, .kata);
    defer f.deinit();

    var index = ProjectIndex.init(gpa);
    defer index.deinit();

    try index.put(try f.engine.extractFacts(gpa, "class A {}", .ts, "src/a.ts"));
    try index.put(try f.engine.extractFacts(gpa, "class B {}", .ts, "src/a.ts"));
    try index.put(try f.engine.extractFacts(gpa, "class C {}", .ts, "src/c.ts"));

    try std.testing.expectEqual(@as(usize, 2), index.count());
    const a = index.get("src/a.ts").?;
    try std.testing.expectEqual(@as(usize, 1), a.classes.len);
    try std.testing.expectEqualStrings("B", a.classes[0].name);
    const c = index.get("src/c.ts").?;
    try std.testing.expectEqualStrings("C", c.classes[0].name);
    try std.testing.expectEqual(@as(?*const facts.FileFacts, null), index.get("src/missing.ts"));
}
