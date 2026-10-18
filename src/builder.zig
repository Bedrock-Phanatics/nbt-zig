const std = @import("std");
const Allocator = std.mem.Allocator;

const small_limit = @import("internal/unique_names.zig").small_limit;
const types = @import("types.zig");

pub fn string(allocator: Allocator, value: []const u8) Allocator.Error!types.Tag {
    return .{ .string = try allocator.dupe(u8, value) };
}

pub fn byteArray(allocator: Allocator, value: []const u8) Allocator.Error!types.Tag {
    return .{ .byte_array = try allocator.dupe(u8, value) };
}

pub fn intArray(allocator: Allocator, value: []const i32) Allocator.Error!types.Tag {
    return .{ .int_array = try allocator.dupe(i32, value) };
}

pub fn longArray(allocator: Allocator, value: []const i64) Allocator.Error!types.Tag {
    return .{ .long_array = try allocator.dupe(i64, value) };
}

/// `append` takes ownership on success.
pub const List = struct {
    allocator: Allocator,
    element_type: types.TagType,
    items: std.ArrayList(types.Tag) = .empty,

    pub fn init(allocator: Allocator, element_type: types.TagType) List {
        return .{
            .allocator = allocator,
            .element_type = element_type,
        };
    }

    pub fn deinit(self: *List) void {
        for (self.items.items) |*item| item.deinit(self.allocator);

        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *List, value: types.Tag) (error{ TypeMismatch, InvalidListType } || Allocator.Error)!void {
        const element_type = value.tagType();

        if (self.element_type == .end or element_type == .end) return error.InvalidListType;
        if (element_type != self.element_type) return error.TypeMismatch;

        try self.items.append(self.allocator, value);
    }

    /// Hands over the items and leaves the builder empty and reusable.
    pub fn finish(self: *List) Allocator.Error!types.Tag {
        const items = try self.items.toOwnedSlice(self.allocator);

        return .{ .list = .{ .element_type = self.element_type, .items = items } };
    }
};

/// `add` copies names and takes values on success.
pub const Compound = struct {
    allocator: Allocator,
    entries: std.ArrayList(types.Entry) = .empty,
    /// Built once the compound outgrows a linear scan.
    names: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: Allocator) Compound {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Compound) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);

        self.entries.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn contains(self: *const Compound, name: []const u8) bool {
        if (self.names.count() != 0) return self.names.contains(name);

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return true;
        }

        return false;
    }

    pub fn add(self: *Compound, name: []const u8, value: types.Tag) (error{ DuplicateName, InvalidTag } || Allocator.Error)!void {
        if (value.tagType() == .end) return error.InvalidTag;
        if (self.contains(name)) return error.DuplicateName;

        try self.entries.ensureUnusedCapacity(self.allocator, 1);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        if (self.entries.items.len >= small_limit) try self.index(owned_name);

        self.entries.appendAssumeCapacity(.{ .name = owned_name, .value = value });
    }

    fn index(self: *Compound, name: []u8) Allocator.Error!void {
        if (self.names.count() == 0) {
            const count = std.math.cast(u32, self.entries.items.len + 1) orelse return error.OutOfMemory;
            try self.names.ensureTotalCapacity(self.allocator, count);

            for (self.entries.items) |entry| self.names.putAssumeCapacityNoClobber(entry.name, {});
        }

        try self.names.putNoClobber(self.allocator, name, {});
    }

    /// Hands over the entries and leaves the builder empty and reusable.
    pub fn finish(self: *Compound) Allocator.Error!types.Tag {
        const entries = try self.entries.toOwnedSlice(self.allocator);

        self.names.clearAndFree(self.allocator);

        return .{ .compound = .{ .entries = entries } };
    }
};
