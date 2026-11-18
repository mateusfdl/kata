const args = @import("args.zig");
const endpoint = @import("daemon_endpoint.zig");
const output = @import("output.zig");
const server = @import("../server.zig");

const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

pub const name = "stop";
pub const synopsis = "stop";

pub const Args = struct {};

pub const grammar = args.grammar(Args, .{ .flags = .{}, .positionals = .{} });

pub fn execute(env: Env, _: Args) !Exit {
    const socket_path = endpoint.socketPath(env) catch |err|
        return output.internal(env.stderr, "resolve socket path", err);

    if (server.client.request(env.io, env.arena, socket_path, .{ .shutdown = true }) == null) {
        try env.stderr.writeAll("no kata daemon running\n");
        try env.stderr.flush();

        return .clean;
    }

    try env.stdout.writeAll("kata daemon stopped\n");
    try env.stdout.flush();

    return .clean;
}
