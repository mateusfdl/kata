const std = @import("std");

const diagnostic = @import("../diagnostic.zig");
const fact_schema = @import("../fact_schema.zig");
const message_rule = @import("message_rule.zig");
const predicate_query = @import("predicate_query.zig");

pub const CompiledFactRule = struct {
    id: []const u8,
    fact: fact_schema.FactKind,
    capture_count: usize = 1,
    predicates: []const predicate_query.Predicate,
    message: []const message_rule.MessageSegment,
    severity: diagnostic.Severity = .@"error",
    maturity: diagnostic.Maturity = .stable,
    exclude_paths: []const []const u8 = &.{},
};

pub fn fieldFromString(name: []const u8) ?fact_schema.Field {
    return std.meta.stringToEnum(fact_schema.Field, name);
}
