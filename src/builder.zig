const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

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

/// A homogeneous list builder. `append` takes ownership on success.
pub const List = struct {
    allocator: Allocator,
    element_type: types.TagType,
    items: std.ArrayList(types.Tag) = .empty,

    pub fn init(allocator: Allocator, element_type: types.TagType) List {
        return .{ .allocator = allocator, .element_type = element_type };
    }

    pub fn deinit(self: *List) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *List, value: types.Tag) (error{ TypeMismatch, InvalidListType } || Allocator.Error)!void {
        if (self.element_type == .end or value.tagType() == .end) return error.InvalidListType;
        if (value.tagType() != self.element_type) return error.TypeMismatch;
        try self.items.append(self.allocator, value);
    }

    pub fn finish(self: *List) Allocator.Error!types.Tag {
        const owned = try self.items.toOwnedSlice(self.allocator);
        self.items = .empty;
        return .{ .list = .{ .element_type = self.element_type, .items = owned } };
    }
};

/// An ordered compound builder. `add` copies names and takes values on success.
pub const Compound = struct {
    allocator: Allocator,
    entries: std.ArrayList(types.Entry) = .empty,
    names: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: Allocator) Compound {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Compound) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.name);
            entry.value.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Compound, name: []const u8, value: types.Tag) (error{ DuplicateName, InvalidTag } || Allocator.Error)!void {
        if (value.tagType() == .end) return error.InvalidTag;
        if (self.names.contains(name)) return error.DuplicateName;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.names.putNoClobber(self.allocator, owned_name, {});
        errdefer _ = self.names.remove(owned_name);
        try self.entries.append(self.allocator, .{ .name = owned_name, .value = value });
    }

    pub fn finish(self: *Compound) Allocator.Error!types.Tag {
        const owned = try self.entries.toOwnedSlice(self.allocator);
        self.names.deinit(self.allocator);
        self.names = .empty;
        self.entries = .empty;
        return .{ .compound = .{ .entries = owned } };
    }
};
