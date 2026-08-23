const std = @import("std");

const fs = @import("../fs.zig");
const git = @import("git");
const lint = @import("engine");
const sources = @import("../sources.zig");

const Engine = lint.Engine;
const language = lint.language;

pub const Baseline = struct {
    ref: []const u8,
    prefix: []const u8,
    dir: std.Io.Dir,
    backdated: []const []const u8 = &.{},

    pub fn backdatedRules(
        io: std.Io,
        arena: std.mem.Allocator,
        baseline: Baseline,
        root: ?[]const u8,
        rule_set: *const lint.RuleSet,
    ) ![]const []const u8 {
        const project_root = root orelse return &.{};
        const base = try repoBase(arena, baseline.prefix, project_root);

        var out: std.ArrayList([]const u8) = .empty;

        const rules_path = try std.fmt.allocPrint(arena, "{s}{s}/rules", .{ base, fs.discover.project_dir_name });
        const ref_files = try git.listFiles(io, arena, baseline.dir, baseline.ref, rules_path, fs.source.max_file_bytes);
        try appendEnabledAfterRef(arena, &out, rule_set, ref_files);

        const yaml_path = try std.fmt.allocPrint(arena, "{s}{s}/rules.yaml", .{ base, fs.discover.project_dir_name });
        if (try git.showFile(io, arena, baseline.dir, baseline.ref, yaml_path, fs.source.max_file_bytes)) |bytes| {
            try appendRaisedAfterRef(arena, &out, bytes);
        }

        return out.toOwnedSlice(arena);
    }

    pub fn apply(
        io: std.Io,
        arena: std.mem.Allocator,
        engine: *Engine,
        baseline: *const Baseline,
        lang: language.Name,
        source: []const u8,
        path: []const u8,
        diagnostics: []lint.diagnostic.Diagnostic,
    ) !void {
        // Rules added or raised after the baseline ref had no enforcing error.
        // Demote them before matching historical findings.
        var has_error = false;
        for (diagnostics) |*d| {
            if (d.severity != .@"error") continue;
            if (containsId(baseline.backdated, d.rule_id)) {
                d.severity = .warn;
                d.demoted = true;
                continue;
            }

            has_error = true;
        }
        if (!has_error) return;

        const repo_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ baseline.prefix, path });

        // A file absent at the ref has no historical findings to demote.
        const baseline_source = (try git.showFile(io, arena, baseline.dir, baseline.ref, repo_path, fs.source.max_file_bytes)) orelse return;
        const before = try engine.lint(arena, baseline_source, lang, path);
        try lint.fingerprint.assign(arena, path, baseline_source, before);
        _ = try lint.baseline.demote(arena, source, diagnostics, baseline_source, before);
    }

    fn repoBase(arena: std.mem.Allocator, prefix: []const u8, root: []const u8) ![]const u8 {
        const trimmed = std.mem.trimEnd(u8, root, "/");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) return prefix;
        const cleaned = if (std.mem.startsWith(u8, trimmed, "./")) trimmed[2..] else trimmed;

        return std.fmt.allocPrint(arena, "{s}{s}/", .{ prefix, cleaned });
    }

    fn appendEnabledAfterRef(
        arena: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
        rule_set: *const lint.RuleSet,
        ref_files: []const []const u8,
    ) !void {
        for (std.enums.values(language.Name)) |lang| {
            for (rule_set.get(lang)) |raw| {
                try appendIfMissingAtRef(arena, out, raw, ref_files);
            }
        }

        for (rule_set.projectRaws()) |raw| {
            try appendIfMissingAtRef(arena, out, raw, ref_files);
        }
    }

    fn appendIfMissingAtRef(
        arena: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
        raw: lint.rule.RawRule,
        ref_files: []const []const u8,
    ) !void {
        if (raw.origin != .project) return;
        if (containsId(out.items, raw.id)) return;

        const suffix = try std.fmt.allocPrint(arena, "/{s}{s}", .{ raw.id, fs.rules.kata_suffix });
        for (ref_files) |path| {
            if (std.mem.endsWith(u8, path, suffix)) return;
        }

        try out.append(arena, raw.id);
    }

    fn appendRaisedAfterRef(
        arena: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
        bytes: []const u8,
    ) !void {
        var diag: sources.config.Diagnostic = .{};
        const cfg = sources.config.parse(arena, bytes, &diag) catch return;

        for (cfg.settings) |setting| {
            if (setting.project) continue;
            if (containsId(out.items, setting.id)) continue;
            if (!setting.enabled or (setting.severity orelse .@"error") == .warn) try out.append(arena, setting.id);
        }
    }

    fn containsId(ids: []const []const u8, id: []const u8) bool {
        for (ids) |candidate| {
            if (std.mem.eql(u8, candidate, id)) return true;
        }

        return false;
    }
};
