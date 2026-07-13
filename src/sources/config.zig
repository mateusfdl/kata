const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("../lint.zig");
const loader = @import("loader.zig");

const language = lint.language;
const project_rule = lint.project_rule;
const rule = lint.rule;

pub const max_config_bytes = fs.config.max_config_bytes;

pub const ScopedId = rule.ScopedId;

pub const Presence = struct {
    enabled: bool = false,
    disabled: bool = false,
    warnings: bool = false,
    project_rules: bool = false,
    ratchet: bool = false,
};

pub const Config = struct {
    enabled: []const ScopedId,
    disabled: []const ScopedId,
    warnings: []const ScopedId,
    project_rules: []const project_rule.ProjectRule,
    ratchet: bool,
    present: Presence,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const Resolved = struct {
    enabled: []const ScopedId = &.{},
    disabled: []const ScopedId = &.{},
    warnings: []const ScopedId = &.{},
    project_rules: []const project_rule.ProjectRule = &.{},
    ratchet: bool = false,
};

pub fn resolve(global: ?*const Config, project: ?*const Config) Resolved {
    var out: Resolved = .{};
    applyPresent(&out, global);
    applyPresent(&out, project);
    return out;
}

fn applyPresent(out: *Resolved, cfg_opt: ?*const Config) void {
    const cfg = cfg_opt orelse return;

    if (cfg.present.enabled) out.enabled = cfg.enabled;
    if (cfg.present.disabled) out.disabled = cfg.disabled;
    if (cfg.present.warnings) out.warnings = cfg.warnings;
    if (cfg.present.project_rules) out.project_rules = cfg.project_rules;
    if (cfg.present.ratchet) out.ratchet = cfg.ratchet;
}

pub const ParseError = error{
    UnknownTopLevelKey,
    TabInIndent,
    BadIndent,
    MalformedListItem,
    ContentAfterKey,
    UnknownLanguage,
    InvalidRuleId,
    UnexpectedListItem,
    UnknownProjectRuleKind,
    MissingProjectRuleKind,
    IncompleteRestrictedCallers,
    MalformedProjectRuleEntry,
    UnknownProjectRuleKey,
    WrongKindProjectRuleKey,
    IncompleteImportBoundary,
    InvalidRatchetValue,
} || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    line: u32 = 0,
};

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownTopLevelKey => "unknown top-level key (expected 'enabled', 'disabled', 'warnings', 'project-rules', or 'ratchet')",
        error.TabInIndent => "tabs are not allowed in indentation",
        error.BadIndent => "indent must be 0 or 2 spaces",
        error.MalformedListItem => "list item must be '  - <rule-id>'",
        error.ContentAfterKey => "no inline content allowed after key",
        error.UnknownLanguage => "unknown language (expected " ++ language.supported_list ++ ")",
        error.InvalidRuleId => "rule id must match [A-Za-z0-9_-]+",
        error.UnexpectedListItem => "list item without a preceding key",
        error.UnknownProjectRuleKind => "unknown project rule kind (expected 'restricted-callers' or 'import-boundary')",
        error.MissingProjectRuleKind => "project rule is missing 'kind'",
        error.IncompleteRestrictedCallers => "restricted-callers requires 'callee-suffix' and 'caller-suffix'",
        error.MalformedProjectRuleEntry => "project rule must be '  <id>:' followed by indented '<key>: <value>' properties",
        error.UnknownProjectRuleKey => "unknown project rule key (expected 'kind', 'callee-suffix', 'caller-suffix', 'from', or 'deny')",
        error.WrongKindProjectRuleKey => "'callee-suffix' and 'caller-suffix' apply to restricted-callers; 'from' and 'deny' apply to import-boundary",
        error.IncompleteImportBoundary => "import-boundary requires 'from' and 'deny'",
        error.InvalidRatchetValue => "ratchet must be 'true' or 'false'",
        else => @errorName(err),
    };
}

const State = enum { top, in_enabled, in_disabled, in_warnings, in_project_rules };

const PendingProjectRule = struct {
    id: []const u8,
    line: u32,
    kind: ?project_rule.ProjectRule.Kind.Tag = null,
    callee_suffix: ?[]const u8 = null,
    caller_suffix: ?[]const u8 = null,
    from: ?[]const u8 = null,
    deny: ?[]const u8 = null,
};

pub fn parse(gpa: std.mem.Allocator, source: []const u8, diag: *Diagnostic) ParseError!Config {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = .init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var enabled: std.ArrayList(ScopedId) = .empty;
    var disabled: std.ArrayList(ScopedId) = .empty;
    var warnings: std.ArrayList(ScopedId) = .empty;
    var project_rules: std.ArrayList(project_rule.ProjectRule) = .empty;
    var ratchet = false;
    var present: Presence = .{};
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
            if (std.mem.startsWith(u8, content, "ratchet:")) {
                ratchet = try parseRatchetValue(content["ratchet:".len..]);
                present.ratchet = true;
                state = .top;
                continue;
            }
            state = try parseTopLevelKey(content);
            markPresent(&present, state);
            continue;
        }

        if (indent == 2) {
            switch (state) {
                .top => return error.UnexpectedListItem,
                .in_enabled => try appendListItem(arena, &enabled, content),
                .in_disabled => try appendListItem(arena, &disabled, content),
                .in_warnings => try appendListItem(arena, &warnings, content),
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
        .enabled = try enabled.toOwnedSlice(arena),
        .disabled = try disabled.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
        .project_rules = try project_rules.toOwnedSlice(arena),
        .ratchet = ratchet,
        .present = present,
        .arena = arena_ptr,
    };
}

fn markPresent(present: *Presence, state: State) void {
    switch (state) {
        .top => {},
        .in_enabled => present.enabled = true,
        .in_disabled => present.disabled = true,
        .in_warnings => present.warnings = true,
        .in_project_rules => present.project_rules = true,
    }
}

fn parseRatchetValue(raw: []const u8) ParseError!bool {
    const value = std.mem.trim(u8, raw, " ");

    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;

    return error.InvalidRatchetValue;
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

    switch (kind) {
        .restricted_callers => {
            if (p.from != null or p.deny != null) {
                diag.line = p.line;
                return error.WrongKindProjectRuleKey;
            }
            const callee_suffix = p.callee_suffix orelse {
                diag.line = p.line;
                return error.IncompleteRestrictedCallers;
            };
            const caller_suffix = p.caller_suffix orelse {
                diag.line = p.line;
                return error.IncompleteRestrictedCallers;
            };
            try project_rules.append(arena, .{
                .id = p.id,
                .kind = .{ .restricted_callers = .{
                    .callee_suffix = callee_suffix,
                    .caller_suffix = caller_suffix,
                } },
            });
        },
        .import_boundary => {
            if (p.callee_suffix != null or p.caller_suffix != null) {
                diag.line = p.line;
                return error.WrongKindProjectRuleKey;
            }
            const from = p.from orelse {
                diag.line = p.line;
                return error.IncompleteImportBoundary;
            };
            const deny = p.deny orelse {
                diag.line = p.line;
                return error.IncompleteImportBoundary;
            };
            try project_rules.append(arena, .{
                .id = p.id,
                .kind = .{ .import_boundary = .{ .from = from, .deny = deny } },
            });
        },
    }
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
        pending.kind = project_rule.ProjectRule.Kind.tagFromString(value) orelse return error.UnknownProjectRuleKind;
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

    if (std.mem.eql(u8, key, "from")) {
        pending.from = try arena.dupe(u8, value);
        return;
    }

    if (std.mem.eql(u8, key, "deny")) {
        pending.deny = try arena.dupe(u8, value);
        return;
    }

    return error.UnknownProjectRuleKey;
}

fn parseTopLevelKey(content: []const u8) ParseError!State {
    if (std.mem.endsWith(u8, content, ":")) {
        return sectionState(content[0 .. content.len - 1]) orelse error.UnknownTopLevelKey;
    }

    if (std.mem.indexOfScalar(u8, content, ':')) |colon| {
        const key = std.mem.trimEnd(u8, content[0..colon], " ");
        if (sectionState(key) != null) return error.ContentAfterKey;
        return error.UnknownTopLevelKey;
    }

    return error.UnknownTopLevelKey;
}

fn sectionState(key: []const u8) ?State {
    if (std.mem.eql(u8, key, "enabled")) return .in_enabled;
    if (std.mem.eql(u8, key, "disabled")) return .in_disabled;
    if (std.mem.eql(u8, key, "warnings")) return .in_warnings;
    if (std.mem.eql(u8, key, "project-rules")) return .in_project_rules;

    return null;
}

fn appendListItem(
    arena: std.mem.Allocator,
    list: *std.ArrayList(ScopedId),
    content: []const u8,
) ParseError!void {
    if (!std.mem.startsWith(u8, content, "- ")) return error.MalformedListItem;

    const item = std.mem.trimStart(u8, content[2..], " ");

    if (item.len == 0) return error.MalformedListItem;

    if (std.mem.indexOfScalar(u8, item, '/')) |slash| {
        const scope = item[0..slash];
        const id = item[slash + 1 ..];
        if (!rule.isValidId(scope) or !rule.isValidId(id)) return error.InvalidRuleId;
        if (std.mem.eql(u8, scope, "project")) {
            try list.append(arena, .{ .lang = null, .id = try arena.dupe(u8, id), .project = true });
            return;
        }
        const lang = language.Name.fromString(scope) orelse return error.UnknownLanguage;
        try list.append(arena, .{ .lang = lang, .id = try arena.dupe(u8, id) });
        return;
    }

    if (!rule.isValidId(item)) return error.InvalidRuleId;

    try list.append(arena, .{ .lang = null, .id = try arena.dupe(u8, item) });
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
    return fs.config.resolveBase(arena, environ);
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
    const path = try fs.config.rulesPath(scratch, base);
    const source = (try fs.config.readRulesYaml(io, scratch, path)) orelse return null;

    return try parse(gpa, source, diag);
}

pub fn applySelection(set: *loader.RuleSet, resolved: Resolved) void {
    for (std.enums.values(language.Name)) |lang| {
        const list = set.by_lang.getPtr(lang);
        var i: usize = 0;

        while (i < list.items.len) {
            if (isActive(lang, list.items[i].id, resolved)) {
                i += 1;
            } else {
                _ = list.swapRemove(i);
            }
        }
    }

    var i: usize = 0;
    while (i < set.project.items.len) {
        if (isActiveProject(set.project.items[i].id, resolved)) {
            i += 1;
        } else {
            _ = set.project.swapRemove(i);
        }
    }
}

fn isActiveProject(id: []const u8, resolved: Resolved) bool {
    return anyMatchesProject(resolved.enabled, id) and !anyMatchesProject(resolved.disabled, id);
}

fn anyMatchesProject(ids: []const ScopedId, id: []const u8) bool {
    for (ids) |scoped| {
        if (scoped.matchesProject(id)) return true;
    }

    return false;
}

fn isActive(lang: language.Name, id: []const u8, resolved: Resolved) bool {
    return matchesAny(resolved.enabled, lang, id) and !matchesAny(resolved.disabled, lang, id);
}

fn matchesAny(ids: []const ScopedId, lang: language.Name, id: []const u8) bool {
    for (ids) |scoped| {
        if (scoped.matches(lang, id)) return true;
    }

    return false;
}
