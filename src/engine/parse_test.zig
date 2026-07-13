const std = @import("std");

const parse = @import("parse.zig");
const Node = @import("node.zig").Node;

test "parse: frontend produces a kata ast for each language" {
    var frontend = parse.Frontend.init(std.testing.allocator);
    defer frontend.deinit();

    var ts_ast = try frontend.tree("const a = 1;", .ts);
    defer ts_ast.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("program", Node.fromKata(&ts_ast, ts_ast.root()).kind());

    var tsx_ast = try frontend.tree("const a = <div />;", .tsx);
    defer tsx_ast.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("program", Node.fromKata(&tsx_ast, tsx_ast.root()).kind());

    var go_ast = try frontend.tree("package main", .go);
    defer go_ast.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("source_file", Node.fromKata(&go_ast, go_ast.root()).kind());
}

test "parse: frontend reuses one parser per language" {
    var frontend = parse.Frontend.init(std.testing.allocator);
    defer frontend.deinit();

    try frontend.ensure(.ts);
    const parser = frontend.parsers.get(.ts).?;

    var first = try frontend.tree("const a = 1;", .ts);
    first.deinit(std.testing.allocator);
    var second = try frontend.tree("const b = 2;", .ts);
    second.deinit(std.testing.allocator);

    try std.testing.expectEqual(parser, frontend.parsers.get(.ts).?);
}
