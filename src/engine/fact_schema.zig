const std = @import("std");

const facts = @import("facts.zig");

pub const FactKind = enum {
    class,
    method,
    typed_decl,
    call,
    import,

    pub fn fromString(name: []const u8) ?FactKind {
        inline for (descriptors) |descriptor_value| {
            if (std.mem.eql(u8, name, descriptor_value.dsl_name)) return descriptor_value.kind;
        }

        return null;
    }

    pub fn toString(self: FactKind) []const u8 {
        return switch (self) {
            inline else => |kind| factDescriptor(kind).dsl_name,
        };
    }
};

pub const HelperDescriptor = struct {
    name: []const u8,
    fact: FactKind,
    needs_class_index: bool,
};

pub const helpers = .{
    .receiver_type = HelperDescriptor{ .name = "receiverType", .fact = .call, .needs_class_index = true },
    .resolved_import_source = HelperDescriptor{ .name = "resolvedImportSource", .fact = .import, .needs_class_index = false },
};

pub const HelperId = std.meta.FieldEnum(@TypeOf(helpers));

pub const Field = enum {
    name,
    container,
    type,
    receiver,
    method,
    source,
    path,
    lang,
};

pub const FactDescriptor = struct {
    kind: FactKind,
    dsl_name: []const u8,
    Record: type,
    list: []const u8,
    fields: []const FieldBinding,
};

pub const FieldBinding = struct {
    field: Field,
    accessor: []const u8,
};

pub const descriptors = [_]FactDescriptor{
    .{
        .kind = .class,
        .dsl_name = "class",
        .Record = facts.ClassDef,
        .list = "classes",
        .fields = &.{.{ .field = .name, .accessor = "name" }},
    },
    .{
        .kind = .method,
        .dsl_name = "method",
        .Record = facts.MethodDef,
        .list = "methods",
        .fields = &.{
            .{ .field = .name, .accessor = "name" },
            .{ .field = .container, .accessor = "container" },
        },
    },
    .{
        .kind = .typed_decl,
        .dsl_name = "typedDecl",
        .Record = facts.TypedDecl,
        .list = "typed_decls",
        .fields = &.{
            .{ .field = .name, .accessor = "name" },
            .{ .field = .type, .accessor = "type_name" },
        },
    },
    .{
        .kind = .call,
        .dsl_name = "call",
        .Record = facts.Call,
        .list = "calls",
        .fields = &.{
            .{ .field = .receiver, .accessor = "receiver" },
            .{ .field = .method, .accessor = "method" },
            .{ .field = .container, .accessor = "container" },
        },
    },
    .{
        .kind = .import,
        .dsl_name = "import",
        .Record = facts.Import,
        .list = "imports",
        .fields = &.{
            .{ .field = .name, .accessor = "name" },
            .{ .field = .source, .accessor = "source" },
        },
    },
};

pub const Fact = union(FactKind) {
    class: facts.ClassDef,
    method: facts.MethodDef,
    typed_decl: facts.TypedDecl,
    call: facts.Call,
    import: facts.Import,
};

pub const VisitControl = enum {
    continue_scan,
    stop,
};

fn factDescriptor(comptime kind: FactKind) FactDescriptor {
    inline for (descriptors) |descriptor_value| {
        if (descriptor_value.kind == kind) return descriptor_value;
    }

    @compileError("FactKind has no descriptor");
}

comptime {
    if (descriptors.len != std.meta.fields(FactKind).len) @compileError("FactKind descriptor count mismatch");

    for (std.meta.fields(FactKind)) |kind_field| {
        const kind: FactKind = @enumFromInt(kind_field.value);
        const descriptor_value = factDescriptor(kind);
        if (@FieldType(Fact, @tagName(kind)) != descriptor_value.Record) @compileError("Fact payload and descriptor record mismatch");
    }
}

pub fn descriptor(comptime id: HelperId) HelperDescriptor {
    return @field(helpers, @tagName(id));
}

pub fn factHasField(kind: FactKind, field: Field) bool {
    if (field == .path or field == .lang) return true;

    return switch (kind) {
        inline else => |resolved_kind| hasBoundField(factDescriptor(resolved_kind), field),
    };
}

fn hasBoundField(comptime descriptor_value: FactDescriptor, field: Field) bool {
    inline for (descriptor_value.fields) |binding| {
        if (field == binding.field) return true;
    }

    return false;
}

pub fn fieldValue(fact: Fact, field: Field, file: *const facts.FileFacts) ?[]const u8 {
    if (field == .path) return file.path;
    if (field == .lang) return file.lang.toString();

    return switch (fact) {
        inline else => |record, kind| valueFromRecord(record, field, factDescriptor(kind)),
    };
}

fn valueFromRecord(record: anytype, field: Field, comptime descriptor_value: FactDescriptor) ?[]const u8 {
    inline for (descriptor_value.fields) |binding| {
        if (field == binding.field) return @field(record, binding.accessor);
    }

    return null;
}

pub fn fileFactsEql(a: *const facts.FileFacts, b: *const facts.FileFacts) bool {
    if (a.lang != b.lang) return false;

    inline for (descriptors) |descriptor_value| {
        const left = @field(a, descriptor_value.list);
        const right = @field(b, descriptor_value.list);
        if (left.len != right.len) return false;
        for (left, right) |left_record, right_record| {
            if (!recordEql(left_record, right_record)) return false;
        }
    }

    return true;
}

fn recordEql(a: anytype, b: @TypeOf(a)) bool {
    inline for (std.meta.fields(@TypeOf(a))) |field| {
        const left = @field(a, field.name);
        const right = @field(b, field.name);
        if (field.type == []const u8) {
            if (!std.mem.eql(u8, left, right)) return false;
        } else if (!std.meta.eql(left, right)) return false;
    }

    return true;
}

pub fn visitFacts(file: *const facts.FileFacts, kind: FactKind, sink: anytype) std.mem.Allocator.Error!VisitControl {
    switch (kind) {
        inline else => |resolved_kind| {
            const descriptor_value = factDescriptor(resolved_kind);
            for (@field(file, descriptor_value.list)) |record| {
                const fact: Fact = @unionInit(Fact, @tagName(resolved_kind), record);
                if (try sink.visit(file, fact) == .stop) return .stop;
            }
        },
    }

    return .continue_scan;
}
