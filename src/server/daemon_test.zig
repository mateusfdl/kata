const std = @import("std");

const lint = @import("engine");
const daemon = @import("daemon.zig");
const protocol = @import("protocol.zig");
const replay = @import("replay.zig");
const fs = @import("../fs.zig");
const test_fixture = @import("../test_fixture.zig");
const test_frame = @import("../test_frame.zig");

fn newFixture(gpa: std.mem.Allocator) !*test_fixture.Fixture {
    return test_fixture.Fixture.init(gpa, &.{ .ts, .tsx }, "no-as-any", test_fixture.no_as_any_rule);
}

fn newFixtureWithSettings(gpa: std.mem.Allocator, settings: []const lint.rule.RuleSetting) !*test_fixture.Fixture {
    return test_fixture.Fixture.initWithSettings(gpa, &.{ .ts, .tsx }, "no-as-any", test_fixture.no_as_any_rule, settings);
}

fn context(f: *test_fixture.Fixture) daemon.Context {
    return .{ .engine = &f.engine, .io = std.testing.io };
}

test "daemon: clean source replies ok with an empty report" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .language = "ts",
        .source = "const x: string = \"ok\";",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
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
    try std.testing.expectEqualStrings("f8442f8df97b699227020f1ca99a3d34007e51a6f4a3934089158471a8f2963b", d.fingerprint);
}

test "daemon: a missing source replies fail" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
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
    const report = parsed.value.report.?;
    try std.testing.expectEqualStrings("ts", report.language);
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqualStrings("as any is not allowed", report.diagnostics[0].message);
}

test "daemon: answers a client-encoded request over a unix socket" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const socket_path = try std.fmt.allocPrint(a, "{s}/kata-test.sock", .{dir});

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);

    const client_stream = try address.connect(io);
    defer client_stream.close(io);

    var client_write_buf: [4096]u8 = undefined;
    var client_writer = client_stream.writer(io, &client_write_buf);
    try protocol.encode(a, &client_writer.interface, protocol.Request{
        .language = "ts",
        .source = "const x = (foo[0] as any).bar;",
    });

    const served = try listener.accept(io);
    defer served.close(io);

    var server_read_buf: [4096]u8 = undefined;
    var server_write_buf: [4096]u8 = undefined;
    var server_reader = served.reader(io, &server_read_buf);
    var server_writer = served.writer(io, &server_write_buf);

    const stop = daemon.processConnection(gpa, context(f), &server_reader.interface, &server_writer.interface);
    try std.testing.expect(!stop);

    var client_read_buf: [4096]u8 = undefined;
    var client_reader = client_stream.reader(io, &client_read_buf);
    const parsed = try protocol.decode(protocol.Response, a, &client_reader.interface);

    try std.testing.expectEqual(protocol.Status.ok, parsed.value.status);
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

test "daemon: rule fixtures are skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "ts+tsx/tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "ts+tsx/no-as-any.kata", .data = "rule no-as-any {}\n" });

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(arena.allocator(), "{s}/ts+tsx/tests/no-as-any.ts", .{dir});

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .filename = filename,
        .source = "const x = (foo[0] as any).bar;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expectEqualStrings("ts", report.language);
    try std.testing.expect(report.clean);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
}

const repository_isolation = [_]@import("engine").project_rule.ProjectRule{.{
    .id = "repository-isolation",
    .kind = .{ .restricted_callers = .{
        .callee_suffix = "Repository",
        .caller_suffix = "Repository",
    } },
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

    var state = try lint.Project.init(gpa, &f.engine, &repository_isolation);
    defer state.deinit();
    try state.replace(user_repository_src, .ts, "/proj/user-repository.ts");
    try state.replace(order_service_src, .ts, "/proj/other-service.ts");

    var ctx = context(f);
    ctx.project = &state;

    const resp = daemon.handle(ctx, arena.allocator(), .{
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

test "daemon: project violations demoted by warnings leave the report clean" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixtureWithSettings(gpa, &.{.{ .lang = null, .id = "repository-isolation", .project = true, .severity = .warn }});
    defer f.deinit();

    var state = try lint.Project.init(gpa, &f.engine, &repository_isolation);
    defer state.deinit();
    try state.replace(user_repository_src, .ts, "/proj/user-repository.ts");
    try state.replace(order_service_src, .ts, "/proj/other-service.ts");

    var ctx = context(f);
    ctx.project = &state;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/proj/order-service.ts",
        .source = order_service_src,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, report.diagnostics[0].severity);
}

test "daemon: lint requests update the project index incrementally" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var state = try lint.Project.init(gpa, &f.engine, &repository_isolation);
    defer state.deinit();
    try state.replace(user_repository_src, .ts, "/proj/user-repository.ts");

    var ctx = context(f);
    ctx.project = &state;

    const first = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/proj/order-service.ts",
        .source = order_service_src,
    });
    try std.testing.expectEqual(@as(usize, 1), first.report.?.diagnostics.len);

    const second = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/proj/order-service.ts",
        .source = fixed_order_service_src,
    });
    try std.testing.expect(second.report.?.clean);
    try std.testing.expectEqual(@as(usize, 0), second.report.?.diagnostics.len);
}

test "daemon: requests without a filename skip project analysis" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var state = try lint.Project.init(gpa, &f.engine, &repository_isolation);
    defer state.deinit();
    try state.replace(user_repository_src, .ts, "/proj/user-repository.ts");

    var ctx = context(f);
    ctx.project = &state;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .language = "ts",
        .source = order_service_src,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    try std.testing.expect(resp.report.?.clean);
}

test "daemon: language is inferred from the filename" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .filename = "/tmp/component.tsx",
        .source = "const C = () => <div>{(props as any).label}</div>;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    try std.testing.expectEqualStrings("tsx", resp.report.?.language);
    try std.testing.expectEqual(@as(usize, 1), resp.report.?.diagnostics.len);
}

test "daemon: warn-only diagnostics keep the report clean" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const warn_rule =
        \\rule no-as-any {
        \\  lang ts
        \\  severity warn
        \\  match as_expression @match {
        \\    child: predefined_type @t
        \\  }
        \\  where { text(@t) == "any" }
        \\  emit @match { message "as any is not allowed" }
        \\}
    ;
    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", warn_rule);
    defer f.deinit();

    const resp = daemon.handle(context(f), arena.allocator(), .{
        .language = "ts",
        .source = "const x = (foo[0] as any).bar;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, report.diagnostics[0].severity);
}

const ratchet_disk_one_violation = "const a = x as any;\n";
const ratchet_proposed_moved = "const clean: string = \"ok\";\nconst a = x as any;\n";
const ratchet_proposed_replacement = "const b = y as any;\n";
const ratchet_proposed_growth = "const a = x as any;\nconst b = y as any;\n";

fn ratchetContext(f: *test_fixture.Fixture, io: std.Io) daemon.Context {
    return .{ .engine = &f.engine, .io = io, .ratchet = true };
}

test "daemon: ratchet demotes an unchanged violation to warn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = ratchet_disk_one_violation });

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(arena.allocator(), "{s}/a.ts", .{dir});

    const resp = daemon.handle(ratchetContext(f, io), arena.allocator(), .{
        .filename = filename,
        .source = ratchet_proposed_moved,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, report.diagnostics[0].severity);
    try std.testing.expectEqual(true, report.diagnostics[0].demoted);
}

test "daemon: ratchet keeps a replacement violation as error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = ratchet_disk_one_violation });

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(arena.allocator(), "{s}/a.ts", .{dir});

    const resp = daemon.handle(ratchetContext(f, io), arena.allocator(), .{
        .filename = filename,
        .source = ratchet_proposed_replacement,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.@"error", report.diagnostics[0].severity);
    try std.testing.expectEqual(false, report.diagnostics[0].demoted);
}

test "daemon: ratchet keeps violation growth as error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = ratchet_disk_one_violation });

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(arena.allocator(), "{s}/a.ts", .{dir});

    const resp = daemon.handle(ratchetContext(f, io), arena.allocator(), .{
        .filename = filename,
        .source = ratchet_proposed_growth,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, report.diagnostics[0].severity);
    try std.testing.expectEqual(true, report.diagnostics[0].demoted);
    try std.testing.expectEqual(lint.diagnostic.Severity.@"error", report.diagnostics[1].severity);
    try std.testing.expectEqual(false, report.diagnostics[1].demoted);
}

test "daemon: ratchet treats a missing file as zero baseline" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(arena.allocator(), "{s}/new.ts", .{dir});

    const resp = daemon.handle(ratchetContext(f, io), arena.allocator(), .{
        .filename = filename,
        .source = ratchet_disk_one_violation,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.@"error", report.diagnostics[0].severity);
}

test "daemon: ratchet baseline follows the current disk state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = ratchet_disk_one_violation });

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(arena.allocator(), "{s}/a.ts", .{dir});

    const first = daemon.handle(ratchetContext(f, io), arena.allocator(), .{
        .filename = filename,
        .source = ratchet_proposed_moved,
    });
    try std.testing.expect(first.report.?.clean);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const clean: string = \"ok\";\n" });

    const second = daemon.handle(ratchetContext(f, io), arena.allocator(), .{
        .filename = filename,
        .source = ratchet_proposed_moved,
    });
    try std.testing.expect(!second.report.?.clean);
    try std.testing.expectEqual(lint.diagnostic.Severity.@"error", second.report.?.diagnostics[0].severity);
}

test "daemon: ratchet compares error counts so warn diagnostics never mask error growth" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const mixed_rule =
        \\rule no-as-any {
        \\  lang ts
        \\  match as_expression @match {
        \\    child: predefined_type @t
        \\  }
        \\  where { text(@t) == "any" }
        \\  emit @match { message "as any is not allowed" }
        \\}
        \\rule no-as-any {
        \\  lang ts
        \\  severity warn
        \\  match non_null_expression @match
        \\  emit @match { message "no non-null assertions" }
        \\}
    ;
    var f = try test_fixture.Fixture.init(gpa, &.{.ts}, "no-as-any", mixed_rule);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const a = x as any;\nconst b = y!;\n" });

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(arena.allocator(), "{s}/a.ts", .{dir});

    const resp = daemon.handle(ratchetContext(f, io), arena.allocator(), .{
        .filename = filename,
        .source = "const a = x as any;\nconst c = z as any;\n",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, report.diagnostics[0].severity);
    try std.testing.expectEqual(true, report.diagnostics[0].demoted);
    try std.testing.expectEqual(lint.diagnostic.Severity.@"error", report.diagnostics[1].severity);
    try std.testing.expectEqual(false, report.diagnostics[1].demoted);
}

test "daemon: ratchet without filename leaves severity untouched" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var ctx = context(f);
    ctx.ratchet = true;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .language = "ts",
        .source = ratchet_disk_one_violation,
    });

    try std.testing.expect(!resp.report.?.clean);
    try std.testing.expectEqual(lint.diagnostic.Severity.@"error", resp.report.?.diagnostics[0].severity);
}

const sources = @import("../sources.zig");

const ProjectHarness = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    resolver: sources.context.Resolver,
    cache: sources.context.Cache,

    fn init() !*ProjectHarness {
        const gpa = std.testing.allocator;
        const self = try gpa.create(ProjectHarness);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .arena = .init(gpa),
            .resolver = undefined,
            .cache = undefined,
        };
        self.resolver = .{
            .gpa = gpa,
            .io = std.testing.io,
        };
        self.cache = sources.context.Cache.init(gpa, &self.resolver);
        return self;
    }

    fn deinit(self: *ProjectHarness) void {
        const gpa = std.testing.allocator;
        self.cache.deinit();
        self.tmp.cleanup();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn path(self: *ProjectHarness, sub: []const u8) ![]const u8 {
        var rel_buf: [256]u8 = undefined;
        const rel = try test_fixture.relativeTmpPath(&rel_buf, &self.tmp.sub_path);
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ rel, sub });
    }
};

test "daemon: file outside any project falls back to the daemon engine" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();
    var h = try ProjectHarness.init();
    defer h.deinit();

    var ctx = context(f);
    ctx.cache = &h.cache;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/kata-daemon-test-absent/main.ts",
        .source = "const x = (foo[0] as any).bar;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqualStrings("no-as-any", report.diagnostics[0].rule_id);
    try std.testing.expectEqualStrings("as any is not allowed", report.diagnostics[0].message);
}

test "daemon: project ratchet demotes unchanged violations while the daemon default stays absolute" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();
    var h = try ProjectHarness.init();
    defer h.deinit();

    try h.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try h.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "ratchet: true\nrules:\n  ts:\n    flag-zzz:\n" });
    try h.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/flag-zzz.kata", .data = flag_zzz_kata_rule });
    try h.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const zzz = 1;\n" });

    var ctx = context(f);
    ctx.cache = &h.cache;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .filename = try h.path("proj/a.ts"),
        .source = "const zzz = 2;\n",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, report.diagnostics[0].severity);
}

test "daemon: broken project rules yaml fails the request" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();
    var h = try ProjectHarness.init();
    defer h.deinit();

    try h.tmp.dir.createDirPath(io, "proj/.kata");
    try h.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "nonsense: true\n" });
    try h.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const ok = 1;\n" });

    var ctx = context(f);
    ctx.cache = &h.cache;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .filename = try h.path("proj/a.ts"),
        .source = "const ok = 1;",
    });

    try std.testing.expectEqual(protocol.Status.fail, resp.status);
    try std.testing.expectEqualStrings("project context failed", resp.message.?);
}

const flag_zzz_kata_rule =
    \\rule flag-zzz {
    \\  lang ts
    \\  match identifier @match
    \\  where { text(@match) == "zzz" }
    \\  emit @match { message "zzz is banned here" }
    \\}
;

test "daemon: cached project context lints with kata project rules" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();
    var h = try ProjectHarness.init();
    defer h.deinit();

    try h.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try h.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  ts:\n    flag-zzz:\n" });
    try h.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/flag-zzz.kata", .data = flag_zzz_kata_rule });
    try h.tmp.dir.writeFile(io, .{ .sub_path = "proj/main.ts", .data = "const ok = 1;\n" });

    var ctx = context(f);
    ctx.cache = &h.cache;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .filename = try h.path("proj/main.ts"),
        .source = "const zzz = 1;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqualStrings("flag-zzz", report.diagnostics[0].rule_id);
    try std.testing.expectEqualStrings("zzz is banned here", report.diagnostics[0].message);
}

const fact_repository_isolation = [_]@import("engine").fact_rule.CompiledFactRule{.{
    .id = "repository-isolation",
    .fact = .call,
    .predicates = &.{
        .{ .op = .ends_with, .args = &.{ .receiver_type, .{ .literal = "Repository" } } },
        .{ .op = .not_ends_with, .args = &.{ .{ .field = .container }, .{ .literal = "Repository" } } },
    },
    .message = &.{.{ .literal = "repositories can only be called by repositories" }},
}};

test "daemon: project kata rules flag a write" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    f.engine.compiled_fact = &fact_repository_isolation;
    var state = try lint.Project.init(gpa, &f.engine, &.{});
    defer state.deinit();
    try state.replace(user_repository_src, .ts, "/proj/user-repository.ts");

    var ctx = context(f);
    ctx.project = &state;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/proj/order-service.ts",
        .source = order_service_src,
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqualStrings("repository-isolation", report.diagnostics[0].rule_id);
    try std.testing.expectEqualStrings(
        "repositories can only be called by repositories",
        report.diagnostics[0].message,
    );
    try std.testing.expectEqual(@as(u32, 4), report.diagnostics[0].range.start.line);
}

test "daemon: sweep unlinks dead kata sockets and spares everything else" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "kata-0.0.1-1.sock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kata.sock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kata-current.sock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.sock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kata-notes.txt", .data = "" });

    var path_buf: [256]u8 = undefined;
    const dir_path = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const socket_path = try std.fmt.allocPrint(gpa, "{s}/kata-current.sock", .{dir_path});
    defer gpa.free(socket_path);

    daemon.sweepStaleSockets(io, gpa, socket_path);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "kata-0.0.1-1.sock", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "kata.sock", .{}));
    _ = try tmp.dir.statFile(io, "kata-current.sock", .{});
    _ = try tmp.dir.statFile(io, "other.sock", .{});
    _ = try tmp.dir.statFile(io, "kata-notes.txt", .{});
}

fn encodeResponse(arena: std.mem.Allocator, resp: protocol.Response) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try protocol.encode(arena, &out.writer, resp);
    return try arena.dupe(u8, out.written());
}

test "daemon: replay returns an identical response for unchanged content" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var cache = try replay.ReplayCache.init(gpa, 16);
    defer cache.deinit();
    var ctx = context(f);
    ctx.replay = &cache;

    const request: protocol.Request = .{
        .filename = "/proj/a.ts",
        .source = "const x = (foo[0] as any).bar;",
    };

    const first = daemon.handle(ctx, arena.allocator(), request);
    const second = daemon.handle(ctx, arena.allocator(), request);

    try std.testing.expectEqual(protocol.Status.ok, second.status);
    try std.testing.expectEqual(@as(usize, 1), second.report.?.diagnostics.len);
    try std.testing.expectEqualStrings(
        try encodeResponse(arena.allocator(), first),
        try encodeResponse(arena.allocator(), second),
    );
}

test "daemon: replay re-lints when content changes" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var cache = try replay.ReplayCache.init(gpa, 16);
    defer cache.deinit();
    var ctx = context(f);
    ctx.replay = &cache;

    const first = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/proj/a.ts",
        .source = "const x = (foo[0] as any).bar;",
    });
    const second = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/proj/a.ts",
        .source = "const x = (foo[0] as any).bar;\nconst y = (foo[1] as any).bar;",
    });

    try std.testing.expectEqual(@as(usize, 1), first.report.?.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), second.report.?.diagnostics.len);
}

test "daemon: replay keeps explicit languages separate for one path" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var cache = try replay.ReplayCache.init(gpa, 16);
    defer cache.deinit();
    var ctx = context(f);
    ctx.replay = &cache;

    const source = "const x = (foo[0] as any).bar;";
    const typescript = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/proj/input",
        .language = "ts",
        .source = source,
    });
    const go = daemon.handle(ctx, arena.allocator(), .{
        .filename = "/proj/input",
        .language = "go",
        .source = source,
    });

    try std.testing.expectEqual(@as(usize, 1), typescript.report.?.diagnostics.len);
    try std.testing.expectEqualStrings("ts", typescript.report.?.language);
    try std.testing.expectEqual(@as(usize, 0), go.report.?.diagnostics.len);
    try std.testing.expectEqualStrings("go", go.report.?.language);
}

test "daemon: ratchet demotion repeats on replayed diagnostics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = ratchet_disk_one_violation });

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(arena.allocator(), "{s}/a.ts", .{dir});

    var cache = try replay.ReplayCache.init(gpa, 16);
    defer cache.deinit();
    var ctx = ratchetContext(f, io);
    ctx.replay = &cache;

    const request: protocol.Request = .{
        .filename = filename,
        .source = ratchet_proposed_growth,
    };

    const first = daemon.handle(ctx, arena.allocator(), request);
    const second = daemon.handle(ctx, arena.allocator(), request);

    try std.testing.expectEqual(lint.diagnostic.Severity.warn, first.report.?.diagnostics[0].severity);
    try std.testing.expectEqual(true, first.report.?.diagnostics[0].demoted);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, second.report.?.diagnostics[0].severity);
    try std.testing.expectEqual(true, second.report.?.diagnostics[0].demoted);
    try std.testing.expectEqualStrings(
        try encodeResponse(arena.allocator(), first),
        try encodeResponse(arena.allocator(), second),
    );
}

test "daemon: project violations appear on a replay hit" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var state = try lint.Project.init(gpa, &f.engine, &repository_isolation);
    defer state.deinit();
    try state.replace(user_repository_src, .ts, "/proj/user-repository.ts");

    var cache = try replay.ReplayCache.init(gpa, 16);
    defer cache.deinit();
    var ctx = context(f);
    ctx.project = &state;
    ctx.replay = &cache;

    const request: protocol.Request = .{
        .filename = "/proj/order-service.ts",
        .source = order_service_src,
    };

    const first = daemon.handle(ctx, arena.allocator(), request);
    const second = daemon.handle(ctx, arena.allocator(), request);

    try std.testing.expectEqualStrings("repository-isolation", first.report.?.diagnostics[0].rule_id);
    try std.testing.expectEqualStrings("repository-isolation", second.report.?.diagnostics[0].rule_id);
    try std.testing.expectEqualStrings(
        try encodeResponse(arena.allocator(), first),
        try encodeResponse(arena.allocator(), second),
    );
}

fn diskCacheDir(arena: std.mem.Allocator, tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const dir = try test_fixture.relativeTmpPath(buf, &tmp.sub_path);

    return std.fmt.allocPrint(arena, "{s}/cache", .{dir});
}

test "daemon: a disk cache hit answers identically to a fresh lint" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;

    var ctx = context(f);
    ctx.cache_dir = try diskCacheDir(a, &tmp, &buf);
    ctx.cache_enabled = true;

    const request: protocol.Request = .{
        .language = "ts",
        .filename = "/proj/clean.ts",
        .source = "const x: string = \"ok\";",
    };

    const cold = daemon.handle(ctx, a, request);
    const warm = daemon.handle(ctx, a, request);

    try std.testing.expect(cold.report.?.clean);
    try std.testing.expect(warm.report.?.clean);
    try std.testing.expectEqualStrings(
        try encodeResponse(a, cold),
        try encodeResponse(a, warm),
    );
}

test "daemon: a changed buffer misses the disk cache" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;

    var ctx = context(f);
    ctx.cache_dir = try diskCacheDir(a, &tmp, &buf);
    ctx.cache_enabled = true;

    const clean = daemon.handle(ctx, a, .{
        .language = "ts",
        .filename = "/proj/a.ts",
        .source = "const x: string = \"ok\";",
    });
    const dirty = daemon.handle(ctx, a, .{
        .language = "ts",
        .filename = "/proj/a.ts",
        .source = "const x = (foo[0] as any).bar;",
    });

    try std.testing.expect(clean.report.?.clean);
    try std.testing.expect(!dirty.report.?.clean);
    try std.testing.expectEqual(@as(usize, 1), dirty.report.?.diagnostics.len);
}

test "daemon: a violating buffer is never marked clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;

    var ctx = context(f);
    ctx.cache_dir = try diskCacheDir(a, &tmp, &buf);
    ctx.cache_enabled = true;

    const source = "const x = (foo[0] as any).bar;";
    _ = daemon.handle(ctx, a, .{ .language = "ts", .filename = "/proj/a.ts", .source = source });

    var content_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &content_hash, .{});
    const h: fs.result_cache.Handle = .{ .dir = ctx.cache_dir.?, .rules_hash = ctx.rules_hash };

    try std.testing.expectEqual(false, h.isClean(io, content_hash, "/proj/a.ts"));
}

test "daemon: the disk cache stays untouched when it is disabled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;

    var ctx = context(f);
    ctx.cache_dir = try diskCacheDir(a, &tmp, &buf);

    const source = "const x: string = \"ok\";";
    _ = daemon.handle(ctx, a, .{ .language = "ts", .filename = "/proj/a.ts", .source = source });

    var content_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &content_hash, .{});
    const h: fs.result_cache.Handle = .{ .dir = ctx.cache_dir.?, .rules_hash = ctx.rules_hash };

    try std.testing.expectEqual(false, h.isClean(io, content_hash, "/proj/a.ts"));
}

test "daemon: a flooding rule is capped in the response but stays unclean" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa);
    defer f.deinit();

    var ctx = context(f);
    ctx.max_matches = 1;

    const resp = daemon.handle(ctx, arena.allocator(), .{
        .language = "ts",
        .source = "const a = v as any;\n" ++
            "const b = v as any;\n" ++
            "const c = v as any;\n" ++
            "const d = v as any;\n" ++
            "const e = v as any;\n",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    const report = resp.report.?;
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 4), report.diagnostics.len);
    try std.testing.expectEqual(false, report.diagnostics[0].capped);
    try std.testing.expectEqual(true, report.diagnostics[3].capped);
    try std.testing.expectEqualStrings(
        "rule no-as-any fired 5 times in this file; showing 3, suppressed 2; a flood usually means a broken pattern or wrong scope",
        report.diagnostics[3].message,
    );
}
