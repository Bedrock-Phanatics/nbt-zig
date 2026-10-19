const std = @import("std");
const Allocator = std.mem.Allocator;
const native_endian = @import("builtin").cpu.arch.endian();

const BoundedWriter = @import("internal/BoundedWriter.zig");
const endian_swap = @import("internal/endian.zig");
const unique_names = @import("internal/unique_names.zig");
const utf8 = @import("utf8.zig");
const options_mod = @import("options.zig");
const Format = options_mod.Format;
const Options = options_mod.Options;
const types = @import("types.zig");
const Bits = types.Bits;
const Compound = types.Compound;
const Document = types.Document;
const Entry = types.Entry;
const List = types.List;
const Payload = types.Payload;
const Tag = types.Tag;
const TagType = types.TagType;

pub const Error = types.CodecError || Allocator.Error;
pub const WriteError = Error || std.Io.Writer.Error;

pub fn encode(allocator: Allocator, document: Document, options: Options) Error![]u8 {
    return encodeWith(allocator, document, options, write);
}

pub fn encodePayload(allocator: Allocator, tag: Tag, options: Options) Error![]u8 {
    return encodeWith(allocator, tag, options, writePayload);
}

fn encodeWith(
    allocator: Allocator,
    value: anytype,
    options: Options,
    comptime writeFn: fn (Allocator, *std.Io.Writer, @TypeOf(value), Options) WriteError!void,
) Error![]u8 {
    // Oversized or unencodable values leave the matching error to the encoder.
    const bound = measure(value, options, false);
    const size = if (bound > options.max_output_bytes) 0 else bound;

    var output = try BoundedWriter.init(allocator, options.max_output_bytes, size);
    defer output.deinit();

    writeFn(allocator, &output.writer, value, options) catch |err| return switch (err) {
        error.WriteFailed => output.err(),
        else => |e| e,
    };

    return output.toOwnedSlice();
}

pub fn write(allocator: Allocator, writer: *std.Io.Writer, document: Document, options: Options) WriteError!void {
    switch (options.format()) {
        inline else => |format| {
            var encoder: Encoder(format) = .{ .allocator = allocator, .writer = writer, .options = options };
            defer encoder.names.deinit(allocator);

            try encoder.document(document);
        },
    }
}

pub fn writePayload(allocator: Allocator, writer: *std.Io.Writer, tag: Tag, options: Options) WriteError!void {
    switch (options.format()) {
        inline else => |format| {
            var encoder: Encoder(format) = .{ .allocator = allocator, .writer = writer, .options = options };
            defer encoder.names.deinit(allocator);

            try encoder.payload(&tag, 0);
        },
    }
}

/// Exact uncompressed size `write` or `writePayload` produces for a `Document` or `Tag`
/// when it succeeds. Only nesting is checked, so the walk stays bounded.
pub fn encodedLength(value: anytype, options: Options) error{DepthLimitExceeded}!usize {
    const size = measure(value, options, true);
    if (size == unencodable) return error.DepthLimitExceeded;
    return size;
}

/// Sizes saturate, so nothing real reaches this.
const unencodable = std.math.maxInt(usize);

/// Inexact sizes never fall short, they just assume the widest network varints so
/// arrays and lists cost nothing to measure.
fn measure(value: anytype, options: Options, comptime exact: bool) usize {
    return switch (options.format()) {
        inline else => |format| switch (@TypeOf(value)) {
            Document => 1 +| Encoder(format).stringSize(value.name) +| Encoder(format).payloadSize(options, value.root, 0, exact),
            Tag => Encoder(format).payloadSize(options, value, 0, exact),
            else => @compileError("expected a Document or Tag"),
        },
    };
}

fn varLen(value: u64) usize {
    return if (value == 0) 1 else (64 - @as(usize, @clz(value)) + 6) / 7;
}

fn zigzag(value: i64) u64 {
    return @bitCast((value << 1) ^ (value >> 63));
}

fn Encoder(comptime format: Format) type {
    return struct {
        const Self = @This();

        const encoding = format.encoding();

        const endian: std.builtin.Endian = if (encoding == .java) .big else .little;
        const varints = encoding == .bedrock_network;

        allocator: Allocator,
        writer: *std.Io.Writer,
        options: Options,
        written: usize = 0,
        names: unique_names.Checker = .{},

        fn stringSize(value: []const u8) usize {
            const transcoded = encoding == .java and !format.rawStrings() and !utf8.isModifiedPlain(value);
            const len = if (transcoded) utf8.modifiedLen(value) else value.len;
            return (if (varints) varLen(len) else 2) +| len;
        }

        fn lengthSize(len: usize) usize {
            return if (varints) varLen(@as(u64, len) *| 2) else 4;
        }

        fn intSize(comptime T: type, value: T, comptime exact: bool) usize {
            if (!varints) return @sizeOf(T);
            return if (exact) varLen(zigzag(value)) else (@bitSizeOf(T) + 6) / 7;
        }

        fn payloadSize(options: Options, tag: Tag, depth: usize, comptime exact: bool) usize {
            return switch (tag) {
                .end => 0,
                .byte => 1,
                .short => 2,
                .float => 4,
                .double => 8,
                .int => |value| intSize(i32, value, exact),
                .long => |value| intSize(i64, value, exact),
                .string => |value| stringSize(value),
                .byte_array => |value| lengthSize(value.len) +| value.len,
                inline .int_array, .long_array => |values| {
                    const T = @TypeOf(values[0]);
                    var size = lengthSize(values.len);
                    if (!varints or !exact) return size +| values.len *| intSize(T, 0, false);

                    for (values) |value| size +|= varLen(zigzag(value));
                    return size;
                },

                .list => |value| {
                    if (value.items.len != 0 and depth + 1 >= options.max_depth) return unencodable;

                    var size = 1 +| lengthSize(value.items.len);
                    const fixed_width = switch (value.element_type) {
                        .byte, .short, .float, .double => true,
                        .int, .long => !varints or !exact,
                        else => false,
                    };

                    if (fixed_width and value.items.len != 0) {
                        return size +| value.items.len *| payloadSize(options, value.items[0], depth + 1, exact);
                    }

                    for (value.items) |item| size +|= payloadSize(options, item, depth + 1, exact);
                    return size;
                },

                .compound => |value| {
                    if (value.entries.len != 0 and depth + 1 >= options.max_depth) return unencodable;

                    var size: usize = 1;
                    for (value.entries) |entry| {
                        size +|= 1 +| stringSize(entry.name) +| payloadSize(options, entry.value, depth + 1, exact);
                    }

                    return size;
                },
            };
        }

        fn document(self: *Self, value: Document) WriteError!void {
            const root_type = value.root.tagType();
            if (root_type == .end) return error.InvalidRoot;

            try self.byte(@backingInt(root_type));
            try self.string(value.name);
            try self.payload(&value.root, 0);
        }

        /// Inline so the many tiny fixed-size writes become plain stores.
        inline fn bytes(self: *Self, data: []const u8) WriteError!void {
            const end = std.math.add(usize, self.written, data.len) catch return error.SizeLimitExceeded;
            if (end > self.options.max_output_bytes) return error.SizeLimitExceeded;

            const w = self.writer;
            if (w.buffer.len - w.end >= data.len) {
                @memcpy(w.buffer[w.end..][0..data.len], data);
                w.end += data.len;
            } else {
                try w.writeAll(data);
            }

            self.written = end;
        }

        /// Writable capacity that is also within the output limit.
        fn spare(self: *Self) []u8 {
            const w = self.writer;
            return w.buffer[w.end..][0..@min(w.buffer.len - w.end, self.options.max_output_bytes -| self.written)];
        }

        /// Claims `len` bytes of spare capacity to fill in place, if they fit.
        fn direct(self: *Self, len: usize) ?[]u8 {
            const w = self.writer;
            const end = std.math.add(usize, self.written, len) catch return null;
            if (end > self.options.max_output_bytes or w.buffer.len - w.end < len) return null;

            defer {
                w.end += len;
                self.written = end;
            }
            return w.buffer[w.end..][0..len];
        }

        fn byte(self: *Self, value: u8) WriteError!void {
            try self.bytes(&.{value});
        }

        fn fixed(self: *Self, comptime T: type, value: T) WriteError!void {
            var buffer: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buffer, value, endian);
            try self.bytes(&buffer);
        }

        fn varUInt(self: *Self, comptime T: type, initial: T) WriteError!void {
            var buffer: [(@bitSizeOf(T) + 6) / 7]u8 = undefined;
            var value = initial;
            var len: usize = 0;

            while (value >= 0x80) : (len += 1) {
                buffer[len] = @truncate(value | 0x80);
                value >>= 7;
            }

            buffer[len] = @truncate(value);
            try self.bytes(buffer[0 .. len + 1]);
        }

        fn scalar(self: *Self, comptime tag_type: TagType, value: Payload(tag_type)) WriteError!void {
            const T = Payload(tag_type);

            if (varints and (T == i32 or T == i64)) {
                const Unsigned = Bits(tag_type);
                const unsigned: Unsigned = @bitCast(value);
                return self.varUInt(Unsigned, (unsigned << 1) ^ @as(Unsigned, @bitCast(value >> (@bitSizeOf(T) - 1))));
            }

            try self.fixed(Bits(tag_type), @bitCast(value));
        }

        fn length(self: *Self, len: usize) WriteError!void {
            if (len > self.options.max_collection_length or len > std.math.maxInt(i32)) return error.SizeLimitExceeded;
            try self.scalar(.int, @intCast(len));
        }

        fn string(self: *Self, value: []const u8) WriteError!void {
            if (!format.rawStrings()) {
                if (!utf8.validate(value)) return error.InvalidUtf8;
                if (encoding == .java and !utf8.isModifiedPlain(value)) return self.modifiedString(value);
            }

            if (value.len > self.options.max_string_bytes) return error.SizeLimitExceeded;

            if (varints) {
                const len = std.math.cast(u32, value.len) orelse return error.SizeLimitExceeded;
                try self.varUInt(u32, len);
            } else {
                const len = std.math.cast(u16, value.len) orelse return error.SizeLimitExceeded;
                try self.fixed(u16, len);
            }

            try self.bytes(value);
        }

        fn modifiedString(self: *Self, value: []const u8) WriteError!void {
            const len = utf8.modifiedLen(value);
            if (len > self.options.max_string_bytes or len > std.math.maxInt(u16)) return error.SizeLimitExceeded;

            try self.fixed(u16, @intCast(len));

            var buffer: [6]u8 = undefined;
            var iterator = std.unicode.Utf8View.initUnchecked(value).iterator();
            while (iterator.nextCodepoint()) |codepoint| try self.bytes(utf8.encodeModified(codepoint, &buffer));
        }

        /// Containers and owned values go out of line to keep each nesting level's frame small.
        fn payload(self: *Self, tag: *const Tag, depth: usize) WriteError!void {
            switch (tag.*) {
                .end => return error.InvalidTag,
                inline .byte, .short, .int, .long, .float, .double => |value, tag_type| try self.scalar(tag_type, value),
                .byte_array, .string, .int_array, .long_array => try self.owned(tag),
                .list => |*value| try self.list(value, depth),
                .compound => |*value| try self.compound(value, depth),
            }
        }

        noinline fn owned(self: *Self, tag: *const Tag) WriteError!void {
            switch (tag.*) {
                .byte_array => |value| {
                    if (value.len > self.options.max_byte_array_length) return error.SizeLimitExceeded;
                    try self.length(value.len);
                    try self.bytes(value);
                },
                .string => |value| try self.string(value),
                .int_array => |value| try self.array(i32, value),
                .long_array => |value| try self.array(i64, value),
                else => unreachable,
            }
        }

        /// Turns runs of one-byte values into single 16-byte writes.
        fn zigzags(self: *Self, comptime T: type, values: []const T) WriteError!void {
            const lanes = 16;
            const Unsigned = @Int(.unsigned, @bitSizeOf(T));
            var rest = values;

            while (rest.len != 0) {
                if (rest.len >= lanes) {
                    const chunk: @Vector(lanes, T) = rest[0..lanes].*;
                    const unsigned: @Vector(lanes, Unsigned) = @bitCast(chunk);
                    const signs: @Vector(lanes, Unsigned) = @bitCast(chunk >> @splat(@bitSizeOf(T) - 1));
                    const encoded = (unsigned << @splat(1)) ^ signs;

                    if (@reduce(.And, encoded < @as(@Vector(lanes, Unsigned), @splat(0x80)))) {
                        const narrow: [lanes]u8 = @as(@Vector(lanes, u8), @truncate(encoded));
                        try self.bytes(&narrow);
                        rest = rest[lanes..];
                        continue;
                    }
                }

                // A miss means wider values, so take the next batch one by one before checking again.
                const batch = rest[0..@min(rest.len, lanes)];
                rest = rest[batch.len..];

                // With room for the widest encoding of the batch, write it in place with one check.
                const max_len = (@bitSizeOf(T) + 6) / 7;
                const room = self.spare();
                if (room.len >= batch.len * max_len) {
                    var len: usize = 0;
                    for (batch) |value| {
                        var unsigned = (@as(Unsigned, @bitCast(value)) << 1) ^ @as(Unsigned, @bitCast(value >> (@bitSizeOf(T) - 1)));
                        while (unsigned >= 0x80) : (unsigned >>= 7) {
                            room[len] = @truncate(unsigned | 0x80);
                            len += 1;
                        }
                        room[len] = @truncate(unsigned);
                        len += 1;
                    }

                    self.writer.end += len;
                    self.written += len;
                    continue;
                }

                for (batch) |value| try self.scalar(if (T == i32) .int else .long, value);
            }
        }

        fn array(self: *Self, comptime T: type, values: []const T) WriteError!void {
            try self.length(values.len);

            if (varints) {
                try self.zigzags(T, values);
            } else if (endian == native_endian) {
                try self.bytes(std.mem.sliceAsBytes(values));
            } else if (self.direct(values.len * @sizeOf(T))) |dest| {
                @memcpy(dest, std.mem.sliceAsBytes(values));
                endian_swap.swapAll(T, @ptrCast(dest));
            } else {
                var buffer: [256 / @sizeOf(T)]T = undefined;
                var rest = values;

                while (rest.len != 0) {
                    const chunk = buffer[0..@min(rest.len, buffer.len)];
                    @memcpy(chunk, rest[0..chunk.len]);
                    endian_swap.swapAll(T, chunk);

                    try self.bytes(std.mem.sliceAsBytes(chunk));
                    rest = rest[chunk.len..];
                }
            }
        }

        noinline fn list(self: *Self, value: *const List, depth: usize) WriteError!void {
            const element_type = value.element_type;

            if (element_type == .end and value.items.len != 0) return error.InvalidListType;
            if (value.items.len != 0 and depth + 1 >= self.options.max_depth) return error.DepthLimitExceeded;

            try self.byte(@backingInt(element_type));
            try self.length(value.items.len);

            switch (element_type) {
                inline .byte, .short, .int, .long, .float, .double => |scalar_type| try self.scalars(scalar_type, value.items),
                else => for (value.items) |*item| {
                    if (item.tagType() != element_type) return error.TypeMismatch;
                    try self.payload(item, depth + 1);
                },
            }
        }

        /// Out of line, its batch buffer would otherwise sit in every nested list's frame.
        noinline fn scalars(self: *Self, comptime scalar_type: TagType, items: []const Tag) WriteError!void {
            const T = Payload(scalar_type);

            if (varints and (T == i32 or T == i64)) {
                for (items) |item| {
                    if (item.tagType() != scalar_type) return error.TypeMismatch;
                    try self.scalar(scalar_type, @field(item, @tagName(scalar_type)));
                }

                return;
            }

            var buffer: [256]u8 = undefined;
            var rest = items;

            while (rest.len != 0) {
                const chunk = rest[0..@min(rest.len, buffer.len / @sizeOf(T))];
                for (chunk, 0..) |item, index| {
                    if (item.tagType() != scalar_type) return error.TypeMismatch;

                    const bits: Bits(scalar_type) = @bitCast(@field(item, @tagName(scalar_type)));
                    std.mem.writeInt(Bits(scalar_type), buffer[index * @sizeOf(T) ..][0..@sizeOf(T)], bits, endian);
                }

                try self.bytes(buffer[0 .. chunk.len * @sizeOf(T)]);
                rest = rest[chunk.len..];
            }
        }

        noinline fn compound(self: *Self, value: *const Compound, depth: usize) WriteError!void {
            const entries = value.entries;

            if (entries.len > self.options.max_compound_entries or entries.len > self.options.max_collection_length) {
                return error.SizeLimitExceeded;
            }

            if (entries.len != 0 and depth + 1 >= self.options.max_depth) return error.DepthLimitExceeded;

            // Bounds the duplicate-name index by the same budget decoding uses.
            const index_budget = std.math.mul(usize, entries.len, @sizeOf(Entry) * 2) catch return error.SizeLimitExceeded;
            if (index_budget > self.options.max_total_decoded_bytes) return error.SizeLimitExceeded;

            try self.names.check(self.allocator, entries);

            for (entries) |*entry| {
                const tag_type = entry.value.tagType();
                if (tag_type == .end) return error.InvalidTag;

                try self.byte(@backingInt(tag_type));
                try self.string(entry.name);
                try self.payload(&entry.value, depth + 1);
            }

            try self.byte(@backingInt(TagType.end));
        }
    };
}
