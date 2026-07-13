const std = @import("std");

const ast = @import("ast.zig");
const family = @import("engine").family;
const query = @import("engine").query;

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
    adapter: *const family.Adapter,
    captures: std.ArrayList([]const u8) = .empty,
    /// The offending kind or field name when lowering fails, for diagnostics.
    detail: []const u8 = "",

    pub fn init(arena: std.mem.Allocator, adapter: *const family.Adapter) Lowerer {
        return .{ .arena = arena, .adapter = adapter };
    }

    /// Resolve a named kind to the kind gate the matcher reads at runtime.
    /// A supertype expands to the sorted set of its transitive concrete member
    /// ids, precomputed by the node-kinds generator (the vendored grammars ship
    /// no runtime subtype map). A concrete kind lowers to its single kata id,
    /// which equals the id the converter stamped on matching nodes. A name
    /// unknown to the whole family is a hard error; a name belonging to only
    /// one dialect of the family lowers and never matches in the others.
    fn resolveKind(self: *Lowerer, name: []const u8) Error!query.Kind {
        if (self.supertypeMembers(name)) |members| return .{ .symbols = members };
        const id = self.adapter.kindId(name, true);
        if (id == 0) return self.failKind(name);
        return .{ .symbol = id };
    }

    fn supertypeMembers(self: *Lowerer, name: []const u8) ?[]const u16 {
        for (self.adapter.supertypes) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.members;
        }
        return null;
    }

    /// Resolve an anonymous token to its single kata kind id. Anonymous tokens
    /// are never supertypes; a token absent from the family is a hard error.
    fn kataAnonymous(self: *Lowerer, name: []const u8) Error!u16 {
        const id = self.adapter.kindId(name, false);
        if (id == 0) return self.failKind(name);
        return id;
    }

    /// Resolve a field name to its kata Field id, which equals the `field_id`
    /// its target child reports. Fields have no aliases or supertypes.
    fn kataField(self: *Lowerer, name: []const u8) Error!u16 {
        const id = self.adapter.fieldId(name);
        if (id == 0) return self.failField(name);
        return id;
    }

    /// Resolve a named grammar kind to the flat set of concrete kata kind ids it
    /// covers: a supertype yields its member set, a concrete kind yields itself.
    pub fn resolveKindMembers(self: *Lowerer, name: []const u8) Error![]const u16 {
        switch (try self.resolveKind(name)) {
            .symbols => |members| return members,
            .symbol => |id| {
                const out = try self.arena.alloc(u16, 1);
                out[0] = id;
                return out;
            },
            else => unreachable,
        }
    }

    pub fn finish(self: *Lowerer, pattern: query.Pattern) Error!Lowered {
        return .{ .pattern = pattern, .capture_names = try self.captures.toOwnedSlice(self.arena) };
    }

    pub fn lowerPattern(self: *Lowerer, pattern: ast.NodePattern) Error!query.Pattern {
        const capture = if (pattern.capture) |c| try self.captureId(c.name) else null;

        switch (pattern.node_kind) {
            .symbol => |kind| {
                return .{
                    .kind = try self.resolveKind(kind),
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
                return .{ .kind = .{ .anonymous = try self.kataAnonymous(token) }, .capture = capture };
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
