const std = @import("std");
const ts = @import("tree_sitter");

const rule = @import("rule.zig");

pub fn evaluate(
    predicates: []const rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
) bool {
    for (predicates) |pred| {
        switch (pred.op) {
            .eq => if (!evalEq(pred, match, source, false)) return false,
            .not_eq => if (!evalEq(pred, match, source, true)) return false,
            .any_of => if (!evalAnyOf(pred, match, source, false)) return false,
            .not_any_of => if (!evalAnyOf(pred, match, source, true)) return false,
            .unknown => {},
        }
    }
    return true;
}

fn evalEq(
    pred: rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    if (pred.args.len != 2) return false;
    const left_text = resolveText(pred.args[0], match, source) orelse return false;
    const right_text = resolveText(pred.args[1], match, source) orelse return false;
    return std.mem.eql(u8, left_text, right_text) != negate;
}

fn evalAnyOf(
    pred: rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    if (pred.args.len < 2) return false;
    const left_text = resolveText(pred.args[0], match, source) orelse return false;
    for (pred.args[1..]) |arg| {
        const candidate = resolveText(arg, match, source) orelse continue;
        if (std.mem.eql(u8, left_text, candidate)) return !negate;
    }
    return negate;
}

fn resolveText(
    operand: rule.PredicateOperand,
    match: ts.Query.Match,
    source: []const u8,
) ?[]const u8 {
    return switch (operand) {
        .string => |s| s,
        .capture => |id| findCaptureText(id, match, source),
    };
}

fn findCaptureText(
    id: u32,
    match: ts.Query.Match,
    source: []const u8,
) ?[]const u8 {
    for (match.captures) |cap| {
        if (cap.index != id) continue;
        const start = cap.node.startByte();
        const end = cap.node.endByte();
        if (end > source.len) return null;
        return source[start..end];
    }
    return null;
}
