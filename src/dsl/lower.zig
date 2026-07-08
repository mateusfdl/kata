const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const query = @import("../lint/query.zig");

pub const Error = error{
    UnknownNodeKind,
    UnknownField,
    AnonymousWithChildren,
    TooManyCaptures,
} || std.mem.Allocator.Error;

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
    captures: std.ArrayList([]const u8) = .empty,
    /// The offending kind or field name when lowering fails, for diagnostics.
    detail: []const u8 = "",

    pub fn init(arena: std.mem.Allocator, grammar: *const ts.Language) Lowerer {
        return .{ .arena = arena, .grammar = grammar };
    }

    pub fn finish(self: *Lowerer, pattern: query.Pattern) Error!Lowered {
        return .{ .pattern = pattern, .capture_names = try self.captures.toOwnedSlice(self.arena) };
    }

    pub fn lowerPattern(self: *Lowerer, pattern: ast.NodePattern) Error!query.Pattern {
        const capture = if (pattern.capture) |c| try self.captureId(c.name) else null;

        switch (pattern.node_kind) {
            .symbol => |kind| {
                if (self.grammar.idForNodeKind(kind, true) == 0) return self.failKind(kind);
                return .{
                    .kind = .{ .symbol = try self.arena.dupe(u8, kind) },
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
                if (self.grammar.idForNodeKind(token, false) == 0) return self.failKind(token);
                return .{ .kind = .{ .anonymous = try self.arena.dupe(u8, token) }, .capture = capture };
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
                .field => |name| blk: {
                    if (self.grammar.fieldIdForName(name) == 0) return self.failField(name);
                    break :blk .{ .field = try self.arena.dupe(u8, name) };
                },
                .child => .child,
                .children => .children,
            };
            slot.* = .{ .relation = relation, .pattern = try self.lowerPattern(field.pattern) };
        }
        return out;
    }

    fn lowerAbsent(self: *Lowerer, absent: []const []const u8) Error![]const []const u8 {
        const out = try self.arena.alloc([]const u8, absent.len);
        for (absent, out) |name, *slot| {
            if (self.grammar.fieldIdForName(name) == 0) return self.failField(name);
            slot.* = try self.arena.dupe(u8, name);
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
