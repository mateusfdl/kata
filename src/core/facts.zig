const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const fs_path = @import("path");
const language = @import("language.zig");
const node_kinds = @import("node_kinds");
const query = @import("query.zig");
const Node = @import("node.zig").Node;

fn tsk(comptime name: []const u8) u16 {
    return @intFromEnum(@field(node_kinds.ts_family.Kind, name));
}

fn gok(comptime name: []const u8) u16 {
    return @intFromEnum(@field(node_kinds.go.Kind, name));
}

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

const role_count = @typeInfo(Role).@"enum".fields.len;

fn cap(role: Role) query.CaptureId {
    return @intFromEnum(role);
}

const ts_patterns: []const query.Pattern = &.{
    .{ .kind = .{ .symbol = tsk("class_declaration") }, .capture = cap(.class_node), .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = tsk("type_identifier") }, .capture = cap(.class_name) } },
    } },
    .{ .kind = .{ .symbol = tsk("abstract_class_declaration") }, .capture = cap(.class_node), .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = tsk("type_identifier") }, .capture = cap(.class_name) } },
    } },
    .{ .kind = .{ .symbol = tsk("method_definition") }, .capture = cap(.method_node), .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = tsk("property_identifier") }, .capture = cap(.method_name) } },
    } },
    .{ .kind = .{ .symbol = tsk("public_field_definition") }, .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = tsk("property_identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .symbol = tsk("type_annotation") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("type_identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = tsk("required_parameter") }, .fields = &.{
        .{ .relation = .{ .field = "pattern" }, .pattern = .{ .kind = .{ .symbol = tsk("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .symbol = tsk("type_annotation") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("type_identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = tsk("variable_declarator") }, .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = tsk("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .symbol = tsk("type_annotation") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("type_identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = tsk("variable_declarator") }, .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = tsk("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = "value" }, .pattern = .{ .kind = .{ .symbol = tsk("new_expression") }, .fields = &.{
            .{ .relation = .{ .field = "constructor" }, .pattern = .{ .kind = .{ .symbol = tsk("identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = tsk("assignment_expression") }, .fields = &.{
        .{ .relation = .{ .field = "left" }, .pattern = .{ .kind = .{ .symbol = tsk("member_expression") }, .fields = &.{
            .{ .relation = .{ .field = "object" }, .pattern = .{ .kind = .{ .symbol = tsk("this") } } },
            .{ .relation = .{ .field = "property" }, .pattern = .{ .kind = .{ .symbol = tsk("property_identifier") }, .capture = cap(.decl_name) } },
        } } },
        .{ .relation = .{ .field = "right" }, .pattern = .{ .kind = .{ .symbol = tsk("new_expression") }, .fields = &.{
            .{ .relation = .{ .field = "constructor" }, .pattern = .{ .kind = .{ .symbol = tsk("identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = tsk("call_expression") }, .capture = cap(.call_node), .fields = &.{
        .{ .relation = .{ .field = "function" }, .pattern = .{ .kind = .{ .symbol = tsk("member_expression") }, .fields = &.{
            .{ .relation = .{ .field = "object" }, .pattern = .{ .kind = .{ .symbol = tsk("identifier") }, .capture = cap(.call_receiver) } },
            .{ .relation = .{ .field = "property" }, .pattern = .{ .kind = .{ .symbol = tsk("property_identifier") }, .capture = cap(.call_method) } },
        } } },
    } },
    .{ .kind = .{ .symbol = tsk("call_expression") }, .capture = cap(.call_node), .fields = &.{
        .{ .relation = .{ .field = "function" }, .pattern = .{ .kind = .{ .symbol = tsk("member_expression") }, .fields = &.{
            .{ .relation = .{ .field = "object" }, .pattern = .{ .kind = .{ .symbol = tsk("member_expression") }, .fields = &.{
                .{ .relation = .{ .field = "object" }, .pattern = .{ .kind = .{ .symbol = tsk("this") } } },
                .{ .relation = .{ .field = "property" }, .pattern = .{ .kind = .{ .symbol = tsk("property_identifier") }, .capture = cap(.call_receiver) } },
            } } },
            .{ .relation = .{ .field = "property" }, .pattern = .{ .kind = .{ .symbol = tsk("property_identifier") }, .capture = cap(.call_method) } },
        } } },
    } },
    .{ .kind = .{ .symbol = tsk("import_statement") }, .fields = &.{
        .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("import_clause") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("named_imports") }, .fields = &.{
                .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("import_specifier") }, .fields = &.{
                    .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = tsk("identifier") }, .capture = cap(.import_name) } },
                } } },
            } } },
        } } },
        .{ .relation = .{ .field = "source" }, .pattern = .{ .kind = .{ .symbol = tsk("string") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("string_fragment") }, .capture = cap(.import_source) } },
        } } },
    } },
    .{ .kind = .{ .symbol = tsk("import_statement") }, .fields = &.{
        .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("import_clause") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("identifier") }, .capture = cap(.import_name) } },
        } } },
        .{ .relation = .{ .field = "source" }, .pattern = .{ .kind = .{ .symbol = tsk("string") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = tsk("string_fragment") }, .capture = cap(.import_source) } },
        } } },
    } },
};

const go_patterns: []const query.Pattern = &.{
    .{ .kind = .{ .symbol = gok("type_declaration") }, .capture = cap(.class_node), .fields = &.{
        .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("type_spec") }, .fields = &.{
            .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.class_name) } },
        } } },
    } },
    .{ .kind = .{ .symbol = gok("method_declaration") }, .capture = cap(.method_node), .fields = &.{
        .{ .relation = .{ .field = "receiver" }, .pattern = .{ .kind = .{ .symbol = gok("parameter_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("parameter_declaration") }, .fields = &.{
                .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .alternation = &.{
                    .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.method_recv) },
                    .{ .kind = .{ .symbol = gok("pointer_type") }, .fields = &.{
                        .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.method_recv) } },
                    } },
                } } } },
            } } },
        } } },
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = gok("field_identifier") }, .capture = cap(.method_name) } },
    } },
    .{ .kind = .{ .symbol = gok("parameter_declaration") }, .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = gok("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.decl_type) },
            .{ .kind = .{ .symbol = gok("pointer_type") }, .fields = &.{
                .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.decl_type) } },
            } },
        } } } },
    } },
    .{ .kind = .{ .symbol = gok("field_declaration") }, .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = gok("field_identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.decl_type) },
            .{ .kind = .{ .symbol = gok("pointer_type") }, .fields = &.{
                .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.decl_type) } },
            } },
        } } } },
    } },
    .{ .kind = .{ .symbol = gok("var_spec") }, .fields = &.{
        .{ .relation = .{ .field = "name" }, .pattern = .{ .kind = .{ .symbol = gok("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.decl_type) },
            .{ .kind = .{ .symbol = gok("pointer_type") }, .fields = &.{
                .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.decl_type) } },
            } },
        } } } },
    } },
    .{ .kind = .{ .symbol = gok("short_var_declaration") }, .fields = &.{
        .{ .relation = .{ .field = "left" }, .pattern = .{ .kind = .{ .symbol = gok("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("identifier") }, .capture = cap(.decl_name) } },
        } } },
        .{ .relation = .{ .field = "right" }, .pattern = .{ .kind = .{ .symbol = gok("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("call_expression") }, .fields = &.{
                .{ .relation = .{ .field = "function" }, .pattern = .{ .kind = .{ .symbol = gok("identifier") }, .capture = cap(.decl_ctor) } },
            } } },
        } } },
    } },
    .{ .kind = .{ .symbol = gok("short_var_declaration") }, .fields = &.{
        .{ .relation = .{ .field = "left" }, .pattern = .{ .kind = .{ .symbol = gok("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("identifier") }, .capture = cap(.decl_name) } },
        } } },
        .{ .relation = .{ .field = "right" }, .pattern = .{ .kind = .{ .symbol = gok("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("composite_literal") }, .fields = &.{
                .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.decl_type) } },
            } } },
        } } },
    } },
    .{ .kind = .{ .symbol = gok("short_var_declaration") }, .fields = &.{
        .{ .relation = .{ .field = "left" }, .pattern = .{ .kind = .{ .symbol = gok("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("identifier") }, .capture = cap(.decl_name) } },
        } } },
        .{ .relation = .{ .field = "right" }, .pattern = .{ .kind = .{ .symbol = gok("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = gok("unary_expression") }, .fields = &.{
                .{ .relation = .{ .field = "operand" }, .pattern = .{ .kind = .{ .symbol = gok("composite_literal") }, .fields = &.{
                    .{ .relation = .{ .field = "type" }, .pattern = .{ .kind = .{ .symbol = gok("type_identifier") }, .capture = cap(.decl_type) } },
                } } },
            } } },
        } } },
    } },
    .{ .kind = .{ .symbol = gok("call_expression") }, .capture = cap(.call_node), .fields = &.{
        .{ .relation = .{ .field = "function" }, .pattern = .{ .kind = .{ .symbol = gok("selector_expression") }, .fields = &.{
            .{ .relation = .{ .field = "operand" }, .pattern = .{ .kind = .{ .symbol = gok("identifier") }, .capture = cap(.call_receiver) } },
            .{ .relation = .{ .field = "field" }, .pattern = .{ .kind = .{ .symbol = gok("field_identifier") }, .capture = cap(.call_method) } },
        } } },
    } },
    .{ .kind = .{ .symbol = gok("call_expression") }, .capture = cap(.call_node), .fields = &.{
        .{ .relation = .{ .field = "function" }, .pattern = .{ .kind = .{ .symbol = gok("selector_expression") }, .fields = &.{
            .{ .relation = .{ .field = "operand" }, .pattern = .{ .kind = .{ .symbol = gok("selector_expression") }, .fields = &.{
                .{ .relation = .{ .field = "field" }, .pattern = .{ .kind = .{ .symbol = gok("field_identifier") }, .capture = cap(.call_receiver) } },
            } } },
            .{ .relation = .{ .field = "field" }, .pattern = .{ .kind = .{ .symbol = gok("field_identifier") }, .capture = cap(.call_method) } },
        } } },
    } },
    .{ .kind = .{ .symbol = gok("import_spec") }, .fields = &.{
        .{ .relation = .{ .field = "path" }, .pattern = .{ .kind = .{ .symbol = gok("interpreted_string_literal") }, .capture = cap(.import_source) } },
    } },
};

fn patternsFor(lang: language.Name) []const query.Pattern {
    return switch (lang) {
        .ts, .tsx => ts_patterns,
        .go => go_patterns,
    };
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

    for (patternsFor(lang)) |*pattern| {
        for (try query.run(arena, pattern, role_count, root)) |match| {
            try assemble(arena, source, match, &lists);
        }
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
    match: query.Match,
    lists: *Lists,
) !void {
    if (match.get(cap(.method_name))) |name_node| {
        const span_node = match.get(cap(.method_node)) orelse name_node;

        try lists.methods.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .container = if (match.get(cap(.method_recv))) |recv| try nodeText(arena, source, recv) else "",
            .start = span_node.startByte(),
            .end = span_node.endByte(),
            .range = rangeOf(span_node),
        });

        return;
    }
    if (match.get(cap(.class_name))) |name_node| {
        const span_node = match.get(cap(.class_node)) orelse name_node;

        try lists.classes.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .start = span_node.startByte(),
            .end = span_node.endByte(),
            .range = rangeOf(span_node),
        });

        return;
    }
    if (match.get(cap(.decl_name))) |name_node| {
        if (!isFirstInExpressionList(name_node)) return;

        const type_name = try declTypeName(arena, source, match) orelse return;

        try lists.typed_decls.append(arena, .{
            .name = try nodeText(arena, source, name_node),
            .type_name = type_name,
            .start = name_node.startByte(),
            .range = rangeOf(name_node),
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
            .range = rangeOf(span_node),
        });

        return;
    }
    if (match.get(cap(.import_source))) |source_node| {
        const raw = try nodeText(arena, source, source_node);

        try lists.imports.append(arena, .{
            .name = if (match.get(cap(.import_name))) |name| try nodeText(arena, source, name) else "",
            .source = std.mem.trim(u8, raw, "\""),
            .start = source_node.startByte(),
            .range = rangeOf(source_node),
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
) !?[]const u8 {
    if (match.get(cap(.decl_type))) |type_node| return try nodeText(arena, source, type_node);

    const ctor_node = match.get(cap(.decl_ctor)) orelse return null;
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

fn nodeSlice(source: []const u8, node: Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

fn nodeText(arena: std.mem.Allocator, source: []const u8, node: Node) ![]const u8 {
    return arena.dupe(u8, nodeSlice(source, node));
}

fn rangeOf(node: Node) diagnostic.Range {
    const sp = node.startPoint();
    const ep = node.endPoint();

    return .{
        .start = .{ .line = sp.row, .column = sp.column },
        .end = .{ .line = ep.row, .column = ep.column },
    };
}
