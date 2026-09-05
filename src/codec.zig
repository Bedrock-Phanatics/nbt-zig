const std = @import("std");
const types = @import("types.zig");
const options_mod = @import("options.zig");
const bounded_buffer = @import("internal/bounded_buffer.zig");

const Allocator = std.mem.Allocator;
const Tag = types.Tag;
const TagType = types.TagType;
const Options = options_mod.Options;

pub const Error = error{
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

const DecodeError = Error || Allocator.Error;

const Decoder = struct {
    allocator: Allocator,
    data: []const u8,
    pos: usize = 0,
    allocated: usize = 0,
    options: Options,

    fn reserve(self: *Decoder, amount: usize) DecodeError!void {
        self.allocated = std.math.add(usize, self.allocated, amount) catch return error.SizeLimitExceeded;
        if (self.allocated > self.options.max_total_decoded_bytes) return error.SizeLimitExceeded;
    }

    fn take(self: *Decoder, n: usize) DecodeError![]const u8 {
        const end = std.math.add(usize, self.pos, n) catch return error.UnexpectedEndOfInput;
        if (end > self.data.len) return error.UnexpectedEndOfInput;
        defer self.pos = end;
        return self.data[self.pos..end];
    }

    fn byte(self: *Decoder) DecodeError!u8 {
        return (try self.take(1))[0];
    }

    fn tagType(self: *Decoder) DecodeError!TagType {
        return TagType.fromByte(try self.byte());
    }

    fn intFixed(self: *Decoder, comptime T: type) DecodeError!T {
        const bytes = try self.take(@sizeOf(T));
        const endian: std.builtin.Endian = if (self.options.encoding == .java) .big else .little;
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], endian);
    }

    fn varUInt32(self: *Decoder) DecodeError!u32 {
        var value: u32 = 0;
        var shift: u6 = 0;
        while (shift < 35) : (shift += 7) {
            const current = try self.byte();
            if (shift == 28 and current & 0xf0 != 0) return error.VarIntOverflow;
            value |= @as(u32, current & 0x7f) << @intCast(shift);
            if (current & 0x80 == 0) return value;
        }
        return error.VarIntOverflow;
    }

    fn varUInt64(self: *Decoder) DecodeError!u64 {
        var value: u64 = 0;
        var shift: u7 = 0;
        while (shift < 70) : (shift += 7) {
            const current = try self.byte();
            if (shift == 63 and current & 0xfe != 0) return error.VarIntOverflow;
            value |= @as(u64, current & 0x7f) << @intCast(shift);
            if (current & 0x80 == 0) return value;
        }
        return error.VarIntOverflow;
    }

    fn int(self: *Decoder, comptime T: type) DecodeError!T {
        if (self.options.encoding != .bedrock_network) return self.intFixed(T);
        return switch (T) {
            i32 => blk: {
                const n = try self.varUInt32();
                break :blk @bitCast((n >> 1) ^ (0 -% (n & 1)));
            },
            i64 => blk: {
                const n = try self.varUInt64();
                break :blk @bitCast((n >> 1) ^ (0 -% (n & 1)));
            },
            else => @compileError("varint is only defined for i32 and i64"),
        };
    }

    fn length(self: *Decoder) DecodeError!usize {
        const signed = try self.int(i32);
        if (signed < 0) return error.InvalidLength;
        const result: usize = @intCast(signed);
        if (result > self.options.max_collection_length) return error.SizeLimitExceeded;
        return result;
    }

    fn string(self: *Decoder) DecodeError![]u8 {
        const len: usize = if (self.options.encoding == .java)
            @intCast(@as(u16, @bitCast(try self.intFixed(i16))))
        else if (self.options.encoding == .bedrock_network)
            std.math.cast(usize, try self.varUInt32()) orelse return error.SizeLimitExceeded
        else
            @intCast(@as(u16, @bitCast(try self.intFixed(i16))));
        if (len > self.options.max_string_bytes) return error.SizeLimitExceeded;
        const encoded = try self.take(len);
        try self.reserve(len);
        if (self.options.encoding == .java) return decodeModifiedUtf8(self.allocator, encoded);
        if (!std.unicode.utf8ValidateSlice(encoded)) return error.InvalidUtf8;
        return self.allocator.dupe(u8, encoded);
    }

    fn payload(self: *Decoder, tag_type: TagType, depth: usize) DecodeError!Tag {
        if (depth >= self.options.max_depth) return error.DepthLimitExceeded;
        return switch (tag_type) {
            .end => error.InvalidTag,
            .byte => .{ .byte = @bitCast(try self.byte()) },
            .short => .{ .short = try self.intFixed(i16) },
            .int => .{ .int = try self.int(i32) },
            .long => .{ .long = try self.int(i64) },
            .float => .{ .float = @bitCast(try self.intFixed(u32)) },
            .double => .{ .double = @bitCast(try self.intFixed(u64)) },
            .byte_array => .{ .byte_array = try self.byteArray() },
            .string => .{ .string = try self.string() },
            .list => try self.list(depth + 1),
            .compound => try self.compound(depth + 1),
            .int_array => .{ .int_array = try self.numberArray(i32) },
            .long_array => .{ .long_array = try self.numberArray(i64) },
        };
    }

    fn byteArray(self: *Decoder) DecodeError![]u8 {
        const len = try self.length();
        try self.reserve(len);
        return self.allocator.dupe(u8, try self.take(len));
    }

    fn numberArray(self: *Decoder, comptime T: type) DecodeError![]T {
        const len = try self.length();
        const bytes = std.math.mul(usize, len, @sizeOf(T)) catch return error.SizeLimitExceeded;
        try self.reserve(bytes);
        const result = try self.allocator.alloc(T, len);
        errdefer self.allocator.free(result);
        for (result) |*item| item.* = try self.int(T);
        return result;
    }

    fn list(self: *Decoder, depth: usize) DecodeError!Tag {
        const element_type = try self.tagType();
        const len = try self.length();
        if (element_type == .end and len != 0) return error.InvalidListType;
        const bytes = std.math.mul(usize, len, @sizeOf(Tag)) catch return error.SizeLimitExceeded;
        try self.reserve(bytes);
        const items = try self.allocator.alloc(Tag, len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
        }
        while (initialized < len) : (initialized += 1) {
            items[initialized] = try self.payload(element_type, depth);
        }
        return .{ .list = .{ .element_type = element_type, .items = items } };
    }

    fn compound(self: *Decoder, depth: usize) DecodeError!Tag {
        var entries: std.ArrayList(types.Entry) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(self.allocator);
        errdefer {
            for (entries.items) |*entry| {
                self.allocator.free(entry.name);
                entry.value.deinit(self.allocator);
            }
            entries.deinit(self.allocator);
        }
        while (true) {
            const child_type = try self.tagType();
            if (child_type == .end) break;
            if (entries.items.len >= self.options.max_compound_entries or entries.items.len >= self.options.max_collection_length)
                return error.SizeLimitExceeded;
            // Include spare list and duplicate-index storage.
            try self.reserve(@sizeOf(types.Entry) * 4);
            const name = try self.string();
            errdefer self.allocator.free(name);
            const name_result = try names.getOrPut(self.allocator, name);
            if (name_result.found_existing) return error.DuplicateName;
            name_result.value_ptr.* = {};
            var value = try self.payload(child_type, depth);
            errdefer value.deinit(self.allocator);
            try entries.append(self.allocator, .{ .name = name, .value = value });
        }
        return .{ .compound = .{ .entries = try entries.toOwnedSlice(self.allocator) } };
    }
};

pub fn decode(allocator: Allocator, data: []const u8, options: Options) DecodeError!types.Document {
    try options.validate();
    var decoder: Decoder = .{ .allocator = allocator, .data = data, .options = options };
    const root_type = try decoder.tagType();
    if (root_type == .end) return error.InvalidRoot;
    const name = try decoder.string();
    errdefer allocator.free(name);
    var root = try decoder.payload(root_type, 0);
    errdefer root.deinit(allocator);
    if (options.reject_trailing_bytes and decoder.pos != data.len) return error.TrailingData;
    return .{ .name = name, .root = root };
}

fn decodeModifiedUtf8(allocator: Allocator, encoded: []const u8) DecodeError![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, encoded.len);
    var index: usize = 0;
    var pending_high: ?u16 = null;
    while (index < encoded.len) {
        const first = encoded[index];
        index += 1;
        var unit: u16 = undefined;
        if (first <= 0x7f) {
            if (first == 0) return error.InvalidModifiedUtf8;
            unit = first;
        } else if (first & 0xe0 == 0xc0) {
            if (index >= encoded.len) return error.InvalidModifiedUtf8;
            const second = encoded[index];
            index += 1;
            if (second & 0xc0 != 0x80) return error.InvalidModifiedUtf8;
            unit = (@as(u16, first & 0x1f) << 6) | (second & 0x3f);
            if (unit != 0 and unit < 0x80) return error.InvalidModifiedUtf8;
        } else if (first & 0xf0 == 0xe0) {
            if (index + 1 >= encoded.len) return error.InvalidModifiedUtf8;
            const second = encoded[index];
            const third = encoded[index + 1];
            index += 2;
            if (second & 0xc0 != 0x80 or third & 0xc0 != 0x80) return error.InvalidModifiedUtf8;
            unit = (@as(u16, first & 0x0f) << 12) | (@as(u16, second & 0x3f) << 6) | (third & 0x3f);
            if (unit < 0x800) return error.InvalidModifiedUtf8;
        } else return error.InvalidModifiedUtf8;

        if (pending_high) |high| {
            if (unit < 0xdc00 or unit > 0xdfff) return error.InvalidModifiedUtf8;
            const scalar: u21 = @intCast(0x10000 + ((@as(u32, high) - 0xd800) << 10) + (@as(u32, unit) - 0xdc00));
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(scalar, &buf) catch return error.InvalidModifiedUtf8;
            try result.appendSlice(allocator, buf[0..n]);
            pending_high = null;
        } else if (unit >= 0xd800 and unit <= 0xdbff) {
            pending_high = unit;
        } else {
            if (unit >= 0xdc00 and unit <= 0xdfff) return error.InvalidModifiedUtf8;
            var buf: [3]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(unit), &buf) catch return error.InvalidModifiedUtf8;
            try result.appendSlice(allocator, buf[0..n]);
        }
    }
    if (pending_high != null) return error.InvalidModifiedUtf8;
    return result.toOwnedSlice(allocator);
}

const Encoder = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    options: Options,

    fn deinit(self: *Encoder) void {
        self.bytes.deinit(self.allocator);
    }

    fn append(self: *Encoder, data: []const u8) (Error || Allocator.Error)!void {
        const end = std.math.add(usize, self.bytes.items.len, data.len) catch return error.SizeLimitExceeded;
        try bounded_buffer.ensureCapacity(&self.bytes, self.allocator, end, self.options.max_output_bytes);
        self.bytes.appendSliceAssumeCapacity(data);
    }

    fn byte(self: *Encoder, value: u8) (Error || Allocator.Error)!void {
        try self.append(&.{value});
    }

    fn intFixed(self: *Encoder, comptime T: type, value: T) (Error || Allocator.Error)!void {
        var buf: [@sizeOf(T)]u8 = undefined;
        const endian: std.builtin.Endian = if (self.options.encoding == .java) .big else .little;
        std.mem.writeInt(T, &buf, value, endian);
        try self.append(&buf);
    }

    fn varUInt(self: *Encoder, comptime T: type, initial: T) (Error || Allocator.Error)!void {
        var value = initial;
        while (value >= 0x80) {
            try self.byte(@truncate(value | 0x80));
            value >>= 7;
        }
        try self.byte(@truncate(value));
    }

    fn int(self: *Encoder, comptime T: type, value: T) (Error || Allocator.Error)!void {
        if (self.options.encoding != .bedrock_network) return self.intFixed(T, value);
        switch (T) {
            i32 => {
                const unsigned: u32 = @bitCast(value);
                try self.varUInt(u32, (unsigned << 1) ^ @as(u32, @bitCast(value >> 31)));
            },
            i64 => {
                const unsigned: u64 = @bitCast(value);
                try self.varUInt(u64, (unsigned << 1) ^ @as(u64, @bitCast(value >> 63)));
            },
            else => @compileError("varint is only defined for i32 and i64"),
        }
    }

    fn length(self: *Encoder, value: usize) (Error || Allocator.Error)!void {
        if (value > self.options.max_collection_length or value > std.math.maxInt(i32)) return error.SizeLimitExceeded;
        try self.int(i32, @intCast(value));
    }

    fn string(self: *Encoder, value: []const u8) (Error || Allocator.Error)!void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        if (self.options.encoding == .java) return self.modifiedString(value);
        if (value.len > self.options.max_string_bytes) return error.SizeLimitExceeded;
        if (self.options.encoding == .bedrock_network) {
            if (value.len > std.math.maxInt(u32)) return error.SizeLimitExceeded;
            try self.varUInt(u32, @intCast(value.len));
        } else {
            if (value.len > std.math.maxInt(u16)) return error.SizeLimitExceeded;
            try self.intFixed(i16, @bitCast(@as(u16, @intCast(value.len))));
        }
        try self.append(value);
    }

    fn modifiedString(self: *Encoder, value: []const u8) (Error || Allocator.Error)!void {
        var view = std.unicode.Utf8View.init(value) catch return error.InvalidUtf8;
        var iterator = view.iterator();
        var encoded_len: usize = 0;
        while (iterator.nextCodepoint()) |cp| {
            const width: usize = if (cp >= 1 and cp <= 0x7f) 1 else if (cp <= 0x7ff) 2 else if (cp <= 0xffff) 3 else 6;
            encoded_len = std.math.add(usize, encoded_len, width) catch return error.SizeLimitExceeded;
            if (encoded_len > self.options.max_string_bytes or encoded_len > std.math.maxInt(u16)) return error.SizeLimitExceeded;
        }

        try self.intFixed(i16, @bitCast(@as(u16, @intCast(encoded_len))));
        view = std.unicode.Utf8View.initUnchecked(value);
        iterator = view.iterator();
        while (iterator.nextCodepoint()) |cp| {
            if (cp <= 0xffff) {
                try self.mutfUnit(@intCast(cp));
            } else {
                const adjusted = cp - 0x10000;
                try self.mutfUnit(@intCast(0xd800 + (adjusted >> 10)));
                try self.mutfUnit(@intCast(0xdc00 + (adjusted & 0x3ff)));
            }
        }
    }

    fn mutfUnit(self: *Encoder, unit: u16) (Error || Allocator.Error)!void {
        if (unit >= 1 and unit <= 0x7f) {
            try self.byte(@intCast(unit));
        } else if (unit <= 0x7ff) {
            try self.byte(@intCast(0xc0 | (unit >> 6)));
            try self.byte(@intCast(0x80 | (unit & 0x3f)));
        } else {
            try self.byte(@intCast(0xe0 | (unit >> 12)));
            try self.byte(@intCast(0x80 | ((unit >> 6) & 0x3f)));
            try self.byte(@intCast(0x80 | (unit & 0x3f)));
        }
    }
    fn payload(self: *Encoder, tag: Tag, depth: usize) (Error || Allocator.Error)!void {
        if (depth >= self.options.max_depth) return error.DepthLimitExceeded;
        switch (tag) {
            .end => return error.InvalidTag,
            .byte => |v| try self.byte(@bitCast(v)),
            .short => |v| try self.intFixed(i16, v),
            .int => |v| try self.int(i32, v),
            .long => |v| try self.int(i64, v),
            .float => |v| try self.intFixed(u32, @bitCast(v)),
            .double => |v| try self.intFixed(u64, @bitCast(v)),
            .byte_array => |v| {
                try self.length(v.len);
                try self.append(v);
            },
            .string => |v| try self.string(v),
            .int_array => |v| {
                try self.length(v.len);
                for (v) |item| try self.int(i32, item);
            },
            .long_array => |v| {
                try self.length(v.len);
                for (v) |item| try self.int(i64, item);
            },
            .list => |v| {
                if (v.element_type == .end and v.items.len != 0) return error.InvalidListType;
                try self.byte(@intFromEnum(v.element_type));
                try self.length(v.items.len);
                for (v.items) |item| {
                    if (item.tagType() != v.element_type) return error.TypeMismatch;
                    try self.payload(item, depth + 1);
                }
            },
            .compound => |v| {
                if (v.entries.len > self.options.max_compound_entries or v.entries.len > self.options.max_collection_length) return error.SizeLimitExceeded;
                const index_budget = std.math.mul(usize, v.entries.len, @sizeOf(types.Entry) * 2) catch return error.SizeLimitExceeded;
                if (index_budget > self.options.max_total_decoded_bytes) return error.SizeLimitExceeded;
                var names: std.StringHashMapUnmanaged(void) = .empty;
                defer names.deinit(self.allocator);
                for (v.entries) |entry| {
                    const name_result = try names.getOrPut(self.allocator, entry.name);
                    if (name_result.found_existing) return error.DuplicateName;
                    name_result.value_ptr.* = {};
                    if (entry.value.tagType() == .end) return error.InvalidTag;
                    try self.byte(@intFromEnum(entry.value.tagType()));
                    try self.string(entry.name);
                    try self.payload(entry.value, depth + 1);
                }
                try self.byte(@intFromEnum(TagType.end));
            },
        }
    }
};

pub fn encode(allocator: Allocator, document: types.Document, options: Options) (Error || Allocator.Error)![]u8 {
    try options.validate();
    if (document.root.tagType() == .end) return error.InvalidRoot;
    var encoder: Encoder = .{ .allocator = allocator, .options = options };
    errdefer encoder.deinit();
    try encoder.byte(@intFromEnum(document.root.tagType()));
    try encoder.string(document.name);
    try encoder.payload(document.root, 0);
    return encoder.bytes.toOwnedSlice(allocator);
}
