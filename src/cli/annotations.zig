const std = @import("std");

const Diagnostic = @import("engine").diagnostic.Diagnostic;

pub const expect_marker = "// kata-expect:";
pub const expect_fix_marker = "// kata-expect-fix:";

pub const Expectation = struct {
    line: u32,
    rule_id: []const u8,
};

pub const FixExpectation = struct {
    line: u32,
    replacement: []const u8,
};

/// A malformed annotation or an expectation mismatch.
pub const Problem = struct {
    /// Zero-based source line.
    line: u32,
    message: []const u8,
};

pub const Comparison = struct {
    problems: []const Problem,
    rules_with_asserted_fix: []const []const u8,
};

/// The expectations that the annotations of one fixture declare.
pub const Annotations = struct {
    found: []const Annotation,
    expectations: []const Expectation,
    fix_expectations: []const FixExpectation,
    problems: []const Problem,

    pub fn parse(arena: std.mem.Allocator, source: []const u8) !Annotations {
        const scanned = try scan(arena, source);

        var expectations: std.ArrayList(Expectation) = .empty;
        var fix_expectations: std.ArrayList(FixExpectation) = .empty;
        var problems: std.ArrayList(Problem) = .empty;

        for (scanned.found) |annotation| {
            const target = targetLine(scanned.found, annotation.line, scanned.line_count);

            switch (annotation.body) {
                .rules => |text| {
                    var ids = std.mem.tokenizeAny(u8, text, ", \t");

                    if (ids.peek() == null) {
                        const problem: Problem = .{ .line = annotation.line, .message = "empty kata-expect annotation" };

                        try problems.append(arena, problem);
                    } else if (target) |line| {
                        while (ids.next()) |id| {
                            const expectation: Expectation = .{ .line = line, .rule_id = id };

                            try expectations.append(arena, expectation);
                        }
                    } else {
                        const problem: Problem = .{ .line = annotation.line, .message = "dangling kata-expect annotation" };

                        try problems.append(arena, problem);
                    }
                },
                .fix => |replacement| {
                    if (target) |line| {
                        const expectation: FixExpectation = .{ .line = line, .replacement = replacement };

                        try fix_expectations.append(arena, expectation);
                    } else {
                        const problem: Problem = .{ .line = annotation.line, .message = "dangling kata-expect-fix annotation" };

                        try problems.append(arena, problem);
                    }
                },
            }
        }

        return .{
            .found = scanned.found,
            .expectations = expectations.items,
            .fix_expectations = fix_expectations.items,
            .problems = problems.items,
        };
    }

    pub fn compare(self: Annotations, arena: std.mem.Allocator, diagnostics: []const Diagnostic) !Comparison {
        var problems: std.ArrayList(Problem) = .empty;
        try problems.appendSlice(arena, self.problems);

        const matched = try arena.alloc(bool, self.expectations.len);
        @memset(matched, false);

        for (diagnostics) |diagnostic| {
            const line = diagnostic.range.start.line;

            if (isAnnotationLine(self.found, line)) {
                continue;
            }

            if (claim(self.expectations, matched, line, diagnostic.rule_id)) {
                continue;
            }

            const problem: Problem = .{
                .line = line,
                .message = try std.fmt.allocPrint(arena, "unexpected [{s}]", .{diagnostic.rule_id}),
            };

            try problems.append(arena, problem);
        }

        for (self.expectations, matched) |expectation, found| {
            if (!found) {
                const problem: Problem = .{
                    .line = expectation.line,
                    .message = try std.fmt.allocPrint(arena, "missing [{s}]", .{expectation.rule_id}),
                };

                try problems.append(arena, problem);
            }
        }

        var covered: std.StringArrayHashMapUnmanaged(void) = .empty;

        const fixed = try arena.alloc(bool, self.fix_expectations.len);
        @memset(fixed, false);

        for (diagnostics) |diagnostic| {
            const fix = diagnostic.fix orelse {
                continue;
            };

            const expectation = claimFix(self.fix_expectations, fixed, diagnostic.range.start.line) orelse {
                continue;
            };

            try covered.put(arena, diagnostic.rule_id, {});

            if (!std.mem.eql(u8, expectation.replacement, fix.replacement)) {
                const problem: Problem = .{
                    .line = expectation.line,
                    .message = try std.fmt.allocPrint(arena, "wrong fix \"{s}\" (expected \"{s}\")", .{ fix.replacement, expectation.replacement }),
                };

                try problems.append(arena, problem);
            }
        }

        for (self.fix_expectations, fixed) |expectation, found| {
            if (!found) {
                const problem: Problem = .{ .line = expectation.line, .message = "missing fix" };

                try problems.append(arena, problem);
            }
        }

        return .{ .problems = problems.items, .rules_with_asserted_fix = covered.keys() };
    }
};

const Annotation = struct {
    line: u32,
    body: union(enum) {
        rules: []const u8,
        fix: []const u8,
    },
};

const Scan = struct {
    found: []const Annotation,
    /// The number of source lines that an annotation can target.
    line_count: u32,
};

fn claim(expectations: []const Expectation, matched: []bool, line: u32, rule_id: []const u8) bool {
    for (expectations, matched) |expectation, *found| {
        if (found.* or expectation.line != line) {
            continue;
        }

        if (!std.mem.eql(u8, expectation.rule_id, rule_id)) {
            continue;
        }

        found.* = true;

        return true;
    }

    return false;
}

// Fix annotations have no rule ID; the first fix on a line consumes the next expectation.
fn claimFix(expectations: []const FixExpectation, matched: []bool, line: u32) ?FixExpectation {
    for (expectations, matched) |expectation, *found| {
        if (found.* or expectation.line != line) {
            continue;
        }

        found.* = true;

        return expectation;
    }

    return null;
}

fn scan(arena: std.mem.Allocator, source: []const u8) !Scan {
    var found: std.ArrayList(Annotation) = .empty;
    var line_count: u32 = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |raw_line| : (line_count += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (std.mem.startsWith(u8, line, expect_fix_marker)) {
            const replacement = std.mem.trim(u8, line[expect_fix_marker.len..], " \t");
            const annotation: Annotation = .{ .line = line_count, .body = .{ .fix = replacement } };

            try found.append(arena, annotation);
        } else if (std.mem.startsWith(u8, line, expect_marker)) {
            const annotation: Annotation = .{ .line = line_count, .body = .{ .rules = line[expect_marker.len..] } };

            try found.append(arena, annotation);
        }
    }

    // splitScalar adds an empty item after a trailing newline. That item is
    // not a targetable source line.
    if (source.len > 0 and source[source.len - 1] == '\n') {
        line_count -= 1;
    }

    return .{ .found = found.items, .line_count = line_count };
}

fn isAnnotationLine(found: []const Annotation, line: u32) bool {
    for (found) |annotation| {
        if (annotation.line == line) {
            return true;
        }
    }

    return false;
}

fn targetLine(found: []const Annotation, line: u32, line_count: u32) ?u32 {
    var target = line + 1;

    // adjacent expect and expect-fix lines form one annotation block. every
    // annotation in the block targets the first source line below it.
    while (isAnnotationLine(found, target)) {
        target += 1;
    }

    if (target >= line_count) {
        return null;
    }

    return target;
}
