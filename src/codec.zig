const std = @import("std");
const Allocator = std.mem.Allocator;

const bounded_buffer = @import("internal/bounded_buffer.zig");
const options_mod = @import("options.zig");
const Options = options_mod.Options;
const types = @import("types.zig");
const Tag = types.Tag;
const TagType = types.TagType;

const small_compound_limit = 16;

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
    offset: usize = 0,
    allocated: usize = 0,
    options: Options,
    /// Shared by nested compounds; each copies its own run out when done.
    entries: std.ArrayList(types.Entry) = .empty,

    fn reserve(self: *Decoder, amount: usize) DecodeError!void {
        self.allocated = std.math.add(
            usize,
            self.allocated,
            amount,
        ) catch return error.SizeLimitExceeded;

        if (self.allocated > self.options.max_total_decoded_bytes) return error.SizeLimitExceeded;
    }

    fn take(self: *Decoder, len: usize) DecodeError![]const u8 {
        const end = std.math.add(
            usize,
            self.offset,
            len,
        ) catch return error.UnexpectedEndOfInput;

        if (end > self.data.len) return error.UnexpectedEndOfInput;

        defer self.offset = end;
        return self.data[self.offset..end];
    }

    fn byte(self: *Decoder) DecodeError!u8 {
        return (try self.take(1))[0];
    }

    fn tagType(self: *Decoder) DecodeError!TagType {
        return TagType.fromByte(try self.byte());
    }

    fn intFixed(self: *Decoder, comptime T: type) DecodeError!T {
        const bytes = try self.take(@sizeOf(T));
        const endian: std.builtin.Endian =
            if (self.options.encoding == .java) .big else .little;

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
                const value = try self.varUInt32();
                break :blk @bitCast(
                    (value >> 1) ^ (0 -% (value & 1)),
                );
            },

            i64 => blk: {
                const value = try self.varUInt64();
                break :blk @bitCast(
                    (value >> 1) ^ (0 -% (value & 1)),
                );
            },

            else => @compileError("varint is only defined for i32 and i64"),
        };
    }

    fn length(self: *Decoder) DecodeError!usize {
        const value = try self.int(i32);
        if (value < 0) return error.InvalidLength;

        const len: usize = @intCast(value);

        if (len > self.options.max_collection_length) return error.SizeLimitExceeded;

        return len;
    }

    fn string(self: *Decoder) DecodeError![]u8 {
        const len: usize = if (self.options.encoding == .bedrock_network)
            std.math.cast(
                usize,
                try self.varUInt32(),
            ) orelse return error.SizeLimitExceeded
        else
            @intCast(@as(u16, @bitCast(try self.intFixed(i16))));

        if (len > self.options.max_string_bytes) return error.SizeLimitExceeded;

        const encoded = try self.take(len);
        try self.reserve(len);

        if (self.options.encoding == .java) return decodeModifiedUtf8(self.allocator, encoded);

        if (!std.unicode.utf8ValidateSlice(encoded)) return error.InvalidUtf8;

        return self.allocator.dupe(u8, encoded);
    }

    fn payload(
        self: *Decoder,
        tag_type: TagType,
        depth: usize,
    ) DecodeError!Tag {
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

        const bytes = std.math.mul(
            usize,
            len,
            @sizeOf(T),
        ) catch return error.SizeLimitExceeded;

        try self.reserve(bytes);

        if (self.offset > self.data.len) return error.UnexpectedEndOfInput;

        const min_input_bytes = if (self.options.encoding == .bedrock_network)
            len
        else
            bytes;

        if (min_input_bytes > self.data.len - self.offset) return error.UnexpectedEndOfInput;

        const result = try self.allocator.alloc(T, len);
        errdefer self.allocator.free(result);

        if (self.options.encoding == .bedrock_network) {
            for (result) |*item| item.* = try self.int(T);
        } else {
            const input = try self.take(bytes);
            const endian: std.builtin.Endian = if (self.options.encoding == .java) .big else .little;
            if (endian == @import("builtin").cpu.arch.endian()) {
                @memcpy(std.mem.sliceAsBytes(result), input);
            } else {
                for (result, 0..) |*item, index| {
                    item.* = std.mem.readInt(T, input[index * @sizeOf(T) ..][0..@sizeOf(T)], endian);
                }
            }
        }

        return result;
    }

    fn minElementSize(self: *const Decoder, element_type: TagType) usize {
        const is_network = self.options.encoding == .bedrock_network;

        return switch (element_type) {
            .end => 0,
            .byte => 1,
            .short => 2,
            .int => if (is_network) 1 else 4,
            .long => if (is_network) 1 else 8,
            .float => 4,
            .double => 8,
            .byte_array, .int_array, .long_array => if (is_network) 1 else 4,
            .string => if (is_network) 1 else 2,
            .list => if (is_network) 2 else 5,
            .compound => 1,
        };
    }

    fn list(self: *Decoder, depth: usize) DecodeError!Tag {
        const element_type = try self.tagType();
        const len = try self.length();

        if (element_type == .end and len != 0) return error.InvalidListType;
        if (len != 0 and depth >= self.options.max_depth) return error.DepthLimitExceeded;

        const bytes = std.math.mul(
            usize,
            len,
            @sizeOf(Tag),
        ) catch return error.SizeLimitExceeded;

        try self.reserve(bytes);

        if (self.offset > self.data.len) return error.UnexpectedEndOfInput;

        if (element_type != .end and len > 0) {
            const min_elem_bytes = self.minElementSize(element_type);
            const min_input_bytes = std.math.mul(
                usize,
                len,
                min_elem_bytes,
            ) catch return error.SizeLimitExceeded;

            if (min_input_bytes > self.data.len - self.offset) return error.UnexpectedEndOfInput;
        }

        const items = try self.allocator.alloc(Tag, len);
        var initialized: usize = 0;

        errdefer {
            for (items[0..initialized]) |*item| {
                item.deinit(self.allocator);
            }

            self.allocator.free(items);
        }

        while (initialized < len) : (initialized += 1) {
            items[initialized] = try self.payload(element_type, depth);
        }

        return .{
            .list = .{
                .element_type = element_type,
                .items = items,
            },
        };
    }

    fn compound(self: *Decoder, depth: usize) DecodeError!Tag {
        const start = self.entries.items.len;
        var names: std.StringHashMapUnmanaged(void) = .empty;

        defer names.deinit(self.allocator);

        errdefer {
            for (self.entries.items[start..]) |*entry| {
                self.allocator.free(entry.name);
                entry.value.deinit(self.allocator);
            }

            self.entries.shrinkRetainingCapacity(start);
        }

        while (true) {
            const child_type = try self.tagType();
            if (child_type == .end) break;
            if (depth >= self.options.max_depth) return error.DepthLimitExceeded;

            const count = self.entries.items.len - start;
            const too_many_entries =
                count >= self.options.max_compound_entries or
                count >= self.options.max_collection_length;

            if (too_many_entries) return error.SizeLimitExceeded;

            try self.reserve(@sizeOf(types.Entry) * 4);

            const name = try self.string();
            errdefer self.allocator.free(name);

            const siblings = self.entries.items[start..];
            if (count < small_compound_limit) {
                for (siblings) |entry| {
                    if (std.mem.eql(u8, entry.name, name)) return error.DuplicateName;
                }
            } else {
                if (count == small_compound_limit) {
                    try names.ensureTotalCapacity(self.allocator, small_compound_limit + 1);
                    for (siblings) |entry| names.putAssumeCapacityNoClobber(entry.name, {});
                }
                const name_entry = try names.getOrPut(self.allocator, name);
                if (name_entry.found_existing) return error.DuplicateName;
                name_entry.value_ptr.* = {};
            }

            var value = try self.payload(child_type, depth);
            errdefer value.deinit(self.allocator);

            try self.entries.append(self.allocator, .{
                .name = name,
                .value = value,
            });
        }

        const entries = try self.allocator.dupe(types.Entry, self.entries.items[start..]);
        self.entries.shrinkRetainingCapacity(start);

        return .{ .compound = .{ .entries = entries } };
    }
};

pub fn decode(
    allocator: Allocator,
    data: []const u8,
    options: Options,
) DecodeError!types.Document {
    try options.validate();

    var decoder: Decoder = .{
        .allocator = allocator,
        .data = data,
        .options = options,
    };
    defer decoder.entries.deinit(allocator);

    const root_type = try decoder.tagType();
    if (root_type == .end) return error.InvalidRoot;

    const name = try decoder.string();
    errdefer allocator.free(name);

    var root = try decoder.payload(root_type, 0);
    errdefer root.deinit(allocator);

    const has_trailing_data =
        options.reject_trailing_bytes and
        decoder.offset != data.len;

    if (has_trailing_data) return error.TrailingData;

    return .{
        .name = name,
        .root = root,
    };
}

fn decodeModifiedUtf8(
    allocator: Allocator,
    encoded: []const u8,
) DecodeError![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.ensureTotalCapacityPrecise(allocator, encoded.len);

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

            unit = (@as(u16, first & 0x1f) << 6) |
                (second & 0x3f);

            if (unit != 0 and unit < 0x80) return error.InvalidModifiedUtf8;
        } else if (first & 0xf0 == 0xe0) {
            if (index + 1 >= encoded.len) return error.InvalidModifiedUtf8;

            const second = encoded[index];
            const third = encoded[index + 1];
            index += 2;

            if (second & 0xc0 != 0x80 or third & 0xc0 != 0x80) return error.InvalidModifiedUtf8;

            unit =
                (@as(u16, first & 0x0f) << 12) |
                (@as(u16, second & 0x3f) << 6) |
                (third & 0x3f);

            if (unit < 0x800) return error.InvalidModifiedUtf8;
        } else {
            return error.InvalidModifiedUtf8;
        }

        if (pending_high) |high| {
            if (unit < 0xdc00 or unit > 0xdfff) return error.InvalidModifiedUtf8;

            const scalar: u21 = @intCast(
                0x10000 +
                    ((@as(u32, high) - 0xd800) << 10) +
                    (@as(u32, unit) - 0xdc00),
            );

            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(
                scalar,
                &buffer,
            ) catch return error.InvalidModifiedUtf8;

            try result.appendSlice(allocator, buffer[0..len]);
            pending_high = null;
        } else if (unit >= 0xd800 and unit <= 0xdbff) {
            pending_high = unit;
        } else {
            if (unit >= 0xdc00 and unit <= 0xdfff) return error.InvalidModifiedUtf8;

            var buffer: [3]u8 = undefined;
            const len = std.unicode.utf8Encode(
                @intCast(unit),
                &buffer,
            ) catch return error.InvalidModifiedUtf8;

            try result.appendSlice(allocator, buffer[0..len]);
        }
    }

    if (pending_high != null) return error.InvalidModifiedUtf8;

    if (result.items.len == result.capacity) return result.toOwnedSliceAssert();
    return result.toOwnedSlice(allocator);
}

fn Encoder(comptime streaming: bool) type {
    return struct {
        const Self = @This();
        const EncodeError = Error || Allocator.Error || if (streaming) std.Io.Writer.Error else error{};
        allocator: Allocator,
        bytes: if (streaming) *std.Io.Writer else std.ArrayList(u8),
        written: usize = 0,
        options: Options,

        fn deinit(self: *Self) void {
            self.bytes.deinit(self.allocator);
        }

        inline fn append(
            self: *Self,
            data: []const u8,
        ) EncodeError!void {
            const end = std.math.add(
                usize,
                if (streaming) self.written else self.bytes.items.len,
                data.len,
            ) catch return error.SizeLimitExceeded;

            if (streaming) return self.write(data, end);

            // Capacity never exceeds the limit, so the fast path needs no check.
            if (end > self.bytes.capacity) try bounded_buffer.ensureCapacity(
                &self.bytes,
                self.allocator,
                end,
                self.options.max_output_bytes,
            );

            self.bytes.appendSliceAssumeCapacity(data);
        }

        // Out of line on purpose; inlining writeAll everywhere was slower.
        fn write(self: *Self, data: []const u8, end: usize) EncodeError!void {
            if (end > self.options.max_output_bytes) return error.SizeLimitExceeded;
            try self.bytes.writeAll(data);
            self.written = end;
        }

        fn byte(
            self: *Self,
            value: u8,
        ) EncodeError!void {
            try self.append(&.{value});
        }

        fn intFixed(
            self: *Self,
            comptime T: type,
            value: T,
        ) EncodeError!void {
            var buffer: [@sizeOf(T)]u8 = undefined;

            const endian: std.builtin.Endian =
                if (self.options.encoding == .java) .big else .little;

            std.mem.writeInt(T, &buffer, value, endian);
            try self.append(&buffer);
        }

        fn varUInt(
            self: *Self,
            comptime T: type,
            initial: T,
        ) EncodeError!void {
            var value = initial;
            var buffer: [(@bitSizeOf(T) + 6) / 7]u8 = undefined;
            var len: usize = 0;

            while (value >= 0x80) {
                buffer[len] = @truncate(value | 0x80);
                len += 1;
                value >>= 7;
            }

            buffer[len] = @truncate(value);
            try self.append(buffer[0 .. len + 1]);
        }

        fn int(
            self: *Self,
            comptime T: type,
            value: T,
        ) EncodeError!void {
            if (self.options.encoding != .bedrock_network) return self.intFixed(T, value);

            switch (T) {
                i32 => {
                    const unsigned: u32 = @bitCast(value);

                    try self.varUInt(
                        u32,
                        (unsigned << 1) ^
                            @as(u32, @bitCast(value >> 31)),
                    );
                },

                i64 => {
                    const unsigned: u64 = @bitCast(value);

                    try self.varUInt(
                        u64,
                        (unsigned << 1) ^
                            @as(u64, @bitCast(value >> 63)),
                    );
                },

                else => @compileError("varint is only defined for i32 and i64"),
            }
        }

        fn length(
            self: *Self,
            value: usize,
        ) EncodeError!void {
            const invalid_length =
                value > self.options.max_collection_length or
                value > std.math.maxInt(i32);

            if (invalid_length) return error.SizeLimitExceeded;

            try self.int(i32, @intCast(value));
        }

        fn numberArray(self: *Self, comptime T: type, values: []const T) EncodeError!void {
            try self.length(values.len);
            if (self.options.encoding == .bedrock_network) {
                for (values) |value| try self.int(T, value);
                return;
            }
            _ = std.math.mul(usize, values.len, @sizeOf(T)) catch return error.SizeLimitExceeded;
            const endian: std.builtin.Endian = if (self.options.encoding == .java) .big else .little;
            if (endian == @import("builtin").cpu.arch.endian()) return self.append(std.mem.sliceAsBytes(values));

            var buffer: [256]u8 = undefined;
            var offset: usize = 0;
            while (offset < values.len) {
                const count: usize = @min(values.len - offset, buffer.len / @sizeOf(T));
                for (values[offset..][0..count], 0..) |value, index| {
                    std.mem.writeInt(T, buffer[index * @sizeOf(T) ..][0..@sizeOf(T)], value, endian);
                }
                try self.append(buffer[0 .. count * @sizeOf(T)]);
                offset += count;
            }
        }

        fn string(
            self: *Self,
            value: []const u8,
        ) EncodeError!void {
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;

            if (self.options.encoding == .java) return self.modifiedString(value);

            if (value.len > self.options.max_string_bytes) return error.SizeLimitExceeded;

            if (self.options.encoding == .bedrock_network) {
                if (value.len > std.math.maxInt(u32)) return error.SizeLimitExceeded;

                try self.varUInt(u32, @intCast(value.len));
            } else {
                if (value.len > std.math.maxInt(u16)) return error.SizeLimitExceeded;

                try self.intFixed(
                    i16,
                    @bitCast(@as(u16, @intCast(value.len))),
                );
            }

            try self.append(value);
        }

        fn modifiedString(
            self: *Self,
            value: []const u8,
        ) EncodeError!void {
            const view = std.unicode.Utf8View.initUnchecked(value);
            var iterator = view.iterator();

            var encoded_len: usize = 0;

            while (iterator.nextCodepoint()) |codepoint| {
                const width: usize =
                    if (codepoint >= 1 and codepoint <= 0x7f)
                        1
                    else if (codepoint <= 0x7ff)
                        2
                    else if (codepoint <= 0xffff)
                        3
                    else
                        6;

                encoded_len = std.math.add(
                    usize,
                    encoded_len,
                    width,
                ) catch return error.SizeLimitExceeded;

                const too_long =
                    encoded_len > self.options.max_string_bytes or
                    encoded_len > std.math.maxInt(u16);

                if (too_long) return error.SizeLimitExceeded;
            }

            try self.intFixed(
                i16,
                @bitCast(@as(u16, @intCast(encoded_len))),
            );

            iterator = view.iterator();

            while (iterator.nextCodepoint()) |codepoint| {
                if (codepoint <= 0xffff) {
                    try self.mutfUnit(@intCast(codepoint));
                } else {
                    const adjusted = codepoint - 0x10000;

                    try self.mutfUnit(
                        @intCast(0xd800 + (adjusted >> 10)),
                    );
                    try self.mutfUnit(
                        @intCast(0xdc00 + (adjusted & 0x3ff)),
                    );
                }
            }
        }

        fn mutfUnit(
            self: *Self,
            unit: u16,
        ) EncodeError!void {
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

        fn payload(
            self: *Self,
            tag: Tag,
            depth: usize,
        ) EncodeError!void {
            if (depth >= self.options.max_depth) return error.DepthLimitExceeded;

            switch (tag) {
                .end => return error.InvalidTag,
                .byte => |value| try self.byte(@bitCast(value)),
                .short => |value| try self.intFixed(i16, value),
                .int => |value| try self.int(i32, value),
                .long => |value| try self.int(i64, value),
                .float => |value| try self.intFixed(u32, @bitCast(value)),
                .double => |value| try self.intFixed(u64, @bitCast(value)),

                .byte_array => |value| {
                    try self.length(value.len);
                    try self.append(value);
                },

                .string => |value| try self.string(value),

                .int_array => |value| try self.numberArray(i32, value),
                .long_array => |value| try self.numberArray(i64, value),

                .list => |value| {
                    if (value.element_type == .end and value.items.len != 0) return error.InvalidListType;
                    if (value.items.len != 0 and depth + 1 >= self.options.max_depth) return error.DepthLimitExceeded;

                    try self.byte(@backingInt(value.element_type));
                    try self.length(value.items.len);

                    for (value.items) |item| {
                        if (item.tagType() != value.element_type) return error.TypeMismatch;

                        try self.payload(item, depth + 1);
                    }
                },

                .compound => |value| {
                    const too_many_entries =
                        value.entries.len > self.options.max_compound_entries or
                        value.entries.len > self.options.max_collection_length;

                    if (too_many_entries) return error.SizeLimitExceeded;
                    if (value.entries.len != 0 and depth + 1 >= self.options.max_depth) return error.DepthLimitExceeded;

                    const index_budget = std.math.mul(
                        usize,
                        value.entries.len,
                        @sizeOf(types.Entry) * 2,
                    ) catch return error.SizeLimitExceeded;

                    if (index_budget > self.options.max_total_decoded_bytes) return error.SizeLimitExceeded;

                    var names: std.StringHashMapUnmanaged(void) = .empty;
                    defer names.deinit(self.allocator);
                    if (value.entries.len > small_compound_limit) {
                        const count = std.math.cast(u32, value.entries.len) orelse return error.SizeLimitExceeded;
                        try names.ensureTotalCapacity(self.allocator, count);
                    }

                    for (value.entries, 0..) |entry, index| {
                        if (value.entries.len <= small_compound_limit) {
                            for (value.entries[0..index]) |previous| {
                                if (std.mem.eql(u8, previous.name, entry.name)) return error.DuplicateName;
                            }
                        } else {
                            const name_entry = names.getOrPutAssumeCapacity(entry.name);
                            if (name_entry.found_existing) return error.DuplicateName;
                            name_entry.value_ptr.* = {};
                        }

                        const tag_type = entry.value.tagType();
                        if (tag_type == .end) return error.InvalidTag;

                        try self.byte(@backingInt(tag_type));
                        try self.string(entry.name);
                        try self.payload(entry.value, depth + 1);
                    }

                    try self.byte(@backingInt(TagType.end));
                },
            }
        }
        fn document(self: *Self, value: types.Document) EncodeError!void {
            try self.options.validate();
            const root_type = value.root.tagType();
            if (root_type == .end) return error.InvalidRoot;
            try self.byte(@backingInt(root_type));
            try self.string(value.name);
            try self.payload(value.root, 0);
        }
    };
}

pub fn encode(
    allocator: Allocator,
    document: types.Document,
    options: Options,
) (Error || Allocator.Error)![]u8 {
    var encoder: Encoder(false) = .{
        .allocator = allocator,
        .bytes = .empty,
        .options = options,
    };
    errdefer encoder.deinit();

    const hint = 3 +| document.name.len +| sizeHint(document.root, options.max_depth);
    try encoder.bytes.ensureTotalCapacityPrecise(allocator, @min(hint, options.max_output_bytes));
    try encoder.document(document);

    return encoder.bytes.toOwnedSlice(allocator);
}

/// Rough output size, so encode allocates once.
fn sizeHint(tag: Tag, depth: usize) usize {
    if (depth == 0) return 0;
    return switch (tag) {
        .end => 0,
        .byte => 1,
        .short => 2,
        .int, .float => 4,
        .long, .double => 8,
        .string => |value| 2 +| value.len,
        .byte_array => |value| 4 +| value.len,
        .int_array => |value| 4 +| value.len *| 4,
        .long_array => |value| 4 +| value.len *| 8,
        .list => |value| blk: {
            switch (value.element_type) {
                .byte, .short, .int, .long, .float, .double => if (value.items.len != 0)
                    break :blk 5 +| value.items.len *| sizeHint(value.items[0], depth - 1),
                else => {},
            }
            var size: usize = 5;
            for (value.items) |item| size +|= sizeHint(item, depth - 1);
            break :blk size;
        },
        .compound => |value| blk: {
            var size: usize = 1;
            for (value.entries) |entry| size +|= 3 +| entry.name.len +| sizeHint(entry.value, depth - 1);
            break :blk size;
        },
    };
}

pub fn encodeWriter(
    allocator: Allocator,
    writer: *std.Io.Writer,
    document: types.Document,
    options: Options,
) (Error || Allocator.Error || std.Io.Writer.Error)!void {
    var encoder: Encoder(true) = .{
        .allocator = allocator,
        .bytes = writer,
        .options = options,
    };
    try encoder.document(document);
}
