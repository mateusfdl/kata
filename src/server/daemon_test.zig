const std = @import("std");

const daemon = @import("daemon.zig");
const protocol = @import("protocol.zig");
const test_fixture = @import("../test_fixture.zig");
const test_frame = @import("../test_frame.zig");

const daemon_mtime: i64 = 1726000000000;

fn newFixture(gpa: std.mem.Allocator) !*test_fixture.Fixture {
    return test_fixture.Fixture.init(gpa, &.{ .ts, .tsx }, "no-as-any", test_fixture.no_as_any_rule);
}

fn context(f: *test_fixture.Fixture) daemon.Context {
    return .{ .engine = &f.engine, .binary_mtime = daemon_mtime };
}

test "daemon: clean source replies ok with an empty report" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .language = "ts",
        .source = "const x: string = \"ok\";",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    try std.testing.expectEqual(@as(i64, daemon_mtime), resp.binary_mtime);
    try std.testing.expectEqual(@as(?[]const u8, null), resp.message);
    const report = resp.report.?;
    try std.testing.expectEqualStrings("ts", report.language);
    try std.testing.expect(report.clean);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
}

test "daemon: violation replies ok with a populated report" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .language = "ts",
        .source = "const x = (foo[0] as any).bar;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expectEqualStrings("ts", report.language);
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);

    const d = report.diagnostics[0];
    try std.testing.expectEqualStrings("no-as-any", d.rule_id);
    try std.testing.expectEqualStrings("ts", d.language);
    try std.testing.expectEqualStrings("as any is not allowed", d.message);
    try std.testing.expectEqual(@as(u32, 0), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 11), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 0), d.range.end.line);
    try std.testing.expectEqual(@as(u32, 24), d.range.end.column);
}

test "daemon: a mismatched binary mtime replies stale without linting" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .binary_mtime = daemon_mtime + 1,
        .language = "ts",
        .source = "const x = foo as any;",
    });

    try std.testing.expectEqual(protocol.Status.stale, resp.status);
    try std.testing.expectEqual(@as(i64, daemon_mtime), resp.binary_mtime);
    try std.testing.expect(resp.report == null);
    try std.testing.expectEqualStrings("daemon is running a stale binary", resp.message.?);
}

test "daemon: a zero binary mtime skips the stale check" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .binary_mtime = 0,
        .language = "ts",
        .source = "const x = foo as any;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    try std.testing.expectEqual(@as(usize, 1), resp.report.?.diagnostics.len);
}

test "daemon: a missing source replies fail" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .language = "ts",
    });

    try std.testing.expectEqual(protocol.Status.fail, resp.status);
    try std.testing.expectEqualStrings("missing source", resp.message.?);
}

test "daemon: an unsupported language replies fail" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .language = "python",
        .source = "print('hi')",
    });

    try std.testing.expectEqual(protocol.Status.fail, resp.status);
    try std.testing.expectEqualStrings("unsupported language", resp.message.?);
}

test "daemon: processConnection frames a lint response and keeps serving" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const request_bytes = try test_frame.frame(gpa, protocol.Request{
        .binary_mtime = daemon_mtime,
        .language = "ts",
        .source = "const x = (foo[0] as any).bar;",
    });
    defer gpa.free(request_bytes);

    var reader: std.Io.Reader = .fixed(request_bytes);
    var response_buf: std.Io.Writer.Allocating = .init(gpa);
    defer response_buf.deinit();

    const stop = daemon.processConnection(gpa, context(f), &reader, &response_buf.writer);
    try std.testing.expect(!stop);

    var response_reader: std.Io.Reader = .fixed(response_buf.written());
    const parsed = try protocol.decode(protocol.Response, gpa, &response_reader);
    defer parsed.deinit();

    try std.testing.expectEqual(protocol.Status.ok, parsed.value.status);
    try std.testing.expectEqual(@as(i64, daemon_mtime), parsed.value.binary_mtime);
    const report = parsed.value.report.?;
    try std.testing.expectEqualStrings("ts", report.language);
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqualStrings("as any is not allowed", report.diagnostics[0].message);
}

test "daemon: processConnection stops on a shutdown request" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const request_bytes = try test_frame.frame(gpa, protocol.Request{
        .binary_mtime = daemon_mtime,
        .shutdown = true,
    });
    defer gpa.free(request_bytes);

    var reader: std.Io.Reader = .fixed(request_bytes);
    var response_buf: std.Io.Writer.Allocating = .init(gpa);
    defer response_buf.deinit();

    const stop = daemon.processConnection(gpa, context(f), &reader, &response_buf.writer);
    try std.testing.expect(stop);

    var response_reader: std.Io.Reader = .fixed(response_buf.written());
    const parsed = try protocol.decode(protocol.Response, gpa, &response_reader);
    defer parsed.deinit();

    try std.testing.expectEqual(protocol.Status.ok, parsed.value.status);
    try std.testing.expect(parsed.value.report == null);
    try std.testing.expectEqualStrings("shutting down", parsed.value.message.?);
}

test "daemon: processConnection replies fail on a malformed frame" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    var reader: std.Io.Reader = .fixed("Content-Length: 9\r\n\r\n{not json");
    var response_buf: std.Io.Writer.Allocating = .init(gpa);
    defer response_buf.deinit();

    const stop = daemon.processConnection(gpa, context(f), &reader, &response_buf.writer);
    try std.testing.expect(!stop);

    var response_reader: std.Io.Reader = .fixed(response_buf.written());
    const parsed = try protocol.decode(protocol.Response, gpa, &response_reader);
    defer parsed.deinit();

    try std.testing.expectEqual(protocol.Status.fail, parsed.value.status);
    try std.testing.expectEqualStrings("malformed request", parsed.value.message.?);
}

const repository_isolation = [_]@import("../lint.zig").project_rule.ProjectRule{.{
    .id = "repository-isolation",
    .kind = .restricted_callers,
    .callee_suffix = "Repository",
    .caller_suffix = "Repository",
}};

const user_repository_src =
    "export class UserRepository {\n" ++
    "  find(id: number) {}\n" ++
    "}\n";

const order_service_src =
    "import { UserRepository } from \"./user-repository\";\n" ++
    "class OrderService {\n" ++
    "  constructor(private repo: UserRepository) {}\n" ++
    "  create() {\n" ++
    "    this.repo.find(1);\n" ++
    "  }\n" ++
    "}\n";

const fixed_order_service_src =
    "class OrderService {\n" ++
    "  create() {}\n" ++
    "}\n";

test "daemon: project rules report violations for the linted file only" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var state = daemon.ProjectState.init(gpa, &repository_isolation);
    defer state.deinit();
    try state.index.put(try f.engine.extractFacts(gpa, user_repository_src, .ts, "/proj/user-repository.ts"));
    try state.index.put(try f.engine.extractFacts(gpa, order_service_src, .ts, "/proj/other-service.ts"));

    var ctx = context(f);
    ctx.project = &state;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .filename = "/proj/order-service.ts",
        .source = order_service_src,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqualStrings("repository-isolation", report.diagnostics[0].rule_id);
    try std.testing.expectEqualStrings(
        "call to UserRepository.find is restricted to *Repository callers",
        report.diagnostics[0].message,
    );
    try std.testing.expectEqual(@as(u32, 4), report.diagnostics[0].range.start.line);
}

test "daemon: lint requests update the project index incrementally" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var state = daemon.ProjectState.init(gpa, &repository_isolation);
    defer state.deinit();
    try state.index.put(try f.engine.extractFacts(gpa, user_repository_src, .ts, "/proj/user-repository.ts"));

    var ctx = context(f);
    ctx.project = &state;

    const first = daemon.handle(ctx, arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .filename = "/proj/order-service.ts",
        .source = order_service_src,
    });
    try std.testing.expectEqual(@as(usize, 1), first.report.?.diagnostics.len);

    const second = daemon.handle(ctx, arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .filename = "/proj/order-service.ts",
        .source = fixed_order_service_src,
    });
    try std.testing.expect(second.report.?.clean);
    try std.testing.expectEqual(@as(usize, 0), second.report.?.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), state.index.count());
}

test "daemon: requests without a filename skip project analysis" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var state = daemon.ProjectState.init(gpa, &repository_isolation);
    defer state.deinit();
    try state.index.put(try f.engine.extractFacts(gpa, user_repository_src, .ts, "/proj/user-repository.ts"));

    var ctx = context(f);
    ctx.project = &state;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .language = "ts",
        .source = order_service_src,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    try std.testing.expect(resp.report.?.clean);
    try std.testing.expectEqual(@as(usize, 1), state.index.count());
}

test "daemon: language is inferred from the filename" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .binary_mtime = daemon_mtime,
        .filename = "/tmp/component.tsx",
        .source = "const C = () => <div>{(props as any).label}</div>;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    try std.testing.expectEqualStrings("tsx", resp.report.?.language);
    try std.testing.expectEqual(@as(usize, 1), resp.report.?.diagnostics.len);
}
