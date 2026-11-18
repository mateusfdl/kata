const std = @import("std");

const fs = @import("../fs.zig");
const git = @import("git");
const lint = @import("engine");
const sources = @import("../sources.zig");

const Engine = lint.Engine;
const FileDiagnostics = @import("file_diagnostics.zig").FileDiagnostics;
const RuleIds = std.StringArrayHashMapUnmanaged(void);
const Backdated = std.EnumArray(lint.language.Name, RuleIds);

const RepoPath = struct { value: []const u8 };

/// Git receives paths relative to the repository root, independent of the process cwd.
const RefTree = struct {
    io: std.Io,
    root: []const u8,
    cwd: []const u8,
    ref: []const u8,

    fn path(tree: RefTree, arena: std.mem.Allocator, working_path: []const u8) !RepoPath {
        const absolute = try std.fs.path.resolve(arena, &.{ tree.cwd, working_path });
        const relative = try std.fs.path.relative(arena, tree.cwd, null, tree.root, absolute);
        if (std.mem.eql(u8, relative, "..") or std.mem.startsWith(u8, relative, "../") or std.fs.path.isAbsolute(relative))
            return error.PathOutsideWorkTree;
        return .{ .value = relative };
    }

    fn file(tree: RefTree, arena: std.mem.Allocator, repo_path: RepoPath) !?[]const u8 {
        var dir = try std.Io.Dir.openDirAbsolute(tree.io, tree.root, .{});
        defer dir.close(tree.io);
        return git.showFile(tree.io, arena, dir, tree.ref, repo_path.value, fs.source.max_file_bytes);
    }

    fn files(tree: RefTree, arena: std.mem.Allocator, repo_path: RepoPath) ![]const u8 {
        var dir = try std.Io.Dir.openDirAbsolute(tree.io, tree.root, .{});
        defer dir.close(tree.io);
        return (try git.listFiles(tree.io, arena, dir, tree.ref, repo_path.value, fs.source.max_file_bytes)) orelse "";
    }
};

/// Errors that the baseline ref already had are not new. A check with a
/// baseline shows them as warnings, so only new errors fail the check.
pub const Baseline = struct {
    tree: RefTree,
    /// Rules that did not enforce an error at the ref.
    backdated: Backdated,

    /// Selects the Git work tree that owns `target`. Paths supplied later are
    /// resolved against the cwd captured here. `root` is the optional project root.
    pub fn open(
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        target: []const u8,
        ref: []const u8,
        root: ?[]const u8,
        rule_set: *const lint.RuleSet,
    ) !Baseline {
        const cwd = try std.process.currentPathAlloc(io, arena);
        const absolute = try std.fs.path.resolve(arena, &.{ cwd, target });
        const repo_root = (try git.findRoot(io, arena, absolute)) orelse return error.NotAWorkTree;
        var dir = try std.Io.Dir.openDirAbsolute(io, repo_root, .{});
        defer dir.close(io);
        try git.verifyRef(io, gpa, dir, ref);

        const tree: RefTree = .{
            .io = io,
            .root = repo_root,
            .cwd = cwd,
            .ref = ref,
        };

        var backdated: Backdated = .initFill(.empty);
        if (root) |project_root| {
            const project_dir = try std.fs.path.join(arena, &.{ project_root, fs.discover.project_dir_name });

            try addRulesAddedAfterRef(arena, &backdated, tree, project_dir, rule_set);
            try addRulesRaisedAfterRef(arena, &backdated, tree, project_dir);
        }

        return .{ .tree = tree, .backdated = backdated };
    }

    pub fn demote(
        baseline: *const Baseline,
        arena: std.mem.Allocator,
        engine: *Engine,
        result: FileDiagnostics,
    ) !void {
        const diagnostics = result.diagnostics;
        const repo_path = try baseline.tree.path(arena, result.path);
        // rules added or raised after the baseline ref had no enforcing error.
        // demote them before matching historical findings.
        for (diagnostics) |*d| {
            if (d.severity == .@"error" and baseline.backdated.get(result.language).contains(d.rule_id)) {
                d.severity = .warn;
                d.demoted = true;
            }
        }
        if (!lint.diagnostic.hasErrors(diagnostics)) return;

        // a file absent at the ref has no historical findings to demote.
        const baseline_source = (try baseline.tree.file(arena, repo_path)) orelse return;
        const before = try engine.lint(arena, baseline_source, result.language, result.path);
        try lint.fingerprint.assign(arena, result.path, baseline_source, before);
        _ = try lint.baseline.demote(arena, result.source, diagnostics, baseline_source, before);
    }
};

/// A project rule whose file is not in the tree of the ref.
fn addRulesAddedAfterRef(
    arena: std.mem.Allocator,
    backdated: *Backdated,
    tree: RefTree,
    project_dir: []const u8,
    rule_set: *const lint.RuleSet,
) !void {
    const rules_dir = try tree.path(arena, try std.fs.path.join(arena, &.{ project_dir, "rules" }));
    const rule_files = try tree.files(arena, rules_dir);

    for (std.enums.values(lint.language.Name)) |lang| {
        for (rule_set.get(lang)) |raw| {
            if (!existedAtRef(raw, lang, rules_dir, rule_files)) try backdated.getPtr(lang).put(arena, raw.id, {});
        }
    }
}

/// Only project rules have a file in the repository. Every other rule counts
/// as present at the ref.
fn existedAtRef(raw: lint.rule.RawRule, lang: lint.language.Name, rules_dir: RepoPath, rule_files: []const u8) bool {
    if (raw.origin != .project) return true;

    var paths = std.mem.splitScalar(u8, rule_files, '\n');
    while (paths.next()) |path| {
        if (!std.mem.startsWith(u8, path, rules_dir.value)) continue;
        const relative = path[rules_dir.value.len..];
        if (relative.len == 0 or relative[0] != '/') continue;
        var parts = std.mem.splitScalar(u8, relative[1..], '/');
        const scope = parts.next() orelse continue;
        const file = parts.next() orelse continue;
        if (parts.next() != null) continue;
        const id = fs.rules.ruleId(file) orelse continue;
        if (!std.mem.eql(u8, id, raw.id)) continue;
        var langs_buf: [lint.language.max_langs_per_dir]lint.language.Name = undefined;
        const langs = lint.language.parseDirName(scope, &langs_buf) catch continue;
        if (std.mem.indexOfScalar(lint.language.Name, langs, lang) != null) return true;
    }

    return false;
}

/// A rule that the rules.yaml of the ref had off or at warn severity.
fn addRulesRaisedAfterRef(
    arena: std.mem.Allocator,
    backdated: *Backdated,
    tree: RefTree,
    project_dir: []const u8,
) !void {
    const yaml = (try tree.file(arena, try tree.path(arena, try std.fs.path.join(arena, &.{ project_dir, "rules.yaml" })))) orelse return;

    var diag: sources.config.Diagnostic = .{};
    // the rules.yaml at the ref can be older than this parser. one that does
    // not parse backdates nothing; it must not fail the check of today's tree.
    const cfg = sources.config.parse(arena, yaml, &diag) catch return;

    for (cfg.settings) |setting| {
        if (setting.project) continue;
        const lang = setting.lang orelse continue;

        const enforced = setting.enabled and (setting.severity orelse .@"error") == .@"error";
        if (!enforced) try backdated.getPtr(lang).put(arena, setting.id, {});
    }
}
