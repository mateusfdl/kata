const std = @import("std");

const lint = @import("../lint.zig");
const loader = @import("loader.zig");

const language = lint.language;
const metric = lint.metric;
const project_rule = lint.project_rule;
const rule = lint.rule;

pub const max_config_bytes: usize = 64 * 1024;

pub const ScopedId = rule.ScopedId;

pub const Config = struct {
    disabled: []const ScopedId,
    warnings: []const ScopedId,
    metrics: metric.Set,
    project_rules: []const project_rule.ProjectRule,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const ParseError = error{
    UnknownTopLevelKey,
    TabInIndent,
    BadIndent,
    MalformedListItem,
    ContentAfterKey,
    UnknownLanguage,
    InvalidRuleId,
    UnexpectedListItem,
    UnknownMetric,
    InvalidThreshold,
    MalformedMetricEntry,
    UnknownProjectRuleKind,
    MissingProjectRuleKind,
    IncompleteProjectRule,
    MalformedProjectRuleEntry,
    UnknownProjectRuleKey,
} || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    line: u32 = 0,
};

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownTopLevelKey => "unknown top-level key (expected 'disabled', 'warnings', 'metrics', or 'project-rules')",
        error.TabInIndent => "tabs are not allowed in indentation",
        error.BadIndent => "indent must be 0 or 2 spaces",
        error.MalformedListItem => "list item must be '  - <rule-id>'",
        error.ContentAfterKey => "no inline content allowed after key",
        error.UnknownLanguage => "unknown language (expected ts, tsx, or go)",
        error.InvalidRuleId => "rule id must match [A-Za-z0-9_-]+",
        error.UnexpectedListItem => "list item without a preceding key",
        error.UnknownMetric => "unknown metric (expected 'complexity', 'nesting-depth', or 'function-length')",
        error.InvalidThreshold => "metric threshold must be a positive integer",
        error.MalformedMetricEntry => "metric entry must be '  <metric>: <threshold>'",
        error.UnknownProjectRuleKind => "unknown project rule kind (expected 'restricted-callers')",
        error.MissingProjectRuleKind => "project rule is missing 'kind'",
        error.IncompleteProjectRule => "restricted-callers requires 'callee-suffix' and 'caller-suffix'",
        error.MalformedProjectRuleEntry => "project rule must be '  <id>:' followed by indented '<key>: <value>' properties",
        error.UnknownProjectRuleKey => "unknown project rule key (expected 'kind', 'callee-suffix', or 'caller-suffix')",
        else => @errorName(err),
    };
}

const State = enum { top, in_disabled, in_warnings, in_metrics, in_project_rules };

const PendingProjectRule = struct {
    id: []const u8,
    line: u32,
    kind: ?project_rule.ProjectRule.Kind = null,
    callee_suffix: ?[]const u8 = null,
    caller_suffix: ?[]const u8 = null,
};

pub fn parse(gpa: std.mem.Allocator, source: []const u8, diag: *Diagnostic) ParseError!Config {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = .init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var disabled: std.ArrayList(ScopedId) = .empty;
    var warnings: std.ArrayList(ScopedId) = .empty;
    var metrics: metric.Set = metric.empty;
    var project_rules: std.ArrayList(project_rule.ProjectRule) = .empty;
    var pending: ?PendingProjectRule = null;

    var line_no: u32 = 0;
    var iter = std.mem.splitScalar(u8, source, '\n');
    var state: State = .top;

    while (iter.next()) |raw_line| {
        line_no += 1;
        diag.line = line_no;

        const without_cr = std.mem.trimEnd(u8, raw_line, "\r");
        const without_comment = stripComment(without_cr);

        if (containsTab(without_comment)) return error.TabInIndent;

        const trimmed_right = std.mem.trimEnd(u8, without_comment, " ");
        if (trimmed_right.len == 0) continue;

        const indent = leadingSpaces(trimmed_right);
        const content = trimmed_right[indent..];

        if (indent == 0) {
            try finalizePending(arena, &pending, &project_rules, diag);
            state = try parseTopLevelKey(content);
            continue;
        }

        if (indent == 2) {
            switch (state) {
                .top => return error.UnexpectedListItem,
                .in_disabled => try appendListItem(arena, &disabled, content),
                .in_warnings => try appendListItem(arena, &warnings, content),
                .in_metrics => try setMetricEntry(&metrics, content),
                .in_project_rules => {
                    try finalizePending(arena, &pending, &project_rules, diag);
                    diag.line = line_no;
                    pending = try startProjectRule(arena, content, line_no);
                },
            }
            continue;
        }

        if (indent == 4 and state == .in_project_rules) {
            if (pending) |*p| {
                try setProjectRuleProperty(arena, p, content);
                continue;
            }
            return error.BadIndent;
        }

        return error.BadIndent;
    }

    diag.line = line_no;
    try finalizePending(arena, &pending, &project_rules, diag);

    diag.line = 0;
    return .{
        .disabled = try disabled.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
        .metrics = metrics,
        .project_rules = try project_rules.toOwnedSlice(arena),
        .arena = arena_ptr,
    };
}

fn finalizePending(
    arena: std.mem.Allocator,
    pending: *?PendingProjectRule,
    project_rules: *std.ArrayList(project_rule.ProjectRule),
    diag: *Diagnostic,
) ParseError!void {
    const p = pending.* orelse return;
    pending.* = null;
    const kind = p.kind orelse {
        diag.line = p.line;
        return error.MissingProjectRuleKind;
    };
    const callee_suffix = p.callee_suffix orelse {
        diag.line = p.line;
        return error.IncompleteProjectRule;
    };
    const caller_suffix = p.caller_suffix orelse {
        diag.line = p.line;
        return error.IncompleteProjectRule;
    };
    try project_rules.append(arena, .{
        .id = p.id,
        .kind = kind,
        .callee_suffix = callee_suffix,
        .caller_suffix = caller_suffix,
    });
}

fn startProjectRule(
    arena: std.mem.Allocator,
    content: []const u8,
    line: u32,
) ParseError!PendingProjectRule {
    if (!std.mem.endsWith(u8, content, ":")) return error.MalformedProjectRuleEntry;
    const id = content[0 .. content.len - 1];
    if (!rule.isValidId(id)) return error.InvalidRuleId;
    return .{ .id = try arena.dupe(u8, id), .line = line };
}

fn setProjectRuleProperty(
    arena: std.mem.Allocator,
    pending: *PendingProjectRule,
    content: []const u8,
) ParseError!void {
    const colon = std.mem.indexOfScalar(u8, content, ':') orelse return error.MalformedProjectRuleEntry;
    const key = std.mem.trimEnd(u8, content[0..colon], " ");
    const value = std.mem.trim(u8, content[colon + 1 ..], " ");
    if (value.len == 0) return error.MalformedProjectRuleEntry;

    if (std.mem.eql(u8, key, "kind")) {
        pending.kind = project_rule.ProjectRule.Kind.fromString(value) orelse return error.UnknownProjectRuleKind;
        return;
    }
    if (std.mem.eql(u8, key, "callee-suffix")) {
        pending.callee_suffix = try arena.dupe(u8, value);
        return;
    }
    if (std.mem.eql(u8, key, "caller-suffix")) {
        pending.caller_suffix = try arena.dupe(u8, value);
        return;
    }
    return error.UnknownProjectRuleKey;
}

fn parseTopLevelKey(content: []const u8) ParseError!State {
    if (std.mem.endsWith(u8, content, ":")) {
        const key = content[0 .. content.len - 1];
        if (std.mem.eql(u8, key, "disabled")) return .in_disabled;
        if (std.mem.eql(u8, key, "warnings")) return .in_warnings;
        if (std.mem.eql(u8, key, "metrics")) return .in_metrics;
        if (std.mem.eql(u8, key, "project-rules")) return .in_project_rules;
        return error.UnknownTopLevelKey;
    }
    if (std.mem.indexOfScalar(u8, content, ':') != null) return error.ContentAfterKey;
    return error.UnknownTopLevelKey;
}

fn setMetricEntry(metrics: *metric.Set, content: []const u8) ParseError!void {
    const colon = std.mem.indexOfScalar(u8, content, ':') orelse return error.MalformedMetricEntry;
    const key = std.mem.trimEnd(u8, content[0..colon], " ");
    const value = std.mem.trim(u8, content[colon + 1 ..], " ");
    const name = metric.Name.fromString(key) orelse return error.UnknownMetric;
    const threshold = std.fmt.parseInt(u32, value, 10) catch return error.InvalidThreshold;
    if (threshold == 0) return error.InvalidThreshold;
    metrics.set(name, threshold);
}

fn appendListItem(
    arena: std.mem.Allocator,
    disabled: *std.ArrayList(ScopedId),
    content: []const u8,
) ParseError!void {
    if (!std.mem.startsWith(u8, content, "- ")) return error.MalformedListItem;
    const item = std.mem.trimStart(u8, content[2..], " ");
    if (item.len == 0) return error.MalformedListItem;

    if (std.mem.indexOfScalar(u8, item, '/')) |slash| {
        const lang_str = item[0..slash];
        const id = item[slash + 1 ..];
        if (!rule.isValidId(lang_str) or !rule.isValidId(id)) return error.InvalidRuleId;
        const lang = language.Name.fromString(lang_str) orelse return error.UnknownLanguage;
        try disabled.append(arena, .{ .lang = lang, .id = try arena.dupe(u8, id) });
        return;
    }

    if (!rule.isValidId(item)) return error.InvalidRuleId;
    try disabled.append(arena, .{ .lang = null, .id = try arena.dupe(u8, item) });
}

fn stripComment(line: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, line, '#')) |idx| line[0..idx] else line;
}

fn containsTab(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\t') != null;
}

fn leadingSpaces(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ' ') n += 1;
    return n;
}

pub fn resolveConfigBase(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg|
        return try std.fmt.allocPrint(arena, "{s}/kata", .{xdg});
    if (environ.get("HOME")) |home|
        return try std.fmt.allocPrint(arena, "{s}/.config/kata", .{home});
    return null;
}

pub fn loadFromDisk(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    diag: *Diagnostic,
) !?Config {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    const base = (try resolveConfigBase(scratch, environ)) orelse return null;
    const path = try std.fmt.allocPrint(scratch, "{s}/rules.yaml", .{base});
    const source = (try tryReadFile(scratch, io, path)) orelse return null;
    return try parse(gpa, source, diag);
}

fn tryReadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

pub fn filterDisabled(set: *loader.RuleSet, cfg: Config) void {
    for (std.enums.values(language.Name)) |lang| {
        const list = set.by_lang.getPtr(lang);
        var i: usize = 0;
        while (i < list.items.len) {
            if (isDisabled(lang, list.items[i].id, cfg)) {
                _ = list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

fn isDisabled(lang: language.Name, id: []const u8, cfg: Config) bool {
    for (cfg.disabled) |d| {
        const lang_matches = d.lang == null or d.lang.? == lang;
        if (lang_matches and std.mem.eql(u8, d.id, id)) return true;
    }
    return false;
}
