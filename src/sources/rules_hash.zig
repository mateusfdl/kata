const std = @import("std");

const build_options = @import("build_options");
const lint = @import("engine");
const config = @import("config.zig");
const loader = @import("loader.zig");

const language = lint.language;
const rule = lint.rule;

const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn compute(rule_set: *const loader.RuleSet, resolved: config.Resolved) [32]u8 {
    var hasher = Sha256.init(.{});

    field(&hasher, build_options.version);

    for (std.enums.values(language.Name)) |name| {
        field(&hasher, name.toString());
        for (rule_set.get(name)) |raw| raws(&hasher, raw);
    }

    field(&hasher, "project");
    for (rule_set.projectRaws()) |raw| raws(&hasher, raw);

    for (resolved.settings) |setting| settings(&hasher, setting);
    for (resolved.project_rules) |pr| projectRules(&hasher, pr);

    byte(&hasher, @intFromBool(resolved.ratchet));
    number(&hasher, resolved.max_matches_per_file);

    var out: [32]u8 = undefined;
    hasher.final(&out);

    return out;
}

fn raws(hasher: *Sha256, raw: rule.RawRule) void {
    field(hasher, raw.id);
    field(hasher, raw.source);
    byte(hasher, @intFromEnum(raw.origin));
}

fn settings(hasher: *Sha256, setting: rule.RuleSetting) void {
    field(hasher, setting.id);
    field(hasher, if (setting.lang) |l| l.toString() else "");
    byte(hasher, @intFromBool(setting.project));
    byte(hasher, @intFromBool(setting.enabled));
    byte(hasher, @intFromBool(setting.enabled_explicit));
    byte(hasher, if (setting.severity) |s| @as(u8, @intFromEnum(s)) + 1 else 0);
    byte(hasher, if (setting.fix) |f| @as(u8, @intFromEnum(f)) + 1 else 0);
    number(hasher, setting.max_matches orelse std.math.maxInt(u32));
    for (setting.exclude) |glob| field(hasher, glob);
}

fn projectRules(hasher: *Sha256, pr: lint.project_rule.ProjectRule) void {
    field(hasher, pr.id);
    byte(hasher, @intFromEnum(std.meta.activeTag(pr.kind)));
    switch (pr.kind) {
        .restricted_callers => |k| {
            field(hasher, k.callee_suffix);
            field(hasher, k.caller_suffix);
        },
        .import_boundary => |k| {
            field(hasher, k.from);
            field(hasher, k.deny);
        },
    }
}

fn field(hasher: *Sha256, bytes: []const u8) void {
    number(hasher, @intCast(bytes.len));
    hasher.update(bytes);
}

fn number(hasher: *Sha256, value: u32) void {
    hasher.update(&std.mem.toBytes(value));
}

fn byte(hasher: *Sha256, value: u8) void {
    hasher.update(&.{value});
}
