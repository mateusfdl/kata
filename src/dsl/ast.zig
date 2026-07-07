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
    alternation: []const NodePattern,
};

pub const KindPattern = struct {
    kind: []const u8,
    capture: ?Capture = null,
    range: tokenizer.Range,
};

pub const FieldPattern = struct {
    relation: PatternRelation,
    pattern: NodePattern,
    range: tokenizer.Range,
};

pub const PatternRelation = union(enum) {
    field: []const u8,
    child,
    children,
};

pub const Predicate = union(enum) {
    expression: Expression,
    composition: Composition,
    count: CountPredicate,
};

pub const Composition = struct {
    op: CompositionOp,
    negated: bool,
    matcher: NestedMatcher,
};

pub const CompositionOp = enum {
    inside,
    has,
    parent,
};

pub const CountPredicate = struct {
    matcher: NestedMatcher,
    op: CompareOp,
    value: u32,
};

pub const NestedMatcher = struct {
    subject: Capture,
    pattern: NodePattern,
    where: []const Expression = &.{},
    range: tokenizer.Range,
};

pub const Expression = union(enum) {
    capture: Capture,
    symbol: SymbolLiteral,
    string: StringLiteral,
    number: NumberLiteral,
    call: Call,
    compare: Compare,
    logical: Logical,
    negate: Negate,
    membership: Membership,
};

pub const Membership = struct {
    subject: *const Expression,
    values: []const StringLiteral,
    negated: bool,
    range: tokenizer.Range,
};

pub const SymbolLiteral = struct {
    name: []const u8,
    range: tokenizer.Range,
};

pub const StringLiteral = struct {
    value: []const u8,
    range: tokenizer.Range,
};

pub const NumberLiteral = struct {
    value: u32,
    range: tokenizer.Range,
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

pub const Negate = struct {
    expression: *const Expression,
    range: tokenizer.Range,
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
