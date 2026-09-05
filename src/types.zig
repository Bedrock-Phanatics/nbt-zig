const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const TagType = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    long_array = 12,

    pub fn fromByte(value: u8) error{InvalidTag}!TagType {
        if (value > @intFromEnum(TagType.long_array)) return error.InvalidTag;
        return @enumFromInt(value);
    }
};

pub const List = struct {
    element_type: TagType,
    items: []Tag,
};

pub const Entry = struct {
    name: []u8,
    value: Tag,
};

pub const Compound = struct {
    entries: []Entry,

    pub fn get(self: Compound, name: []const u8) ?*const Tag {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return &entry.value;
        }
        return null;
    }

    pub fn getMut(self: *Compound, name: []const u8) ?*Tag {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return &entry.value;
        }
        return null;
    }
};

/// An owned NBT value. Its slices belong to the containing tree.
pub const Tag = union(TagType) {
    end: void,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []u8,
    string: []u8,
    list: List,
    compound: Compound,
    int_array: []i32,
    long_array: []i64,

    pub fn tagType(self: Tag) TagType {
        return self;
    }

    pub fn deinit(self: *Tag, allocator: Allocator) void {
        switch (self.*) {
            .string => |value| allocator.free(value),
            .byte_array => |value| allocator.free(value),
            .int_array => |value| allocator.free(value),
            .long_array => |value| allocator.free(value),
            .list => |list| {
                for (list.items) |*item| item.deinit(allocator);
                allocator.free(list.items);
            },
            .compound => |compound| {
                for (compound.entries) |*entry| {
                    allocator.free(entry.name);
                    entry.value.deinit(allocator);
                }
                allocator.free(compound.entries);
            },
            else => {}, // NOOP: scalar tags own nothing.
        }
        self.* = .{ .end = {} };
    }

    pub fn eql(a: Tag, b: Tag) bool {
        if (a.tagType() != b.tagType()) return false;
        return switch (a) {
            .end => true,
            .byte => |v| v == b.byte,
            .short => |v| v == b.short,
            .int => |v| v == b.int,
            .long => |v| v == b.long,
            .float => |v| @as(u32, @bitCast(v)) == @as(u32, @bitCast(b.float)),
            .double => |v| @as(u64, @bitCast(v)) == @as(u64, @bitCast(b.double)),
            .byte_array => |v| std.mem.eql(u8, v, b.byte_array),
            .string => |v| std.mem.eql(u8, v, b.string),
            .int_array => |v| std.mem.eql(i32, v, b.int_array),
            .long_array => |v| std.mem.eql(i64, v, b.long_array),
            .list => |v| blk: {
                if (v.element_type != b.list.element_type or v.items.len != b.list.items.len) break :blk false;
                for (v.items, b.list.items) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            .compound => |v| blk: {
                if (v.entries.len != b.compound.entries.len) break :blk false;
                for (v.entries, b.compound.entries) |x, y| {
                    if (!std.mem.eql(u8, x.name, y.name) or !x.value.eql(y.value)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

/// Owns its name and tag tree.
pub const Document = struct {
    name: []u8,
    root: Tag,

    /// Copies `name` and takes `root` on success.
    pub fn init(allocator: Allocator, name: []const u8, root: Tag) (error{InvalidRoot} || Allocator.Error)!Document {
        if (root.tagType() == .end) return error.InvalidRoot;
        return .{ .name = try allocator.dupe(u8, name), .root = root };
    }

    pub fn deinit(self: *Document, allocator: Allocator) void {
        allocator.free(self.name);
        self.root.deinit(allocator);
        self.* = undefined;
    }

    pub fn eql(a: Document, b: Document) bool {
        return std.mem.eql(u8, a.name, b.name) and a.root.eql(b.root);
    }
};
