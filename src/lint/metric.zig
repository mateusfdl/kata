const std = @import("std");
const ts = @import("tree_sitter");

const diagnostic = @import("diagnostic.zig");
const language = @import("language.zig");

pub const Name = enum {
    function_length,

    pub fn toString(self: Name) []const u8 {
        return switch (self) {
            .function_length => "function-length",
        };
    }

    pub fn fromString(s: []const u8) ?Name {
        for (std.enums.values(Name)) |n| {
            if (std.mem.eql(u8, s, n.toString())) return n;
        }
        return null;
    }
};

pub const Set = std.EnumArray(Name, ?u32);

pub const empty: Set = .initFill(null);

pub fn anyEnabled(set: Set) bool {
    for (std.enums.values(Name)) |n| {
        if (set.get(n) != null) return true;
    }
    return false;
}

const ts_query_source =
    \\(function_declaration) @function
    \\(function_expression) @function
    \\(generator_function_declaration) @function
    \\(generator_function) @function
    \\(arrow_function) @function
    \\(method_definition) @function
;

const go_query_source =
    \\(function_declaration) @function
    \\(method_declaration) @function
    \\(func_literal) @function
;

pub fn querySource(lang: language.Name) []const u8 {
    return switch (lang) {
        .ts, .tsx => ts_query_source,
        .go => go_query_source,
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    set: Set,
    query: *ts.Query,
    cursor: *ts.QueryCursor,
    root: ts.Node,
    lang: language.Name,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const max = set.get(.function_length) orelse return;

    cursor.exec(query, root);
    const lang_str = lang.toString();

    while (cursor.nextMatch()) |match| {
        for (match.captures) |cap| {
            try checkFunctionLength(allocator, cap.node, max, lang_str, out);
        }
    }
}

fn checkFunctionLength(
    allocator: std.mem.Allocator,
    node: ts.Node,
    max: u32,
    lang_str: []const u8,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const sp = node.startPoint();
    const ep = node.endPoint();
    const lines = ep.row - sp.row + 1;
    if (lines <= max) return;

    try out.append(allocator, .{
        .rule_id = Name.function_length.toString(),
        .language = lang_str,
        .message = try std.fmt.allocPrint(
            allocator,
            "function length {d} exceeds max {d}",
            .{ lines, max },
        ),
        .range = .{
            .start = .{ .line = sp.row, .column = sp.column },
            .end = .{ .line = ep.row, .column = ep.column },
        },
    });
}
