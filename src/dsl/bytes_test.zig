const std = @import("std");
const bytes = @import("bytes.zig");

const MessageToken = bytes.MessageToken;

fn scan(arena: std.mem.Allocator, msg: []const u8) !?[]const MessageToken {
    return bytes.scanMessage(arena, msg);
}

test "scanMessage: no braces returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(null, try scan(arena.allocator(), "hello world"));
}

test "scanMessage: empty string returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(null, try scan(arena.allocator(), ""));
}

test "scanMessage: single placeholder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = (try scan(arena.allocator(), "{field(@x, name)}")).?;
    try std.testing.expectEqual(1, tokens.len);
    try std.testing.expectEqualStrings("field(@x, name)", tokens[0].placeholder);
}

test "scanMessage: literal then placeholder then literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = (try scan(arena.allocator(), "found {lines(@match)} lines")).?;
    try std.testing.expectEqual(3, tokens.len);
    try std.testing.expectEqualStrings("found ", tokens[0].literal);
    try std.testing.expectEqualStrings("lines(@match)", tokens[1].placeholder);
    try std.testing.expectEqualStrings(" lines", tokens[2].literal);
}

test "scanMessage: escaped open brace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = (try scan(arena.allocator(), "use {{braces}}")).?;
    try std.testing.expectEqual(1, tokens.len);
    try std.testing.expectEqualStrings("use {braces}", tokens[0].literal);
}

test "scanMessage: multiple placeholders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = (try scan(arena.allocator(), "{a} and {b}")).?;
    try std.testing.expectEqual(3, tokens.len);
    try std.testing.expectEqualStrings("a", tokens[0].placeholder);
    try std.testing.expectEqualStrings(" and ", tokens[1].literal);
    try std.testing.expectEqualStrings("b", tokens[2].placeholder);
}

test "scanMessage: bare close brace is invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidPlaceholder, scan(arena.allocator(), "bad } here"));
}

test "scanMessage: unclosed open brace is invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidPlaceholder, scan(arena.allocator(), "bad {here"));
}

test "scanMessage: placeholder only with no surrounding text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = (try scan(arena.allocator(), "{x}")).?;
    try std.testing.expectEqual(1, tokens.len);
    try std.testing.expectEqualStrings("x", tokens[0].placeholder);
}
