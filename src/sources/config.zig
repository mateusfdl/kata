const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const lifecycle = @import("lifecycle.zig");
const loader = @import("loader.zig");

const diagnostic = lint.diagnostic;
const language = lint.language;
const project_rule = lint.project_rule;
const rule = lint.rule;

pub const max_config_bytes = fs.config.max_config_bytes;

pub const RuleSetting = rule.RuleSetting;

pub const Presence = struct {
    project_rules: bool = false,
    ratchet: bool = false,
};

pub const Config = struct {
    settings: []const RuleSetting,
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
    settings: []const RuleSetting = &.{},
    project_rules: []const project_rule.ProjectRule = &.{},
    ratchet: bool = false,
};

pub fn resolve(
    arena: std.mem.Allocator,
    global: ?*const Config,
    project: ?*const Config,
) std.mem.Allocator.Error!Resolved {
    var out: Resolved = .{};
    applyPresent(&out, global);
    applyPresent(&out, project);
    out.settings = try mergeSettings(arena, global, project);
    return out;
}

fn mergeSettings(
    arena: std.mem.Allocator,
    global: ?*const Config,
    project: ?*const Config,
) std.mem.Allocator.Error![]const RuleSetting {
    const g = if (global) |c| c.settings else &.{};
    const p = if (project) |c| c.settings else &.{};

    if (p.len == 0) return g;
    if (g.len == 0) return p;

    var merged: std.ArrayList(RuleSetting) = .empty;
    try merged.appendSlice(arena, g);

    for (p) |setting| {
        if (findSetting(merged.items, setting)) |idx| {
            merged.items[idx] = setting;
        } else {
            try merged.append(arena, setting);
        }
    }

    return merged.toOwnedSlice(arena);
}

fn findSetting(settings: []const RuleSetting, setting: RuleSetting) ?usize {
    for (settings, 0..) |existing, i| {
        if (existing.project == setting.project and existing.lang == setting.lang and std.mem.eql(u8, existing.id, setting.id)) return i;
    }

    return null;
}

fn applyPresent(out: *Resolved, cfg_opt: ?*const Config) void {
    const cfg = cfg_opt orelse return;

    if (cfg.present.project_rules) out.project_rules = cfg.project_rules;
    if (cfg.present.ratchet) out.ratchet = cfg.ratchet;
}

pub const ParseError = error{
    UnknownTopLevelKey,
    TabInIndent,
    BadIndent,
    MalformedListItem,
    ContentAfterKey,
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
    UnknownScope,
    MalformedRuleEntry,
    UnknownRuleKey,
    InvalidEnabledValue,
    InvalidSeverityValue,
    DuplicateRule,
} || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    line: u32 = 0,
};

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownTopLevelKey => "unknown top-level key (expected 'rules', 'project-rules', or 'ratchet')",
        error.TabInIndent => "tabs are not allowed in indentation",
        error.BadIndent => "indent must be 0 or 2 spaces",
        error.MalformedListItem => "list item must be '  - <rule-id>'",
        error.ContentAfterKey => "no inline content allowed after key",
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
        error.UnknownScope => "unknown scope (expected 'go', 'ts', 'tsx', 'typescript', or 'project')",
        error.MalformedRuleEntry => "rule must be '    <id>:' followed by indented '<key>: <value>' properties",
        error.UnknownRuleKey => "unknown rule key (expected 'enabled', 'severity', or 'exclude')",
        error.InvalidEnabledValue => "enabled must be 'true' or 'false'",
        error.InvalidSeverityValue => "severity must be 'error' or 'warn'",
        error.DuplicateRule => "rule is already configured for this scope",
        else => @errorName(err),
    };
}

const State = enum { top, in_project_rules, in_rules };

const Scope = struct {
    langs: []const language.Name,
    project: bool,
};

const PendingRule = struct {
    scope: Scope,
    id: []const u8,
    line: u32,
    enabled: bool = true,
    severity: ?diagnostic.Severity = null,
    exclude: std.ArrayList([]const u8) = .empty,
    in_exclude: bool = false,
};

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

    var settings: std.ArrayList(RuleSetting) = .empty;
    var project_rules: std.ArrayList(project_rule.ProjectRule) = .empty;
    var ratchet = false;
    var present: Presence = .{};
    var pending: ?PendingProjectRule = null;
    var pending_rule: ?PendingRule = null;
    var scope: ?Scope = null;

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
            try finalizePendingRule(arena, &pending_rule, &settings, diag);
            scope = null;
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

        if (state == .in_rules) {
            switch (indent) {
                2 => {
                    try finalizePendingRule(arena, &pending_rule, &settings, diag);
                    diag.line = line_no;
                    scope = try parseScopeKey(content);
                },
                4 => {
                    try finalizePendingRule(arena, &pending_rule, &settings, diag);
                    diag.line = line_no;
                    const s = scope orelse return error.BadIndent;
                    pending_rule = try startRuleEntry(arena, s, content, line_no);
                },
                6 => {
                    if (pending_rule) |*p| {
                        try setRuleProperty(p, content);
                        continue;
                    }
                    return error.BadIndent;
                },
                8 => {
                    if (pending_rule) |*p| {
                        if (p.in_exclude) {
                            try appendExcludeItem(arena, p, content);
                            continue;
                        }
                    }
                    return error.BadIndent;
                },
                else => return error.BadIndent,
            }
            continue;
        }

        if (indent == 2) {
            switch (state) {
                .top => return error.UnexpectedListItem,
                .in_rules => unreachable,
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
    try finalizePendingRule(arena, &pending_rule, &settings, diag);

    diag.line = 0;

    return .{
        .settings = try settings.toOwnedSlice(arena),
        .project_rules = try project_rules.toOwnedSlice(arena),
        .ratchet = ratchet,
        .present = present,
        .arena = arena_ptr,
    };
}

fn markPresent(present: *Presence, state: State) void {
    switch (state) {
        .top, .in_rules => {},
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
    if (std.mem.eql(u8, key, "rules")) return .in_rules;
    if (std.mem.eql(u8, key, "project-rules")) return .in_project_rules;

    return null;
}

fn parseScopeKey(content: []const u8) ParseError!Scope {
    if (!std.mem.endsWith(u8, content, ":")) {
        if (std.mem.indexOfScalar(u8, content, ':')) |colon| {
            const key = std.mem.trimEnd(u8, content[0..colon], " ");
            if (scopeFromKey(key) != null) return error.ContentAfterKey;
        }
        return error.UnknownScope;
    }

    return scopeFromKey(content[0 .. content.len - 1]) orelse error.UnknownScope;
}

fn scopeFromKey(key: []const u8) ?Scope {
    if (std.mem.eql(u8, key, "go")) return .{ .langs = &.{.go}, .project = false };
    if (std.mem.eql(u8, key, "ts")) return .{ .langs = &.{.ts}, .project = false };
    if (std.mem.eql(u8, key, "tsx")) return .{ .langs = &.{.tsx}, .project = false };
    if (std.mem.eql(u8, key, "typescript")) return .{ .langs = &.{ .ts, .tsx }, .project = false };
    if (std.mem.eql(u8, key, "project")) return .{ .langs = &.{}, .project = true };

    return null;
}

fn startRuleEntry(
    arena: std.mem.Allocator,
    scope: Scope,
    content: []const u8,
    line: u32,
) ParseError!PendingRule {
    if (!std.mem.endsWith(u8, content, ":")) {
        if (std.mem.indexOfScalar(u8, content, ':') != null) return error.ContentAfterKey;
        return error.MalformedRuleEntry;
    }

    const id = content[0 .. content.len - 1];

    if (!rule.isValidId(id)) return error.InvalidRuleId;

    return .{ .scope = scope, .id = try arena.dupe(u8, id), .line = line };
}

fn setRuleProperty(pending: *PendingRule, content: []const u8) ParseError!void {
    pending.in_exclude = false;

    const colon = std.mem.indexOfScalar(u8, content, ':') orelse return error.MalformedRuleEntry;
    const key = std.mem.trimEnd(u8, content[0..colon], " ");
    const value = std.mem.trim(u8, content[colon + 1 ..], " ");

    if (std.mem.eql(u8, key, "enabled")) {
        pending.enabled = try parseBoolValue(value, error.InvalidEnabledValue);
        return;
    }

    if (std.mem.eql(u8, key, "severity")) {
        pending.severity = try parseSeverityValue(value);
        return;
    }

    if (std.mem.eql(u8, key, "exclude")) {
        if (value.len != 0) return error.ContentAfterKey;
        pending.in_exclude = true;
        return;
    }

    return error.UnknownRuleKey;
}

fn parseBoolValue(value: []const u8, invalid: ParseError) ParseError!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;

    return invalid;
}

fn parseSeverityValue(value: []const u8) ParseError!diagnostic.Severity {
    if (std.mem.eql(u8, value, "error")) return .@"error";
    if (std.mem.eql(u8, value, "warn")) return .warn;

    return error.InvalidSeverityValue;
}

fn appendExcludeItem(
    arena: std.mem.Allocator,
    pending: *PendingRule,
    content: []const u8,
) ParseError!void {
    if (!std.mem.startsWith(u8, content, "- ")) return error.MalformedListItem;

    const item = stripQuotes(std.mem.trim(u8, content[2..], " "));

    if (item.len == 0) return error.MalformedListItem;

    try pending.exclude.append(arena, try arena.dupe(u8, item));
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len < 2) return s;

    const first = s[0];
    const last = s[s.len - 1];
    if ((first == '\'' and last == '\'') or (first == '"' and last == '"')) return s[1 .. s.len - 1];

    return s;
}

fn finalizePendingRule(
    arena: std.mem.Allocator,
    pending: *?PendingRule,
    settings: *std.ArrayList(RuleSetting),
    diag: *Diagnostic,
) ParseError!void {
    var p = pending.* orelse return;

    pending.* = null;

    const exclude = try p.exclude.toOwnedSlice(arena);

    if (p.scope.project) {
        try appendSetting(arena, settings, .{
            .lang = null,
            .id = p.id,
            .project = true,
            .enabled = p.enabled,
            .severity = p.severity,
            .exclude = exclude,
        }, p.line, diag);
        return;
    }

    for (p.scope.langs) |lang| {
        try appendSetting(arena, settings, .{
            .lang = lang,
            .id = p.id,
            .enabled = p.enabled,
            .severity = p.severity,
            .exclude = exclude,
        }, p.line, diag);
    }
}

fn appendSetting(
    arena: std.mem.Allocator,
    settings: *std.ArrayList(RuleSetting),
    setting: RuleSetting,
    line: u32,
    diag: *Diagnostic,
) ParseError!void {
    if (findSetting(settings.items, setting) != null) {
        diag.line = line;
        return error.DuplicateRule;
    }

    try settings.append(arena, setting);
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

pub fn applySelection(
    arena: std.mem.Allocator,
    set: *loader.RuleSet,
    resolved: *Resolved,
    table: *const lifecycle.Table,
    diag: *rule.Diagnostic,
) !void {
    resolved.settings = try resolveFormerIds(arena, set, resolved.settings, table, diag);

    for (std.enums.values(language.Name)) |lang| {
        const list = set.by_lang.getPtr(lang);
        var i: usize = 0;

        while (i < list.items.len) {
            if (isActive(lang, list.items[i].id, resolved.*)) {
                i += 1;
            } else {
                _ = list.swapRemove(i);
            }
        }
    }

    var i: usize = 0;
    while (i < set.project.items.len) {
        if (isActiveProject(set.project.items[i].id, resolved.*)) {
            i += 1;
        } else {
            _ = set.project.swapRemove(i);
        }
    }
}

fn resolveFormerIds(
    arena: std.mem.Allocator,
    set: *loader.RuleSet,
    settings: []const RuleSetting,
    table: *const lifecycle.Table,
    diag: *rule.Diagnostic,
) ![]const RuleSetting {
    const rewritten = try arena.dupe(RuleSetting, settings);
    for (rewritten) |*setting| {
        const scope: ?language.Name = if (setting.project) null else setting.lang orelse continue;
        switch (table.resolve(scope, setting.id)) {
            .renamed, .replaced => |canonical| {
                try appendRenamedWarning(set, setting.lang, setting.id, canonical);
                setting.id = canonical;
            },
            .removed => |reason| {
                diag.* = .{
                    .lang = setting.lang,
                    .rule_id = setting.id,
                    .detail = try std.fmt.allocPrint(arena, "removed: {s}", .{reason}),
                };

                return error.RetiredRuleRemoved;
            },
            .live, .unknown => {},
        }
    }

    return rewritten;
}

fn appendRenamedWarning(set: *loader.RuleSet, lang: ?language.Name, id: []const u8, canonical: []const u8) !void {
    for (set.warnings.items) |w| {
        if (w.kind != .renamed) continue;
        if (!std.mem.eql(u8, w.id, id)) continue;
        if (std.mem.eql(u8, w.canonical.?, canonical)) return;
    }

    try set.warnings.append(set.allocator, .{
        .kind = .renamed,
        .lang = lang,
        .id = id,
        .canonical = canonical,
    });
}

fn isActiveProject(id: []const u8, resolved: Resolved) bool {
    for (resolved.settings) |setting| {
        if (setting.matchesProject(id)) return setting.enabled;
    }

    return false;
}

fn isActive(lang: language.Name, id: []const u8, resolved: Resolved) bool {
    for (resolved.settings) |setting| {
        if (setting.matches(lang, id)) return setting.enabled;
    }

    return false;
}
