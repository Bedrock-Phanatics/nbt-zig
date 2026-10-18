const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CodecError = error{
    UnexpectedEndOfInput,
    InvalidTag,
    InvalidRoot,
    InvalidLength,
    SizeLimitExceeded,
    DepthLimitExceeded,
    InvalidListType,
    DuplicateName,
    InvalidUtf8,
    InvalidModifiedUtf8,
    VarIntOverflow,
    TrailingData,
    TypeMismatch,
    InvalidOptions,
};

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
        // Tags are contiguous, which beats the linear scan in std.enums.fromInt.
        if (value > @backingInt(TagType.long_array)) return error.InvalidTag;
        return @fromBackingInt(value);
    }

    /// True for fixed-size numbers, which own no memory.
    pub fn isScalar(self: TagType) bool {
        return switch (self) {
            .byte, .short, .int, .long, .float, .double => true,
            else => false,
        };
    }
};

pub fn Payload(comptime tag_type: TagType) type {
    return @FieldType(Tag, @tagName(tag_type));
}

/// Unsigned integer with the same bits as a scalar payload.
pub fn Bits(comptime tag_type: TagType) type {
    return @Int(.unsigned, @bitSizeOf(Payload(tag_type)));
}

pub const List = struct {
    element_type: TagType,
    items: []Tag,
};

pub const Entry = struct {
    name: []u8,
    value: Tag,

    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
    }
};

pub const Compound = struct {
    entries: []Entry,

    pub fn get(self: Compound, name: []const u8) ?*Tag {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return &entry.value;
        }

        return null;
    }
};

/// Owns all of its slices.
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
            .string, .byte_array => |value| allocator.free(value),
            .int_array => |value| allocator.free(value),
            .long_array => |value| allocator.free(value),

            .list => |list| {
                // Items are freed even in scalar lists, since a hand-built list may hold the wrong type.
                for (list.items) |*item| item.deinit(allocator);
                allocator.free(list.items);
            },

            .compound => |compound| {
                for (compound.entries) |*entry| entry.deinit(allocator);
                allocator.free(compound.entries);
            },

            else => {},
        }

        self.* = .{ .end = {} };
    }

    /// Floats compare by bits, so NaN equals itself and -0 differs from 0.
    pub fn eql(a: Tag, b: Tag) bool {
        if (a.tagType() != b.tagType()) return false;

        return switch (a) {
            .end => true,
            .byte => |value| value == b.byte,
            .short => |value| value == b.short,
            .int => |value| value == b.int,
            .long => |value| value == b.long,
            .float => |value| @as(u32, @bitCast(value)) == @as(u32, @bitCast(b.float)),
            .double => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(b.double)),
            .byte_array => |value| std.mem.eql(u8, value, b.byte_array),
            .string => |value| std.mem.eql(u8, value, b.string),
            .int_array => |value| std.mem.eql(i32, value, b.int_array),
            .long_array => |value| std.mem.eql(i64, value, b.long_array),

            .list => |value| {
                if (value.element_type != b.list.element_type) return false;
                if (value.items.len != b.list.items.len) return false;

                for (value.items, b.list.items) |left, right| {
                    if (!left.eql(right)) return false;
                }

                return true;
            },

            .compound => |value| {
                if (value.entries.len != b.compound.entries.len) return false;

                for (value.entries, b.compound.entries) |left, right| {
                    if (!std.mem.eql(u8, left.name, right.name)) return false;
                    if (!left.value.eql(right.value)) return false;
                }

                return true;
            },
        };
    }
};

pub const Document = struct {
    name: []u8,
    root: Tag,

    /// Copies `name` and takes `root` on success.
    pub fn init(
        allocator: Allocator,
        name: []const u8,
        root: Tag,
    ) (error{InvalidRoot} || Allocator.Error)!Document {
        if (root.tagType() == .end) return error.InvalidRoot;

        return .{
            .name = try allocator.dupe(u8, name),
            .root = root,
        };
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
