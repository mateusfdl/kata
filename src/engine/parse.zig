const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const convert = @import("convert.zig");
const kind_map = @import("kind_map.zig");
const language = @import("language.zig");

/// The only place kata talks to tree-sitter at runtime: parser lifecycle,
/// remap tables, and the parse-then-clone step. tree-sitter is used only to
/// parse; nothing tree-sitter typed escapes this module.
pub const Frontend = struct {
    allocator: std.mem.Allocator,
    parsers: std.EnumArray(language.Name, ?*ts.Parser) = .initFill(null),
    kinds: std.EnumArray(language.Name, ?kind_map.Kinds) = .initFill(null),

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

    fn ensureKinds(self: *Frontend, lang: language.Name) !*const kind_map.Kinds {
        const slot = self.kinds.getPtr(lang);
        if (slot.*) |*cached| return cached;

        slot.* = try kind_map.build(lang.family(), language.grammar(lang), self.allocator);

        return &slot.*.?;
    }
};
