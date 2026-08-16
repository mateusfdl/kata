const std = @import("std");

const context_query = @import("context_query.zig");
const facts = @import("../facts.zig");
const fact_schema = @import("../fact_schema.zig");

const BoundFact = context_query.BoundFact;
const CaptureId = context_query.CaptureId;
const Context = context_query.Context;

pub const FieldOperand = struct {
    capture: CaptureId,
    field: fact_schema.Field,
};

pub const HelperOperand = struct {
    id: fact_schema.HelperId,
    capture: CaptureId,
};

pub const Operand = union(enum) {
    field: FieldOperand,
    literal: []const u8,
    helper: HelperOperand,

    pub fn resolve(self: Operand, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!?[]const u8 {
        return switch (self) {
            .literal => |s| s,
            .field => |field| if (bound(bindings, field.capture)) |fact| fact_schema.fieldValue(fact.fact, field.field, fact.file) else null,
            .helper => |helper| if (bound(bindings, helper.capture)) |fact| switch (helper.id) {
                .receiver_type => receiverType(ctx, fact),
                .resolved_import_source => try resolvedImportSource(ctx, fact),
            } else null,
        };
    }

    pub fn captureId(self: Operand) ?CaptureId {
        return switch (self) {
            .literal => null,
            .field => |field| field.capture,
            .helper => |helper| helper.capture,
        };
    }

    pub fn needsClassIndex(self: Operand) bool {
        return switch (self) {
            .helper => |helper| switch (helper.id) {
                inline else => |id| fact_schema.descriptor(id).needs_class_index,
            },
            .field, .literal => false,
        };
    }
};

fn bound(bindings: []?BoundFact, capture: CaptureId) ?BoundFact {
    if (capture >= bindings.len) return null;

    return bindings[capture];
}

fn receiverType(ctx: Context, bound_fact: BoundFact) ?[]const u8 {
    const call = switch (bound_fact.fact) {
        .call => |c| c,
        else => return null,
    };
    const resolved = facts.receiverType(bound_fact.file, call.receiver) orelse return null;
    if (!ctx.class_names.contains(resolved)) return null;

    return resolved;
}

fn resolvedImportSource(ctx: Context, bound_fact: BoundFact) std.mem.Allocator.Error!?[]const u8 {
    const im = switch (bound_fact.fact) {
        .import => |i| i,
        else => return null,
    };

    return facts.resolveImportSource(ctx.allocator, bound_fact.file.lang.family(), bound_fact.file.path, im.source);
}
