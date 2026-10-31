const std = @import("std");

const lint = @import("engine");
const dsl = @import("dsl");
const loader = @import("loader.zig");

const diagnostic = lint.diagnostic;
const language = lint.language;

const Scope = struct {
    maturities: std.StringHashMapUnmanaged(diagnostic.Maturity) = .empty,
};

pub const Table = struct {
    arena: std.mem.Allocator,
    by_lang: std.EnumArray(language.Name, Scope) = .initFill(.{}),
    project: Scope = .{},

    pub fn maturityOf(self: *const Table, scope: ?language.Name, id: []const u8) diagnostic.Maturity {
        return self.scopeOf(scope).maturities.get(id) orelse .stable;
    }

    fn scopeOf(self: *const Table, scope: ?language.Name) *const Scope {
        return if (scope) |lang| self.by_lang.getPtrConst(lang) else &self.project;
    }

    fn scopeMut(self: *Table, scope: ?language.Name) *Scope {
        return if (scope) |lang| self.by_lang.getPtr(lang) else &self.project;
    }
};

pub fn build(arena: std.mem.Allocator, rule_set: *const loader.RuleSet) error{OutOfMemory}!Table {
    var table = Table{ .arena = arena };

    for (std.enums.values(language.Name)) |lang| {
        for (rule_set.get(lang)) |raw| {
            try registerRule(&table, lang, raw);
        }
    }
    for (rule_set.projectRaws()) |raw| {
        try registerRule(&table, null, raw);
    }

    return table;
}

fn registerRule(table: *Table, scope: ?language.Name, raw: lint.rule.RawRule) error{OutOfMemory}!void {
    const parsed = parseRule(table.arena, raw.source) orelse return;

    try table.scopeMut(scope).maturities.put(table.arena, raw.id, switch (parsed.maturity) {
        .experimental => .experimental,
        .stable => .stable,
        .deprecated => .deprecated,
    });
}

fn parseRule(arena: std.mem.Allocator, source: []const u8) ?dsl.ast.Rule {
    var parse_diag: dsl.parser.Diagnostic = .{};
    var p = dsl.parser.Parser.init(arena, source, &parse_diag) catch return null;
    const file = p.parseFile() catch return null;

    return file.rules[0];
}
