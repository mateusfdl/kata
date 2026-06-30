const tokenizer = @import("tokenizer.zig");

pub const File = struct {
    rules: []const Rule,
};

pub const Rule = struct {
    id: []const u8,
    kind: RuleKind = .local,
    languages: []const []const u8 = &.{},
    severity: Severity = .@"error",
    exclude_paths: []const []const u8 = &.{},
    match: ?Match = null,
    where: []const Predicate = &.{},
    emit: Emit,
    range: tokenizer.Range,
};

pub const RuleKind = enum {
    local,
    project,
};

pub const Severity = enum {
    @"error",
    warn,
};

pub const Match = union(enum) {
    node: NodePattern,
    kind: KindPattern,
};

pub const NodePattern = struct {
    node_kind: NodeKind,
    capture: ?Capture = null,
    fields: []const FieldPattern = &.{},
    range: tokenizer.Range,
};

pub const NodeKind = union(enum) {
    symbol: []const u8,
    anonymous: []const u8,
    alternation: []const []const u8,
};

pub const KindPattern = struct {
    kind: []const u8,
    capture: ?Capture = null,
    range: tokenizer.Range,
};

pub const FieldPattern = struct {
    name: []const u8,
    pattern: NodePattern,
    range: tokenizer.Range,
};

pub const Predicate = struct {
    expression: Expression,
    range: tokenizer.Range,
};

pub const Expression = union(enum) {
    capture: Capture,
    string: []const u8,
    number: u32,
    call: Call,
    compare: Compare,
    logical: Logical,
    negate: *const Expression,
};

pub const Call = struct {
    name: []const u8,
    args: []const Expression = &.{},
    range: tokenizer.Range,
};

pub const Compare = struct {
    op: CompareOp,
    left: *const Expression,
    right: *const Expression,
    range: tokenizer.Range,
};

pub const CompareOp = enum {
    eq,
    ne,
    gt,
    ge,
    lt,
    le,
};

pub const Logical = struct {
    op: LogicalOp,
    left: *const Expression,
    right: *const Expression,
    range: tokenizer.Range,
};

pub const LogicalOp = enum {
    @"and",
    @"or",
};

pub const Emit = struct {
    capture: Capture,
    message: []const u8,
    range: tokenizer.Range,
};

pub const Capture = struct {
    name: []const u8,
    range: tokenizer.Range,
};
