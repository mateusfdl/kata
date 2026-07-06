const std = @import("std");
const ts = @import("tree_sitter");

const diagnostic = @import("diagnostic.zig");
const fs_path = @import("../fs/path.zig");
const language = @import("language.zig");

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
    lang: language.Name,
    importer_path: []const u8,
    specifier: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    if (lang == .go or !isRelativeSpecifier(specifier)) return specifier;
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

const go_constructor_prefix = "New";

const Role = enum {
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

fn roleFromCaptureName(name: []const u8) ?Role {
    const table = [_]struct { name: []const u8, role: Role }{
        .{ .name = "class", .role = .class_node },
        .{ .name = "class.name", .role = .class_name },
        .{ .name = "method", .role = .method_node },
        .{ .name = "method.name", .role = .method_name },
        .{ .name = "method.recv", .role = .method_recv },
        .{ .name = "decl.name", .role = .decl_name },
        .{ .name = "decl.type", .role = .decl_type },
        .{ .name = "decl.ctor", .role = .decl_ctor },
        .{ .name = "call", .role = .call_node },
        .{ .name = "call.receiver", .role = .call_receiver },
        .{ .name = "call.method", .role = .call_method },
        .{ .name = "import.name", .role = .import_name },
        .{ .name = "import.source", .role = .import_source },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.role;
    }
    return null;
}

const ts_query_source =
    \\(class_declaration name: (type_identifier) @class.name) @class
    \\(abstract_class_declaration name: (type_identifier) @class.name) @class
    \\(method_definition name: (property_identifier) @method.name) @method
    \\(public_field_definition name: (property_identifier) @decl.name type: (type_annotation (type_identifier) @decl.type))
    \\(required_parameter pattern: (identifier) @decl.name type: (type_annotation (type_identifier) @decl.type))
    \\(variable_declarator name: (identifier) @decl.name type: (type_annotation (type_identifier) @decl.type))
    \\(variable_declarator name: (identifier) @decl.name value: (new_expression constructor: (identifier) @decl.type))
    \\(assignment_expression left: (member_expression object: (this) property: (property_identifier) @decl.name) right: (new_expression constructor: (identifier) @decl.type))
    \\(call_expression function: (member_expression object: (identifier) @call.receiver property: (property_identifier) @call.method)) @call
    \\(call_expression function: (member_expression object: (member_expression object: (this) property: (property_identifier) @call.receiver) property: (property_identifier) @call.method)) @call
    \\(import_statement (import_clause (named_imports (import_specifier name: (identifier) @import.name))) source: (string (string_fragment) @import.source))
    \\(import_statement (import_clause (identifier) @import.name) source: (string (string_fragment) @import.source))
;

const go_query_source =
    \\(type_declaration (type_spec name: (type_identifier) @class.name)) @class
    \\(method_declaration receiver: (parameter_list (parameter_declaration type: [(type_identifier) @method.recv (pointer_type (type_identifier) @method.recv)])) name: (field_identifier) @method.name) @method
    \\(parameter_declaration name: (identifier) @decl.name type: [(type_identifier) @decl.type (pointer_type (type_identifier) @decl.type)])
    \\(field_declaration name: (field_identifier) @decl.name type: [(type_identifier) @decl.type (pointer_type (type_identifier) @decl.type)])
    \\(var_spec name: (identifier) @decl.name type: [(type_identifier) @decl.type (pointer_type (type_identifier) @decl.type)])
    \\(short_var_declaration left: (expression_list . (identifier) @decl.name) right: (expression_list (call_expression function: (identifier) @decl.ctor)))
    \\(short_var_declaration left: (expression_list . (identifier) @decl.name) right: (expression_list (composite_literal type: (type_identifier) @decl.type)))
    \\(short_var_declaration left: (expression_list . (identifier) @decl.name) right: (expression_list (unary_expression operand: (composite_literal type: (type_identifier) @decl.type))))
    \\(call_expression function: (selector_expression operand: (identifier) @call.receiver field: (field_identifier) @call.method)) @call
    \\(call_expression function: (selector_expression operand: (selector_expression field: (field_identifier) @call.receiver) field: (field_identifier) @call.method)) @call
    \\(import_spec path: (interpreted_string_literal) @import.source)
;

pub fn querySource(lang: language.Name) []const u8 {
    return switch (lang) {
        .ts, .tsx => ts_query_source,
        .go => go_query_source,
    };
}

pub const Compiled = struct {
    query: *ts.Query,
    capture_roles: []const Role,

    pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void {
        self.query.destroy();
        allocator.free(self.capture_roles);
    }
};

pub const CompileError = error{FactsQueryCompileFailed} || std.mem.Allocator.Error;

pub fn compile(
    allocator: std.mem.Allocator,
    ts_lang: *const ts.Language,
    lang: language.Name,
) CompileError!Compiled {
    var error_offset: u32 = 0;
    const query = ts.Query.create(ts_lang, querySource(lang), &error_offset) catch
        return error.FactsQueryCompileFailed;
    errdefer query.destroy();

    const roles = try allocator.alloc(Role, query.captureCount());
    errdefer allocator.free(roles);

    for (roles, 0..) |*role, i| {
        const cap_name = query.captureNameForId(@intCast(i)) orelse return error.FactsQueryCompileFailed;
        role.* = roleFromCaptureName(cap_name) orelse return error.FactsQueryCompileFailed;
    }

    return .{ .query = query, .capture_roles = roles };
}

const Lists = struct {
    classes: std.ArrayList(ClassDef) = .empty,
    methods: std.ArrayList(MethodDef) = .empty,
    typed_decls: std.ArrayList(TypedDecl) = .empty,
    calls: std.ArrayList(Call) = .empty,
    imports: std.ArrayList(Import) = .empty,
};

pub fn extract(
    gpa: std.mem.Allocator,
    compiled: *const Compiled,
    cursor: *ts.QueryCursor,
    root: ts.Node,
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

    cursor.exec(compiled.query, root);
    while (cursor.nextMatch()) |match| {
        var nodes: std.EnumArray(Role, ?ts.Node) = .initFill(null);

        for (match.captures) |cap| {
            nodes.set(compiled.capture_roles[cap.index], cap.node);
        }

        try assemble(arena, source, nodes, &lists);
    }

    sortByStart(ClassDef, lists.classes.items);
    sortByStart(MethodDef, lists.methods.items);
    sortByStart(TypedDecl, lists.typed_decls.items);
    sortByStart(Call, lists.calls.items);
    sortByStart(Import, lists.imports.items);

    resolveContainers(lang, lists.classes.items, lists.methods.items, lists.calls.items);

    return .{
        .arena = arena_ptr,
        .path = try arena.dupe(u8, path),
        .lang = lang,
        .classes = try lists.classes.toOwnedSlice(arena),
        .methods = try lists.methods.toOwnedSlice(arena),
        .typed_decls = try lists.typed_decls.toOwnedSlice(arena),
        .calls = try lists.calls.toOwnedSlice(arena),
        .imports = try lists.imports.toOwnedSlice(arena),
    };
}

fn assemble(
    arena: std.mem.Allocator,
    source: []const u8,
    nodes: std.EnumArray(Role, ?ts.Node),
    lists: *Lists,
) !void {
    if (nodes.get(.method_name)) |name_node| {
        const span_node = nodes.get(.method_node) orelse name_node;

        try lists.methods.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .container = if (nodes.get(.method_recv)) |recv| try nodeText(arena, source, recv) else "",
            .start = span_node.startByte(),
            .end = span_node.endByte(),
            .range = rangeOf(span_node),
        });

        return;
    }
    if (nodes.get(.class_name)) |name_node| {
        const span_node = nodes.get(.class_node) orelse name_node;

        try lists.classes.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .start = span_node.startByte(),
            .end = span_node.endByte(),
            .range = rangeOf(span_node),
        });

        return;
    }
    if (nodes.get(.decl_name)) |name_node| {
        const type_name = try declTypeName(arena, source, nodes) orelse return;

        try lists.typed_decls.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .type_name = type_name,
            .start = name_node.startByte(),
            .range = rangeOf(name_node),
        });

        return;
    }
    if (nodes.get(.call_method)) |method_node| {
        const span_node = nodes.get(.call_node) orelse method_node;

        try lists.calls.append(arena, .{
            .receiver = if (nodes.get(.call_receiver)) |recv| try nodeText(arena, source, recv) else "",
            .method = try nodeText(arena, source, method_node),
            .container = "",
            .start = span_node.startByte(),
            .range = rangeOf(span_node),
        });

        return;
    }
    if (nodes.get(.import_source)) |source_node| {
        const raw = try nodeText(arena, source, source_node);

        try lists.imports.append(arena, .{
            .name = if (nodes.get(.import_name)) |name| try nodeText(arena, source, name) else "",
            .source = std.mem.trim(u8, raw, "\""),
            .start = source_node.startByte(),
            .range = rangeOf(source_node),
        });

        return;
    }
}

fn declTypeName(
    arena: std.mem.Allocator,
    source: []const u8,
    nodes: std.EnumArray(Role, ?ts.Node),
) !?[]const u8 {
    if (nodes.get(.decl_type)) |type_node| return try nodeText(arena, source, type_node);

    const ctor_node = nodes.get(.decl_ctor) orelse return null;
    const ctor = nodeSlice(source, ctor_node);

    if (!std.mem.startsWith(u8, ctor, go_constructor_prefix)) return null;

    const type_name = ctor[go_constructor_prefix.len..];

    if (type_name.len == 0) return null;

    return try arena.dupe(u8, type_name);
}

fn resolveContainers(
    lang: language.Name,
    classes: []const ClassDef,
    methods: []MethodDef,
    calls: []Call,
) void {
    switch (lang) {
        .ts, .tsx => {
            for (methods) |*m| {
                if (m.container.len == 0) m.container = innermostClassName(classes, m.start, m.end) orelse "";
            }

            for (calls) |*c| {
                c.container = innermostClassName(classes, c.start, c.start) orelse "";
            }
        },
        .go => {
            for (calls) |*c| {
                c.container = enclosingMethodContainer(methods, c.start) orelse "";
            }
        },
    }
}

fn innermostClassName(classes: []const ClassDef, start: u32, end: u32) ?[]const u8 {
    var best: ?usize = null;

    for (classes, 0..) |cl, i| {
        if (cl.start > start or end > cl.end) continue;
        if (cl.start == start and cl.end == end) continue;
        if (best == null or classes[best.?].start < cl.start) best = i;
    }

    return if (best) |i| classes[i].name else null;
}

fn enclosingMethodContainer(methods: []const MethodDef, start: u32) ?[]const u8 {
    var best: ?usize = null;

    for (methods, 0..) |m, i| {
        if (m.start > start or start >= m.end) continue;
        if (best == null or methods[best.?].start < m.start) best = i;
    }

    return if (best) |i| methods[i].container else null;
}

fn sortByStart(comptime T: type, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn lessThan(_: void, a: T, b: T) bool {
            return a.start < b.start;
        }
    }.lessThan);
}

fn nodeSlice(source: []const u8, node: ts.Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

fn nodeText(arena: std.mem.Allocator, source: []const u8, node: ts.Node) ![]const u8 {
    return arena.dupe(u8, nodeSlice(source, node));
}

fn rangeOf(node: ts.Node) diagnostic.Range {
    const sp = node.startPoint();
    const ep = node.endPoint();

    return .{
        .start = .{ .line = sp.row, .column = sp.column },
        .end = .{ .line = ep.row, .column = ep.column },
    };
}
