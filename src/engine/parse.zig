const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const convert = @import("convert.zig");
const family_mod = @import("family/family.zig");
const language = @import("language.zig");

/// Per-grammar remap tables from tree-sitter symbol/field ids to kata ids, built
/// once per language and cached by the frontend. The converter applies them so
/// the flat `Ast` stores kata ids directly.
pub const Kinds = struct {
    kind_remap: []const u16,
    field_remap: []const u16,
};

pub fn buildKinds(
    fam: family_mod.Family,
    grammar: *const ts.Language,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!Kinds {
    const adapter = family_mod.of(fam);
    const kind_remap = try adapter.buildKindRemap(grammar, gpa);
    errdefer gpa.free(kind_remap);
    const field_remap = try adapter.buildFieldRemap(grammar, gpa);
    return .{ .kind_remap = kind_remap, .field_remap = field_remap };
}

/// The only place kata talks to tree-sitter at runtime: parser lifecycle,
/// remap tables, and the parse-then-clone step. tree-sitter is used only to
/// parse; nothing tree-sitter typed escapes this module.
pub const Frontend = struct {
    allocator: std.mem.Allocator,
    parsers: std.EnumArray(language.Name, ?*ts.Parser) = .initFill(null),
    kinds: std.EnumArray(language.Name, ?Kinds) = .initFill(null),

    pub fn init(allocator: std.mem.Allocator) Frontend {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Frontend) void {
        var pit = self.parsers.iterator();
        while (pit.next()) |entry| {
            if (entry.value.*) |parser| parser.destroy();
        }

        var kit = self.kinds.iterator();
        while (kit.next()) |entry| {
            if (entry.value.*) |k| {
                self.allocator.free(k.kind_remap);
                self.allocator.free(k.field_remap);
            }
        }
    }

    pub fn ensure(self: *Frontend, lang: language.Name) !void {
        _ = try self.ensureParser(lang);
        _ = try self.ensureKinds(lang);
    }

    pub fn tree(self: *Frontend, source: []const u8, lang: language.Name) !ast.Ast {
        const kinds = try self.ensureKinds(lang);
        const parser = try self.ensureParser(lang);
        const parsed = parser.parseString(source, null) orelse return error.ParseFailed;
        const cloned = convert.build(lang.family(), kinds.kind_remap, kinds.field_remap, parsed.rootNode(), source, self.allocator) catch |err| {
            parsed.destroy();
            return err;
        };
        parsed.destroy();
        return cloned;
    }

    fn ensureParser(self: *Frontend, lang: language.Name) !*ts.Parser {
        if (self.parsers.get(lang)) |cached| return cached;
        const parser = ts.Parser.create();
        errdefer parser.destroy();
        parser.setLanguage(language.grammar(lang)) catch return error.SetLanguageFailed;
        self.parsers.set(lang, parser);
        return parser;
    }

    fn ensureKinds(self: *Frontend, lang: language.Name) !*const Kinds {
        const slot = self.kinds.getPtr(lang);
        if (slot.*) |*cached| return cached;

        slot.* = try buildKinds(lang.family(), language.grammar(lang), self.allocator);

        return &slot.*.?;
    }
};
