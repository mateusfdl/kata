const std = @import("std");

const ast = @import("ast.zig");
const family = @import("family/family.zig");
const language = @import("language.zig");
const node = @import("node.zig");
const parse = @import("parse.zig");

/// A parsed-and-converted kata tree for tests, produced through the parse
/// frontend like production trees. The caller owns it and must `deinit`.
pub const Tree = struct {
    lang: language.Name,
    ast: ast.Ast,

    pub fn root(self: *const Tree) node.Node {
        return node.Node.fromKata(&self.ast, self.ast.root());
    }

    pub fn sym(self: Tree, name: []const u8) u16 {
        return family.of(self.lang.family()).kindId(name, true);
    }

    pub fn tok(self: Tree, name: []const u8) u16 {
        return family.of(self.lang.family()).kindId(name, false);
    }

    pub fn field(self: Tree, name: []const u8) u16 {
        return family.of(self.lang.family()).fieldId(name);
    }

    pub fn deinit(self: *Tree, gpa: std.mem.Allocator) void {
        self.ast.deinit(gpa);
    }
};

pub fn build(gpa: std.mem.Allocator, lang: language.Name, source: []const u8) Tree {
    var frontend = parse.Frontend.init(gpa);
    defer frontend.deinit();

    const cloned = frontend.tree(source, lang) catch unreachable;
    return .{ .lang = lang, .ast = cloned };
}
