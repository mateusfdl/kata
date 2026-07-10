const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const query = @import("core").query;

pub const Error = error{
    UnknownNodeKind,
    UnknownField,
    AnonymousWithChildren,
    TooManyCaptures,
} || std.mem.Allocator.Error;

/// A kata kind id no real node ever reports (ids live in `[0, kind_count)`), used
/// for a supertype reference so its pattern compiles yet never matches.
const unmatchable_kind: u16 = std.math.maxInt(u16);

/// A lowered match pattern plus its capture table: `capture_names[id]` is the
/// name bound to capture id `id`. tree-sitter no longer assigns capture ids, so
/// lowering assigns them by first occurrence.
pub const Lowered = struct {
    pattern: query.Pattern,
    capture_names: []const []const u8,

    pub fn idForName(self: Lowered, name: []const u8) ?query.CaptureId {
        for (self.capture_names, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, name)) return @intCast(i);
        }
        return null;
    }
};

pub const Lowerer = struct {
    arena: std.mem.Allocator,
    grammar: *const ts.Language,
    kind_remap: []const u16,
    field_remap: []const u16,
    captures: std.ArrayList([]const u8) = .empty,
    /// The offending kind or field name when lowering fails, for diagnostics.
    detail: []const u8 = "",

    pub fn init(
        arena: std.mem.Allocator,
        grammar: *const ts.Language,
        kind_remap: []const u16,
        field_remap: []const u16,
    ) Lowerer {
        return .{ .arena = arena, .grammar = grammar, .kind_remap = kind_remap, .field_remap = field_remap };
    }

    /// Resolve a grammar kind name to its kata kind id through the same remap the
    /// matcher reads at runtime, so a lowered pattern id equals the node id it is
    /// meant to match. A name the grammar does not know at all is a hard error. A
    /// supertype (a real grammar symbol, but excluded from the kata enum) remaps
    /// to 0; the matcher does not expand supertypes, so it lowers to a sentinel id
    /// no node ever reports, reproducing the old name matcher's silent no-match.
    fn kataKind(self: *Lowerer, name: []const u8, is_named: bool) Error!u16 {
        const sym = self.grammar.idForNodeKind(name, is_named);
        if (sym == 0 or sym >= self.kind_remap.len) return self.failKind(name);
        const id = self.kind_remap[sym];
        return if (id == 0) unmatchable_kind else id;
    }

    /// Resolve a grammar field name to its kata Field id through the same remap
    /// the converter applied to stored nodes, so a lowered relation id equals the
    /// `field_id` its target child reports. Fields have no aliases or supertypes,
    /// so a known field always remaps to a real nonzero id.
    fn kataField(self: *Lowerer, name: []const u8) Error!u16 {
        const sym = self.grammar.fieldIdForName(name);
        if (sym == 0 or sym >= self.field_remap.len) return self.failField(name);
        return self.field_remap[sym];
    }

    pub fn finish(self: *Lowerer, pattern: query.Pattern) Error!Lowered {
        return .{ .pattern = pattern, .capture_names = try self.captures.toOwnedSlice(self.arena) };
    }

    pub fn lowerPattern(self: *Lowerer, pattern: ast.NodePattern) Error!query.Pattern {
        const capture = if (pattern.capture) |c| try self.captureId(c.name) else null;

        switch (pattern.node_kind) {
            .symbol => |kind| {
                return .{
                    .kind = .{ .symbol = try self.kataKind(kind, true) },
                    .capture = capture,
                    .fields = try self.lowerFields(pattern.fields),
                    .absent_fields = try self.lowerAbsent(pattern.absent_fields),
                };
            },
            .anonymous => |token| {
                if (pattern.fields.len != 0 or pattern.absent_fields.len != 0) {
                    self.detail = token;
                    return error.AnonymousWithChildren;
                }
                return .{ .kind = .{ .anonymous = try self.kataKind(token, false) }, .capture = capture };
            },
            .alternation => |branches| {
                const lowered = try self.arena.alloc(query.Pattern, branches.len);
                for (branches, lowered) |branch, *slot| {
                    const merged = try withSharedFields(self.arena, branch, pattern.fields, pattern.absent_fields);
                    slot.* = try self.lowerPattern(merged);
                }
                return .{ .kind = .{ .alternation = lowered }, .capture = capture };
            },
        }
    }

    fn lowerFields(self: *Lowerer, fields: []const ast.FieldPattern) Error![]const query.Field {
        const out = try self.arena.alloc(query.Field, fields.len);
        for (fields, out) |field, *slot| {
            const relation: query.Relation = switch (field.relation) {
                .field => |name| .{ .field = try self.kataField(name) },
                .child => .child,
                .children => .children,
            };
            slot.* = .{ .relation = relation, .pattern = try self.lowerPattern(field.pattern) };
        }
        return out;
    }

    fn lowerAbsent(self: *Lowerer, absent: []const []const u8) Error![]const u16 {
        const out = try self.arena.alloc(u16, absent.len);
        for (absent, out) |name, *slot| {
            slot.* = try self.kataField(name);
        }
        return out;
    }

    fn captureId(self: *Lowerer, name: []const u8) Error!query.CaptureId {
        for (self.captures.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, name)) return @intCast(i);
        }
        if (self.captures.items.len > std.math.maxInt(query.CaptureId)) return error.TooManyCaptures;
        const id: query.CaptureId = @intCast(self.captures.items.len);
        try self.captures.append(self.arena, try self.arena.dupe(u8, name));
        return id;
    }

    fn failKind(self: *Lowerer, kind: []const u8) Error {
        self.detail = kind;
        return error.UnknownNodeKind;
    }

    fn failField(self: *Lowerer, name: []const u8) Error {
        self.detail = name;
        return error.UnknownField;
    }
};

/// Distribute an alternation's shared fields into a branch, mirroring how the
/// tree-sitter renderer pushed `[a b] c: (d)` down to `[(a c: (d)) (b c: (d))]`.
fn withSharedFields(
    arena: std.mem.Allocator,
    branch: ast.NodePattern,
    shared: []const ast.FieldPattern,
    shared_absent: []const []const u8,
) Error!ast.NodePattern {
    if (shared.len == 0 and shared_absent.len == 0) return branch;

    const fields = try arena.alloc(ast.FieldPattern, branch.fields.len + shared.len);
    @memcpy(fields[0..branch.fields.len], branch.fields);
    @memcpy(fields[branch.fields.len..], shared);

    const absent = try arena.alloc([]const u8, branch.absent_fields.len + shared_absent.len);
    @memcpy(absent[0..branch.absent_fields.len], branch.absent_fields);
    @memcpy(absent[branch.absent_fields.len..], shared_absent);

    return .{
        .node_kind = branch.node_kind,
        .capture = branch.capture,
        .fields = fields,
        .absent_fields = absent,
        .range = branch.range,
    };
}
