const std = @import("std");
const Allocator = std.mem.Allocator;
const native_endian = @import("builtin").cpu.arch.endian();

const BoundedWriter = @import("internal/BoundedWriter.zig");
const unique_names = @import("internal/unique_names.zig");
const utf8 = @import("utf8.zig");
const options_mod = @import("options.zig");
const Encoding = options_mod.Encoding;
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

/// Expects validated options.
pub fn encode(allocator: Allocator, document: Document, options: Options) Error![]u8 {
    const java = options.encoding == .java;
    const hint = 1 +| stringHint(document.name, java) +| sizeHint(document.root, options.max_depth, java);

    var output = try BoundedWriter.init(allocator, options.max_output_bytes, hint);
    defer output.deinit();

    write(allocator, &output.writer, document, options) catch |err| return switch (err) {
        error.WriteFailed => output.err(),
        else => |e| e,
    };

    return output.toOwnedSlice();
}

/// Expects validated options.
pub fn write(allocator: Allocator, writer: *std.Io.Writer, document: Document, options: Options) WriteError!void {
    switch (options.encoding) {
        inline else => |encoding| {
            var encoder: Encoder(encoding) = .{
                .allocator = allocator,
                .writer = writer,
                .options = options,
            };
            defer encoder.names.deinit(allocator);

            try encoder.document(document);
        },
    }
}

/// Close to the encoded size so serialize usually allocates once.
fn sizeHint(tag: Tag, depth: usize, java: bool) usize {
    if (depth == 0) return 0;

    return switch (tag) {
        .end => 0,
        .byte => 1,
        .short => 2,
        .int, .float => 4,
        .long, .double => 8,
        .string => |value| stringHint(value, java),
        .byte_array => |value| 4 +| value.len,
        .int_array => |value| 4 +| value.len *| 4,
        .long_array => |value| 4 +| value.len *| 8,

        .list => |value| {
            if (value.element_type.isScalar() and value.items.len != 0) {
                return 5 +| value.items.len *| sizeHint(value.items[0], depth - 1, java);
            }

            var size: usize = 5;
            for (value.items) |item| size +|= sizeHint(item, depth - 1, java);
            return size;
        },

        .compound => |value| {
            var size: usize = 1;
            for (value.entries) |entry| size +|= 1 +| stringHint(entry.name, java) +| sizeHint(entry.value, depth - 1, java);
            return size;
        },
    };
}

/// Java strings can grow when written as modified UTF-8.
fn stringHint(value: []const u8, java: bool) usize {
    return 2 +| if (java and !utf8.isModifiedPlain(value)) utf8.modifiedLen(value) else value.len;
}

fn Encoder(comptime encoding: Encoding) type {
    return struct {
        const Self = @This();

        const endian: std.builtin.Endian = if (encoding == .java) .big else .little;
        const varints = encoding == .bedrock_network;

        allocator: Allocator,
        writer: *std.Io.Writer,
        options: Options,
        written: usize = 0,
        names: unique_names.Checker = .{},

        fn document(self: *Self, value: Document) WriteError!void {
            const root_type = value.root.tagType();
            if (root_type == .end) return error.InvalidRoot;

            try self.byte(@backingInt(root_type));
            try self.string(value.name);
            try self.payload(value.root, 0);
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
            if (!utf8.validate(value)) return error.InvalidUtf8;
            if (encoding == .java and !utf8.isModifiedPlain(value)) return self.modifiedString(value);
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

        fn payload(self: *Self, tag: Tag, depth: usize) WriteError!void {
            switch (tag) {
                .end => return error.InvalidTag,
                inline .byte, .short, .int, .long, .float, .double => |value, tag_type| try self.scalar(tag_type, value),

                .byte_array => |value| {
                    try self.length(value.len);
                    try self.bytes(value);
                },

                .string => |value| try self.string(value),
                .list => |value| try self.list(value, depth),
                .compound => |value| try self.compound(value, depth),
                .int_array => |value| try self.array(i32, value),
                .long_array => |value| try self.array(i64, value),
            }
        }

        fn array(self: *Self, comptime T: type, values: []const T) WriteError!void {
            try self.length(values.len);

            if (varints) {
                for (values) |value| try self.scalar(if (T == i32) .int else .long, value);
            } else if (endian == native_endian) {
                try self.bytes(std.mem.sliceAsBytes(values));
            } else {
                var buffer: [256]u8 = undefined;
                var rest = values;

                while (rest.len != 0) {
                    const chunk = rest[0..@min(rest.len, buffer.len / @sizeOf(T))];
                    for (chunk, 0..) |value, index| {
                        std.mem.writeInt(T, buffer[index * @sizeOf(T) ..][0..@sizeOf(T)], value, endian);
                    }

                    try self.bytes(buffer[0 .. chunk.len * @sizeOf(T)]);
                    rest = rest[chunk.len..];
                }
            }
        }

        fn list(self: *Self, value: List, depth: usize) WriteError!void {
            const element_type = value.element_type;

            if (element_type == .end and value.items.len != 0) return error.InvalidListType;
            if (value.items.len != 0 and depth + 1 >= self.options.max_depth) return error.DepthLimitExceeded;

            try self.byte(@backingInt(element_type));
            try self.length(value.items.len);

            switch (element_type) {
                inline .byte, .short, .int, .long, .float, .double => |scalar_type| {
                    const T = Payload(scalar_type);

                    if (varints and (T == i32 or T == i64)) {
                        for (value.items) |item| {
                            if (item.tagType() != scalar_type) return error.TypeMismatch;
                            try self.scalar(scalar_type, @field(item, @tagName(scalar_type)));
                        }

                        return;
                    }

                    var buffer: [256]u8 = undefined;
                    var rest = value.items;

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
                },

                else => for (value.items) |item| {
                    if (item.tagType() != element_type) return error.TypeMismatch;
                    try self.payload(item, depth + 1);
                },
            }
        }

        fn compound(self: *Self, value: Compound, depth: usize) WriteError!void {
            const entries = value.entries;

            if (entries.len > self.options.max_compound_entries or entries.len > self.options.max_collection_length) {
                return error.SizeLimitExceeded;
            }

            if (entries.len != 0 and depth + 1 >= self.options.max_depth) return error.DepthLimitExceeded;

            // Bounds the duplicate-name index by the same budget decoding uses.
            const index_budget = std.math.mul(usize, entries.len, @sizeOf(Entry) * 2) catch return error.SizeLimitExceeded;
            if (index_budget > self.options.max_total_decoded_bytes) return error.SizeLimitExceeded;

            try self.names.check(self.allocator, entries);

            for (entries) |entry| {
                const tag_type = entry.value.tagType();
                if (tag_type == .end) return error.InvalidTag;

                try self.byte(@backingInt(tag_type));
                try self.string(entry.name);
                try self.payload(entry.value, depth + 1);
            }

            try self.byte(@backingInt(TagType.end));
        }
    };
}
