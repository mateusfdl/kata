const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("core").ast;
const convert = @import("convert.zig");
const kind_map = @import("core").kind_map;
const language = @import("core").language;
const node = @import("core").node;

/// A parsed-and-converted kata tree for tests: parse `source` with tree-sitter,
/// clone it into a flat `Ast`, and keep the remap tables so tests can author
/// kata kind ids. The caller owns it and must `deinit`.
pub const Tree = struct {
    lang: language.Name,
    ast: ast.Ast,
    kinds: kind_map.Kinds,

    pub fn root(self: *const Tree) node.Node {
        return node.Node.fromKata(&self.ast, self.ast.root());
    }

    pub fn sym(self: Tree, name: []const u8) u16 {
        return self.kinds.kind_remap[language.grammar(self.lang).idForNodeKind(name, true)];
    }

    pub fn tok(self: Tree, name: []const u8) u16 {
        return self.kinds.kind_remap[language.grammar(self.lang).idForNodeKind(name, false)];
    }

    pub fn field(self: Tree, name: []const u8) u16 {
        return self.kinds.field_remap[language.grammar(self.lang).fieldIdForName(name)];
    }

    pub fn deinit(self: *Tree, gpa: std.mem.Allocator) void {
        self.ast.deinit(gpa);
        gpa.free(self.kinds.kind_remap);
        gpa.free(self.kinds.field_remap);
    }
};

pub fn build(gpa: std.mem.Allocator, lang: language.Name, source: []const u8) Tree {
    const grammar = language.grammar(lang);
    const kinds = kind_map.build(lang, grammar, gpa) catch unreachable;

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(grammar) catch unreachable;
    const tree = parser.parseString(source, null).?;
    defer tree.destroy();

    const cloned = convert.build(lang, kinds.kind_remap, kinds.field_remap, tree.rootNode(), source, gpa) catch unreachable;
    return .{ .lang = lang, .ast = cloned, .kinds = kinds };
}
