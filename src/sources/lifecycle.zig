const std = @import("std");

const lint = @import("engine");
const dsl = @import("dsl");
const loader = @import("loader.zig");
const retired = @import("retired.zig");

const diagnostic = lint.diagnostic;
const language = lint.language;

pub const Error = error{ OutOfMemory, LifecycleCollision };

pub const Resolution = union(enum) {
    unchanged,
    renamed: []const u8,
    removed: []const u8,
};

const Scope = struct {
    live: std.StringHashMapUnmanaged(void) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    maturities: std.StringHashMapUnmanaged(diagnostic.Maturity) = .empty,
};

pub const Table = struct {
    arena: std.mem.Allocator,
    by_lang: std.EnumArray(language.Name, Scope) = .initFill(.{}),
    project: Scope = .{},
    retired: retired.Registry = .empty,

    pub fn resolve(self: *const Table, scope: ?language.Name, id: []const u8) Resolution {
        const maps = self.scopeOf(scope);
        if (maps.live.contains(id)) return .unchanged;
        if (maps.aliases.get(id)) |canonical| return .{ .renamed = canonical };
        if (self.retired.get(id)) |entry| {
            return switch (entry) {
                .replaced => |canonical| .{ .renamed = canonical },
                .removed => |reason| .{ .removed = reason },
            };
        }

        return .unchanged;
    }

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

pub fn build(arena: std.mem.Allocator, rule_set: *const loader.RuleSet, diag: *lint.rule.Diagnostic) Error!Table {
    var table = Table{ .arena = arena };

    for (std.enums.values(language.Name)) |lang| {
        for (rule_set.get(lang)) |raw| {
            try table.scopeMut(lang).live.put(arena, raw.id, {});
        }
    }
    for (rule_set.projectRaws()) |raw| {
        try table.project.live.put(arena, raw.id, {});
    }

    for (std.enums.values(language.Name)) |lang| {
        for (rule_set.get(lang)) |raw| {
            try registerRule(&table, lang, raw, diag);
        }
    }
    for (rule_set.projectRaws()) |raw| {
        try registerRule(&table, null, raw, diag);
    }

    return table;
}

fn registerRule(table: *Table, scope: ?language.Name, raw: lint.rule.RawRule, diag: *lint.rule.Diagnostic) Error!void {
    const parsed = parseRule(table.arena, raw.source) orelse return;
    const maps = table.scopeMut(scope);

    try maps.maturities.put(table.arena, raw.id, switch (parsed.maturity) {
        .experimental => .experimental,
        .stable => .stable,
        .deprecated => .deprecated,
    });

    for (parsed.former_ids) |former| {
        if (maps.live.contains(former)) {
            diag.* = .{
                .lang = scope,
                .rule_id = raw.id,
                .detail = try std.fmt.allocPrint(table.arena, "former id '{s}' is a live rule id", .{former}),
            };

            return error.LifecycleCollision;
        }

        const entry = try maps.aliases.getOrPut(table.arena, former);
        if (entry.found_existing) {
            diag.* = .{
                .lang = scope,
                .rule_id = raw.id,
                .detail = try std.fmt.allocPrint(table.arena, "former id '{s}' already claimed by rule '{s}'", .{ former, entry.value_ptr.* }),
            };

            return error.LifecycleCollision;
        }

        entry.value_ptr.* = raw.id;
    }
}

fn parseRule(arena: std.mem.Allocator, source: []const u8) ?dsl.ast.Rule {
    var parse_diag: dsl.parser.Diagnostic = .{};
    var p = dsl.parser.Parser.init(arena, source, &parse_diag) catch return null;
    const file = p.parseFile() catch return null;

    return file.rules[0];
}
