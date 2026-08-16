const std = @import("std");

const facts = @import("../facts.zig");
const fact_schema = @import("../fact_schema.zig");

const ProjectIndex = @import("../ProjectIndex.zig").ProjectIndex;

pub const CaptureId = usize;
pub const CaptureSet = u64;

pub const BoundFact = struct {
    fact: fact_schema.Fact,
    file: *const facts.FileFacts,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    index: *const ProjectIndex,
    class_names: *const std.StringHashMapUnmanaged(void),
};
