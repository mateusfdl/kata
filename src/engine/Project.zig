const std = @import("std");

const fact_rule = @import("fact_rule.zig");
const diagnostic = @import("diagnostic.zig");
const language = @import("language.zig");
const project_rule = @import("ProjectRule.zig");

const Engine = @import("Engine.zig").Engine;
const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

pub const Project = struct {
    engine: *Engine,
    rules: []const project_rule.ProjectRule,
    fact_rules: []const fact_rule.CompiledFactRule,
    index: ProjectIndex,
    tracks_files: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *Engine,
        rules: []const project_rule.ProjectRule,
    ) !Project {
        const fact_rules = try engine.ensureCompiledFact();
        return .{
            .engine = engine,
            .rules = rules,
            .fact_rules = fact_rules,
            .index = ProjectIndex.init(allocator),
            .tracks_files = rules.len > 0 or fact_rules.len > 0,
        };
    }

    pub fn deinit(self: *Project) void {
        self.index.deinit();
    }

    pub fn indexGeneration(self: *const Project) u64 {
        return self.index.generation;
    }

    pub fn hasCrossFileRules(self: *const Project) bool {
        return self.rules.len > 0 or self.fact_rules.len > 0;
    }

    pub fn configure(self: *Project, engine: *Engine) !void {
        const fact_rules = try engine.ensureCompiledFact();
        self.engine = engine;
        self.fact_rules = fact_rules;
        self.tracks_files = self.tracks_files or self.rules.len > 0 or fact_rules.len > 0;
    }

    pub fn replace(
        self: *Project,
        source: []const u8,
        lang: language.Name,
        path: []const u8,
    ) !void {
        // Avoid parsing and retaining facts when no configured rule can use the
        // project index. Once enabled, tracking remains active across configure.
        if (!self.tracks_files) return;

        try self.index.put(try self.engine.extractFacts(self.index.allocator, source, lang, path));
    }

    pub fn remove(self: *Project, path: []const u8) bool {
        // Removal mirrors replace for long-lived projects such as the daemon.
        // Returning false distinguishes an untracked or unknown file.
        if (!self.tracks_files) return false;

        return self.index.remove(path);
    }

    pub fn lint(
        self: *Project,
        allocator: std.mem.Allocator,
        source: []const u8,
        lang: language.Name,
        path: []const u8,
    ) ![]diagnostic.Diagnostic {
        if (!self.tracks_files) return self.engine.lint(allocator, source, lang, path);

        var parsed = try self.engine.parseSource(source, lang);
        defer parsed.deinit();
        const result = try self.engine.lintParsed(allocator, &parsed, path);
        try self.index.put(try self.engine.extractFactsParsed(self.index.allocator, &parsed, path));

        return result;
    }

    pub fn diagnostics(
        self: *const Project,
        allocator: std.mem.Allocator,
        path_filter: ?[]const u8,
    ) ![]project_rule.Violation {
        if (!self.active()) return &.{};

        var out: std.ArrayList(project_rule.Violation) = .empty;
        errdefer out.deinit(allocator);
        try project_rule.evaluateInto(allocator, self.rules, self.engine.settings, &self.index, path_filter, &out);
        try fact_rule.evaluateInto(allocator, self.fact_rules, self.engine.settings, &self.index, path_filter, &out);

        std.mem.sort(project_rule.Violation, out.items, {}, project_rule.violationLessThan);
        return out.toOwnedSlice(allocator);
    }

    fn active(self: *const Project) bool {
        return self.rules.len > 0 or self.fact_rules.len > 0;
    }
};
