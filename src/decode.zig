const std = @import("std");
const Allocator = std.mem.Allocator;
const native_endian = @import("builtin").cpu.arch.endian();

const unique_names = @import("internal/unique_names.zig");
const utf8 = @import("utf8.zig");
const options_mod = @import("options.zig");
const Encoding = options_mod.Encoding;
const Options = options_mod.Options;
const types = @import("types.zig");
const Bits = types.Bits;
const Document = types.Document;
const Entry = types.Entry;
const Payload = types.Payload;
const Tag = types.Tag;
const TagType = types.TagType;

pub const Error = types.CodecError || Allocator.Error;

/// Expects validated options.
pub fn decode(allocator: Allocator, data: []const u8, options: Options) Error!Document {
    return switch (options.encoding) {
        inline else => |encoding| Decoder(encoding).document(allocator, data, options),
    };
}

fn Decoder(comptime encoding: Encoding) type {
    return struct {
        const Self = @This();

        const endian: std.builtin.Endian = if (encoding == .java) .big else .little;
        const varints = encoding == .bedrock_network;

        allocator: Allocator,
        data: []const u8,
        offset: usize = 0,
        allocated: usize = 0,
        options: Options,
        /// Shared by nested compounds, each copies its own run out when done.
        entries: std.ArrayList(Entry) = .empty,
        names: unique_names.Checker = .{},

        fn document(allocator: Allocator, data: []const u8, options: Options) Error!Document {
            var self: Self = .{
                .allocator = allocator,
                .data = data,
                .options = options,
            };
            defer {
                self.entries.deinit(allocator);
                self.names.deinit(allocator);
            }

            const root_type = try self.tagType();
            if (root_type == .end) return error.InvalidRoot;

            const name = try self.string();
            errdefer allocator.free(name);

            var root = try self.payload(root_type, 0);
            errdefer root.deinit(allocator);

            if (options.reject_trailing_bytes and self.offset != data.len) return error.TrailingData;

            return .{ .name = name, .root = root };
        }

        fn reserve(self: *Self, amount: usize) Error!void {
            self.allocated = std.math.add(usize, self.allocated, amount) catch return error.SizeLimitExceeded;
            if (self.allocated > self.options.max_total_decoded_bytes) return error.SizeLimitExceeded;
        }

        fn remaining(self: *const Self) usize {
            return self.data.len - self.offset;
        }

        fn take(self: *Self, len: usize) Error![]const u8 {
            if (len > self.remaining()) return error.UnexpectedEndOfInput;

            defer self.offset += len;
            return self.data[self.offset..][0..len];
        }

        fn byte(self: *Self) Error!u8 {
            if (self.offset >= self.data.len) return error.UnexpectedEndOfInput;

            defer self.offset += 1;
            return self.data[self.offset];
        }

        fn tagType(self: *Self) Error!TagType {
            return TagType.fromByte(try self.byte());
        }

        fn fixed(self: *Self, comptime T: type) Error!T {
            return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], endian);
        }

        fn varUInt(self: *Self, comptime T: type) Error!T {
            const max_len = (@bitSizeOf(T) + 6) / 7;
            const last_bits = @bitSizeOf(T) - 7 * (max_len - 1);
            var value: T = 0;

            inline for (0..max_len) |index| {
                const current = try self.byte();

                if (index == max_len - 1) {
                    // Also rejects a continuation bit on the final byte.
                    if (current >> last_bits != 0) return error.VarIntOverflow;
                    return value | @as(T, current) << (7 * index);
                }

                value |= @as(T, current & 0x7f) << (7 * index);
                if (current & 0x80 == 0) return value;
            }
        }

        fn zigzag(self: *Self, comptime T: type) Error!T {
            const Unsigned = @Int(.unsigned, @bitSizeOf(T));
            const value = try self.varUInt(Unsigned);

            return @bitCast((value >> 1) ^ (0 -% (value & 1)));
        }

        fn scalar(self: *Self, comptime tag_type: TagType) Error!Payload(tag_type) {
            const T = Payload(tag_type);
            if (varints and (T == i32 or T == i64)) return self.zigzag(T);

            return @bitCast(try self.fixed(Bits(tag_type)));
        }

        fn length(self: *Self) Error!usize {
            const value = try self.scalar(.int);
            if (value < 0) return error.InvalidLength;

            const len: usize = @intCast(value);
            if (len > self.options.max_collection_length) return error.SizeLimitExceeded;

            return len;
        }

        fn string(self: *Self) Error![]u8 {
            const len: usize = if (varints)
                std.math.cast(usize, try self.varUInt(u32)) orelse return error.SizeLimitExceeded
            else
                try self.fixed(u16);

            if (len > self.options.max_string_bytes) return error.SizeLimitExceeded;

            const encoded = try self.take(len);
            try self.reserve(len);

            if (encoding == .java) {
                if (!utf8.isModifiedPlain(encoded) or !utf8.validate(encoded)) {
                    return utf8.decodeModified(self.allocator, encoded);
                }
            } else if (!utf8.validate(encoded)) {
                return error.InvalidUtf8;
            }

            return self.allocator.dupe(u8, encoded);
        }

        fn payload(self: *Self, tag_type: TagType, depth: usize) Error!Tag {
            return switch (tag_type) {
                .end => error.InvalidTag,
                .byte => .{ .byte = try self.scalar(.byte) },
                .short => .{ .short = try self.scalar(.short) },
                .int => .{ .int = try self.scalar(.int) },
                .long => .{ .long = try self.scalar(.long) },
                .float => .{ .float = try self.scalar(.float) },
                .double => .{ .double = try self.scalar(.double) },
                .byte_array => .{ .byte_array = try self.array(u8) },
                .string => .{ .string = try self.string() },
                .list => try self.list(depth + 1),
                .compound => try self.compound(depth + 1),
                .int_array => .{ .int_array = try self.array(i32) },
                .long_array => .{ .long_array = try self.array(i64) },
            };
        }

        fn array(self: *Self, comptime T: type) Error![]T {
            const len = try self.length();
            const size = std.math.mul(usize, len, @sizeOf(T)) catch return error.SizeLimitExceeded;

            try self.reserve(size);

            const varint_array = varints and T != u8;
            if ((if (varint_array) len else size) > self.remaining()) return error.UnexpectedEndOfInput;

            const result = try self.allocator.alloc(T, len);
            errdefer self.allocator.free(result);

            if (varint_array) {
                for (result) |*item| item.* = try self.zigzag(T);
            } else {
                const input = try self.take(size);

                if (T == u8 or endian == native_endian) {
                    @memcpy(std.mem.sliceAsBytes(result), input);
                } else {
                    for (result, 0..) |*item, index| {
                        item.* = std.mem.readInt(T, input[index * @sizeOf(T) ..][0..@sizeOf(T)], endian);
                    }
                }
            }

            return result;
        }

        /// Smallest encoded payload, used to reject impossible lengths before allocating.
        fn minSize(tag_type: TagType) usize {
            return switch (tag_type) {
                .end => 0,
                .byte, .compound => 1,
                .short => 2,
                .int, .float => if (varints and tag_type == .int) 1 else 4,
                .long, .double => if (varints and tag_type == .long) 1 else 8,
                .byte_array, .int_array, .long_array => if (varints) 1 else 4,
                .string => if (varints) 1 else 2,
                .list => if (varints) 2 else 5,
            };
        }

        fn list(self: *Self, depth: usize) Error!Tag {
            const element_type = try self.tagType();
            const len = try self.length();

            if (element_type == .end and len != 0) return error.InvalidListType;
            if (len != 0 and depth >= self.options.max_depth) return error.DepthLimitExceeded;

            try self.reserve(std.math.mul(usize, len, @sizeOf(Tag)) catch return error.SizeLimitExceeded);

            const min_bytes = std.math.mul(usize, len, minSize(element_type)) catch return error.SizeLimitExceeded;
            if (min_bytes > self.remaining()) return error.UnexpectedEndOfInput;

            const items = try self.allocator.alloc(Tag, len);
            var initialized: usize = 0;

            errdefer {
                for (items[0..initialized]) |*item| item.deinit(self.allocator);
                self.allocator.free(items);
            }

            switch (element_type) {
                inline .byte, .short, .int, .long, .float, .double => |scalar_type| {
                    const T = Payload(scalar_type);

                    if (varints and (T == i32 or T == i64)) {
                        for (items) |*item| item.* = @unionInit(Tag, @tagName(scalar_type), try self.zigzag(T));
                    } else {
                        // The size check above already covered every fixed-width element.
                        const input = self.data[self.offset..][0..min_bytes];
                        self.offset += min_bytes;

                        for (items, 0..) |*item, index| {
                            const bits = std.mem.readInt(Bits(scalar_type), input[index * @sizeOf(T) ..][0..@sizeOf(T)], endian);
                            item.* = @unionInit(Tag, @tagName(scalar_type), @bitCast(bits));
                        }
                    }
                },

                else => while (initialized < len) : (initialized += 1) {
                    items[initialized] = try self.payload(element_type, depth);
                },
            }

            return .{ .list = .{ .element_type = element_type, .items = items } };
        }

        fn compound(self: *Self, depth: usize) Error!Tag {
            const start = self.entries.items.len;

            errdefer {
                for (self.entries.items[start..]) |*entry| entry.deinit(self.allocator);
                self.entries.shrinkRetainingCapacity(start);
            }

            while (true) {
                const tag_type = try self.tagType();
                if (tag_type == .end) break;
                if (depth >= self.options.max_depth) return error.DepthLimitExceeded;

                const count = self.entries.items.len - start;
                if (count >= self.options.max_compound_entries or count >= self.options.max_collection_length) {
                    return error.SizeLimitExceeded;
                }

                try self.reserve(@sizeOf(Entry) * 4);

                const name = try self.string();
                errdefer self.allocator.free(name);

                var value = try self.payload(tag_type, depth);
                errdefer value.deinit(self.allocator);

                try self.entries.append(self.allocator, .{ .name = name, .value = value });
            }

            const fields = self.entries.items[start..];
            try self.names.check(self.allocator, fields);

            const entries = try self.allocator.dupe(Entry, fields);
            self.entries.shrinkRetainingCapacity(start);

            return .{ .compound = .{ .entries = entries } };
        }
    };
}
