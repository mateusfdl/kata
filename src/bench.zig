const std = @import("std");

const dsl = @import("dsl");
const lint = @import("engine");

const rule_source =
    \\rule no-as-any {
    \\  lang ts
    \\  match as_expression @match {
    \\    child: predefined_type @type
    \\  }
    \\  where { text(@type) == "any" }
    \\  emit @match { message "as any is not allowed" }
    \\}
;

const metric_rule_source =
    \\rule max-complexity {
    \\  lang ts
    \\  match [function_declaration, function_expression, arrow_function, method_definition] @match
    \\  where { complexity(@match) > 1 }
    \\  emit @match { message "complexity {complexity(@match)} exceeds 1" }
    \\}
;

const source =
    \\import { UserRepository } from "./user-repository";
    \\class UserRepository { save(value: unknown) {} }
    \\class OrderService {
    \\  constructor(private repo: UserRepository) {}
    \\  create(value: unknown) {
    \\    if (value) {
    \\      this.repo.save(value);
    \\    }
    \\    const first = value as any;
    \\    const second = value as any;
    \\    this.repo.save(first);
    \\    return second;
    \\  }
    \\}
;

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocation_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    requested_growth_bytes: usize = 0,
    released_bytes: usize = 0,
    live_bytes: usize = 0,
    baseline_live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *CountingAllocator) void {
        self.allocation_calls = 0;
        self.resize_calls = 0;
        self.remap_calls = 0;
        self.free_calls = 0;
        self.requested_growth_bytes = 0;
        self.released_bytes = 0;
        self.baseline_live_bytes = self.live_bytes;
        self.peak_live_bytes = self.live_bytes;
    }

    fn peakAdditionalBytes(self: CountingAllocator) usize {
        return self.peak_live_bytes - self.baseline_live_bytes;
    }

    fn liveAdditionalBytes(self: CountingAllocator) usize {
        return self.live_bytes - self.baseline_live_bytes;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocation_calls += 1;
        self.requested_growth_bytes += len;
        self.live_bytes += len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resize_calls += 1;
        self.recordResize(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.remap_calls += 1;
        self.recordResize(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
        self.free_calls += 1;
        self.released_bytes += memory.len;
        self.live_bytes -= memory.len;
    }

    fn recordResize(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            const added = new_len - old_len;
            self.requested_growth_bytes += added;
            self.live_bytes += added;
            self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        } else {
            const removed = old_len - new_len;
            self.released_bytes += removed;
            self.live_bytes -= removed;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var counter: CountingAllocator = .{ .child = init.gpa };
    const allocator = counter.allocator();

    var rules: lint.RuleSet = .{ .allocator = allocator };
    defer rules.deinit();
    try rules.append(.ts, .{ .id = "no-as-any", .source = rule_source });
    try rules.append(.ts, .{ .id = "max-complexity", .source = metric_rule_source });

    var engine = lint.Engine.init(allocator, &rules, dsl.engine_compiler.ruleCompiler(), &.{});
    defer engine.deinit();
    try engine.prewarm();

    const project_rules = [_]lint.project_rule.ProjectRule{.{
        .id = "repository-isolation",
        .kind = .{ .restricted_callers = .{ .callee_suffix = "Repository", .caller_suffix = "Controller" } },
    }};
    var project = try lint.Project.init(allocator, &engine, &project_rules);
    defer project.deinit();

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try project.lint(arena.allocator(), source, .ts, "src/order-service.ts");
        _ = try project.diagnostics(arena.allocator(), "src/order-service.ts");
    }

    counter.reset();
    const started = std.Io.Clock.awake.now(init.io);
    var diagnostic_count: usize = 0;
    const iterations: usize = 1000;
    for (0..iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        diagnostic_count += (try project.lint(arena.allocator(), source, .ts, "src/order-service.ts")).len;
        diagnostic_count += (try project.diagnostics(arena.allocator(), "src/order-service.ts")).len;
    }
    const elapsed_ns = started.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print(
        "iterations={d} diagnostics={d} elapsed_ns={d} allocations={d} resizes={d} remaps={d} frees={d} requested_growth_bytes={d} released_bytes={d} peak_additional_bytes={d} live_additional_bytes={d}\n",
        .{
            iterations,
            diagnostic_count,
            elapsed_ns,
            counter.allocation_calls,
            counter.resize_calls,
            counter.remap_calls,
            counter.free_calls,
            counter.requested_growth_bytes,
            counter.released_bytes,
            counter.peakAdditionalBytes(),
            counter.liveAdditionalBytes(),
        },
    );
    try stdout.interface.flush();
}
