const std = @import("std");

const expression_open: u8 = '(';
const expression_close: u8 = ')';
const capture_marker: u8 = '@';

pub const Measure = enum {
    complexity,
    nesting,
    length,
    text,
    params,
    args,
    position,
    siblings,

    pub fn fromString(s: []const u8) ?Measure {
        return std.meta.stringToEnum(Measure, s);
    }
};

pub const Compare = enum {
    gt,
    ge,
    lt,
    le,
    eq,
    ne,

    pub fn fromString(name: []const u8) ?Compare {
        inline for (std.meta.fields(Compare)) |field| {
            const compare: Compare = @enumFromInt(field.value);
            if (std.mem.eql(u8, name, compare.toString())) return compare;
        }

        return null;
    }

    pub fn toString(self: Compare) []const u8 {
        return switch (self) {
            .gt => ">",
            .ge => ">=",
            .lt => "<",
            .le => "<=",
            .eq => "=",
            .ne => "!=",
        };
    }
};

const LogicalOp = enum {
    @"and",
    @"or",
    not,

    fn fromString(name: []const u8) ?LogicalOp {
        return std.meta.stringToEnum(LogicalOp, name);
    }
};

pub const Term = union(enum) {
    number: u32,
    measure: struct { measure: Measure, capture_id: u32 },
};

pub const Expr = union(enum) {
    compare: struct { op: Compare, left: Term, right: Term },
    all: []const Expr,
    any: []const Expr,
    negate: *const Expr,
};

const Token = union(enum) {
    open,
    close,
    atom: []const u8,
};

const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,

    fn next(self: *Tokenizer) ?Token {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) self.pos += 1;
        if (self.pos >= self.source.len) return null;

        switch (self.source[self.pos]) {
            expression_open => {
                self.pos += 1;

                return .open;
            },
            expression_close => {
                self.pos += 1;

                return .close;
            },
            else => {
                const start = self.pos;

                while (self.pos < self.source.len) : (self.pos += 1) {
                    const c = self.source[self.pos];

                    if (std.ascii.isWhitespace(c) or c == expression_open or c == expression_close) break;
                }

                return .{ .atom = self.source[start..self.pos] };
            },
        }
    }
};

pub fn captureName(atom: []const u8) ?[]const u8 {
    if (atom.len < 2 or atom[0] != capture_marker) return null;
    return atom[1..];
}

pub const ParseError = error{
    MalformedExpression,
    UnknownOperator,
    UnknownMeasure,
    UnknownCapture,
    InvalidNumber,
} || std.mem.Allocator.Error;

pub fn parse(
    arena: std.mem.Allocator,
    source: []const u8,
    resolver: anytype,
) ParseError!*const Expr {
    var tokens: Tokenizer = .{ .source = source };

    try expectOpen(&tokens);

    const parsed = try parseForm(arena, &tokens, resolver);

    if (tokens.next() != null) return error.MalformedExpression;

    const root = try arena.create(Expr);
    root.* = parsed;

    return root;
}

pub fn evaluate(root: *const Expr, measures: anytype) @TypeOf(measures).Error!bool {
    switch (root.*) {
        .compare => |c| {
            const left = (try resolveTerm(c.left, measures)) orelse return false;
            const right = (try resolveTerm(c.right, measures)) orelse return false;

            return switch (c.op) {
                .gt => left > right,
                .ge => left >= right,
                .lt => left < right,
                .le => left <= right,
                .eq => left == right,
                .ne => left != right,
            };
        },
        .all => |items| {
            for (items) |*item| {
                if (!try evaluate(item, measures)) return false;
            }

            return true;
        },
        .any => |items| {
            for (items) |*item| {
                if (try evaluate(item, measures)) return true;
            }

            return false;
        },
        .negate => |inner| return !try evaluate(inner, measures),
    }
}

fn resolveTerm(term: Term, measures: anytype) @TypeOf(measures).Error!?u32 {
    return switch (term) {
        .number => |n| n,
        .measure => |m| try measures.measure(m.measure, m.capture_id),
    };
}

fn parseForm(arena: std.mem.Allocator, tokens: *Tokenizer, resolver: anytype) ParseError!Expr {
    const head = try expectAtom(tokens);

    if (Compare.fromString(head)) |op| {
        const left = try parseTerm(tokens, resolver);
        const right = try parseTerm(tokens, resolver);
        try expectClose(tokens);
        return .{ .compare = .{ .op = op, .left = left, .right = right } };
    }

    return switch (LogicalOp.fromString(head) orelse return error.UnknownOperator) {
        .@"and" => .{ .all = try parseList(arena, tokens, resolver) },
        .@"or" => .{ .any = try parseList(arena, tokens, resolver) },
        .not => blk: {
            try expectOpen(tokens);
            const inner = try arena.create(Expr);
            inner.* = try parseForm(arena, tokens, resolver);
            try expectClose(tokens);
            break :blk .{ .negate = inner };
        },
    };
}

fn parseList(arena: std.mem.Allocator, tokens: *Tokenizer, resolver: anytype) ParseError![]const Expr {
    var items: std.ArrayList(Expr) = .empty;
    while (true) {
        const token = tokens.next() orelse return error.MalformedExpression;

        switch (token) {
            .close => break,
            .open => try items.append(arena, try parseForm(arena, tokens, resolver)),
            .atom => return error.MalformedExpression,
        }
    }

    if (items.items.len == 0) return error.MalformedExpression;

    return items.toOwnedSlice(arena);
}

fn parseTerm(tokens: *Tokenizer, resolver: anytype) ParseError!Term {
    const token = tokens.next() orelse return error.MalformedExpression;
    switch (token) {
        .open => {
            const name = try expectAtom(tokens);
            const measure = Measure.fromString(name) orelse return error.UnknownMeasure;
            const capture = try expectAtom(tokens);
            const capture_name = captureName(capture) orelse return error.MalformedExpression;
            const id = resolver.captureId(capture_name) orelse return error.UnknownCapture;

            try expectClose(tokens);

            return .{ .measure = .{ .measure = measure, .capture_id = id } };
        },
        .atom => |a| return .{ .number = std.fmt.parseInt(u32, a, 10) catch return error.InvalidNumber },
        .close => return error.MalformedExpression,
    }
}

fn expectAtom(tokens: *Tokenizer) ParseError![]const u8 {
    const token = tokens.next() orelse return error.MalformedExpression;

    return switch (token) {
        .atom => |a| a,
        else => error.MalformedExpression,
    };
}

fn expectOpen(tokens: *Tokenizer) ParseError!void {
    const token = tokens.next() orelse return error.MalformedExpression;

    if (token != .open) return error.MalformedExpression;
}

fn expectClose(tokens: *Tokenizer) ParseError!void {
    const token = tokens.next() orelse return error.MalformedExpression;

    if (token != .close) return error.MalformedExpression;
}
