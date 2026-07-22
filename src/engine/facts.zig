const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const fs_path = @import("path");
const family_mod = @import("family/family.zig");
const language = @import("language.zig");
const query = @import("query.zig");
const Node = @import("node.zig").Node;

pub const ClassDef = struct {
    name: []const u8,
    start: u32,
    end: u32,
    range: diagnostic.Range,
};

pub const MethodDef = struct {
    name: []const u8,
    container: []const u8,
    start: u32,
    end: u32,
    range: diagnostic.Range,
};

pub const TypedDecl = struct {
    name: []const u8,
    type_name: []const u8,
    start: u32,
    range: diagnostic.Range,
};

pub const Call = struct {
    receiver: []const u8,
    method: []const u8,
    container: []const u8,
    start: u32,
    range: diagnostic.Range,
};

pub const Import = struct {
    name: []const u8,
    source: []const u8,
    start: u32,
    range: diagnostic.Range,
};

pub const FileFacts = struct {
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    lang: language.Name,
    classes: []const ClassDef,
    methods: []const MethodDef,
    typed_decls: []const TypedDecl,
    calls: []const Call,
    imports: []const Import,

    pub fn deinit(self: *FileFacts) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();

        child.destroy(self.arena);
    }
};

pub const Role = enum {
    class_node,
    class_name,
    method_node,
    method_name,
    method_recv,
    decl_name,
    decl_type,
    decl_ctor,
    call_node,
    call_receiver,
    call_method,
    import_name,
    import_source,
};

const role_count = @typeInfo(Role).@"enum".fields.len;

const Lists = struct {
    classes: std.ArrayList(ClassDef) = .empty,
    methods: std.ArrayList(MethodDef) = .empty,
    typed_decls: std.ArrayList(TypedDecl) = .empty,
    calls: std.ArrayList(Call) = .empty,
    imports: std.ArrayList(Import) = .empty,
};

const ExtractionSink = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    constructor_prefix: ?[]const u8,
    lists: *Lists,
    done: bool = false,

    pub fn emit(self: *ExtractionSink, bindings: []const ?Node) std.mem.Allocator.Error!void {
        try assemble(self.arena, self.source, .{ .nodes = bindings }, self.constructor_prefix, self.lists);
    }
};

pub fn receiverType(file: *const FileFacts, receiver: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;

    for (file.typed_decls) |decl| {
        if (!std.mem.eql(u8, decl.name, receiver)) continue;

        if (found) |existing| {
            if (!std.mem.eql(u8, existing, decl.type_name)) return null;
        } else {
            found = decl.type_name;
        }
    }

    return found;
}

pub fn resolveImportSource(
    allocator: std.mem.Allocator,
    fam: family_mod.Family,
    importer_path: []const u8,
    specifier: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    if (!family_mod.of(fam).relative_import_specifiers) return specifier;
    if (!isRelativeSpecifier(specifier)) return specifier;

    return resolveRelative(allocator, importer_path, specifier);
}

fn isRelativeSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
}

fn resolveRelative(
    allocator: std.mem.Allocator,
    importer_path: []const u8,
    specifier: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    const dir = fs_path.parentDir(importer_path);
    var dir_it = std.mem.tokenizeScalar(u8, dir, '/');
    while (dir_it.next()) |segment| try segments.append(allocator, segment);

    var spec_it = std.mem.tokenizeScalar(u8, specifier, '/');
    while (spec_it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;

        if (std.mem.eql(u8, segment, "..")) {
            if (segments.pop() == null) return null;

            continue;
        }

        try segments.append(allocator, segment);
    }

    return try std.mem.join(allocator, "/", segments.items);
}

pub fn extract(
    gpa: std.mem.Allocator,
    root: Node,
    source: []const u8,
    path: []const u8,
    lang: language.Name,
) !FileFacts {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);

    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();

    const arena = arena_ptr.allocator();

    var lists: Lists = .{};

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    const adapter = family_mod.of(lang.family());
    for (adapter.fact_patterns) |*pattern| {
        _ = scratch.reset(.retain_capacity);
        var sink: ExtractionSink = .{
            .arena = arena,
            .source = source,
            .constructor_prefix = adapter.constructor_prefix,
            .lists = &lists,
        };
        try query.stream(scratch.allocator(), pattern, role_count, root, &sink);
    }

    sortByStart(ClassDef, lists.classes.items);
    sortByStart(MethodDef, lists.methods.items);
    sortByStart(TypedDecl, lists.typed_decls.items);
    sortByStart(Call, lists.calls.items);
    sortByStart(Import, lists.imports.items);

    adapter.resolveContainers(lists.classes.items, lists.methods.items, lists.calls.items);

    return .{
        .arena = arena_ptr,
        .path = try arena.dupe(u8, path),
        .lang = lang,
        .classes = lists.classes.items,
        .methods = lists.methods.items,
        .typed_decls = lists.typed_decls.items,
        .calls = lists.calls.items,
        .imports = lists.imports.items,
    };
}

pub fn cap(role: Role) query.CaptureId {
    return @intFromEnum(role);
}

fn assemble(
    arena: std.mem.Allocator,
    source: []const u8,
    match: query.Match,
    constructor_prefix: ?[]const u8,
    lists: *Lists,
) !void {
    if (match.get(cap(.method_name))) |name_node| {
        const span_node = match.get(cap(.method_node)) orelse name_node;

        try lists.methods.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .container = if (match.get(cap(.method_recv))) |recv| try nodeText(arena, source, recv) else "",
            .start = span_node.startByte(),
            .end = span_node.endByte(),
            .range = span_node.range(),
        });

        return;
    }
    if (match.get(cap(.class_name))) |name_node| {
        const span_node = match.get(cap(.class_node)) orelse name_node;

        try lists.classes.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .start = span_node.startByte(),
            .end = span_node.endByte(),
            .range = span_node.range(),
        });
    }

    if (match.get(cap(.decl_name))) |name_node| {
        if (!isFirstInExpressionList(name_node)) return;

        const type_name = try declTypeName(arena, source, match, constructor_prefix) orelse return;

        try lists.typed_decls.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .type_name = type_name,
            .start = name_node.startByte(),
            .range = name_node.range(),
        });

        return;
    }

    if (match.get(cap(.call_method))) |method_node| {
        const span_node = match.get(cap(.call_node)) orelse method_node;

        try lists.calls.append(arena, .{
            .receiver = if (match.get(cap(.call_receiver))) |recv| try nodeText(arena, source, recv) else "",
            .method = try nodeText(arena, source, method_node),
            .container = "",
            .start = span_node.startByte(),
            .range = span_node.range(),
        });

        return;
    }

    if (match.get(cap(.import_source))) |source_node| {
        const raw = try nodeText(arena, source, source_node);

        try lists.imports.append(arena, .{
            .name = if (match.get(cap(.import_name))) |name| try nodeText(arena, source, name) else "",
            .source = std.mem.trim(u8, raw, "\""),
            .start = source_node.startByte(),
            .range = source_node.range(),
        });

        return;
    }
}

fn isFirstInExpressionList(name_node: Node) bool {
    const parent = name_node.parent() orelse return true;
    if (!std.mem.eql(u8, parent.kind(), "expression_list")) return true;

    const first = parent.namedChild(0) orelse return false;

    return first.eql(name_node);
}

fn declTypeName(
    arena: std.mem.Allocator,
    source: []const u8,
    match: query.Match,
    constructor_prefix: ?[]const u8,
) !?[]const u8 {
    if (match.get(cap(.decl_type))) |type_node| return try nodeText(arena, source, type_node);

    const prefix = constructor_prefix orelse return null;
    const ctor_node = match.get(cap(.decl_ctor)) orelse return null;
    const ctor = nodeSlice(source, ctor_node);

    if (!std.mem.startsWith(u8, ctor, prefix)) return null;

    const type_name = ctor[prefix.len..];

    if (type_name.len == 0) return null;

    return try arena.dupe(u8, type_name);
}

fn sortByStart(comptime T: type, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn lessThan(_: void, a: T, b: T) bool {
            return a.start < b.start;
        }
    }.lessThan);
}

fn nodeSlice(source: []const u8, node: Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

fn nodeText(arena: std.mem.Allocator, source: []const u8, node: Node) ![]const u8 {
    return arena.dupe(u8, nodeSlice(source, node));
}
