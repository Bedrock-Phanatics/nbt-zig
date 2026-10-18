//! Validates NBT in place and reports how many bytes it spans, without building a tree
//! or touching an allocator.
//!
//! The scanner applies the same checks and limits as the tree decoder with two
//! exceptions, because both need memory proportional to the input: duplicate
//! compound names are not detected and `max_total_decoded_bytes` is not charged.
//! `max_input_bytes` caps how far a scan may read, so a document that would run past
//! it fails with `error.SizeLimitExceeded` even when more input follows.

const std = @import("std");

const options_mod = @import("options.zig");
const Format = options_mod.Format;
const Options = options_mod.Options;
const types = @import("types.zig");
const Tag = types.Tag;
const TagType = types.TagType;
const utf8 = @import("utf8.zig");

pub const Error = types.CodecError;

/// Scans the named document at the start of `input`.
pub fn scanDocument(input: []const u8, options: Options) Error!usize {
    return run(input, options, .document);
}

/// Like `scanDocument`, but a lone TAG_End, which Bedrock sends for absent NBT, is
/// accepted and spans one byte.
pub fn scanOptionalDocument(input: []const u8, options: Options) Error!usize {
    return run(input, options, .optional_document);
}

/// Scans a headerless payload whose type the caller already knows.
pub fn scanPayload(input: []const u8, tag_type: TagType, options: Options) Error!usize {
    return run(input, options, .{ .payload = tag_type });
}

const Start = union(enum) {
    document,
    optional_document,
    payload: TagType,
};

fn run(input: []const u8, options: Options, start: Start) Error!usize {
    try options.validate();
    if (options.compression != .none) return error.InvalidOptions;

    const window = input[0..@min(input.len, options.max_input_bytes)];
    const len = switch (options.format()) {
        inline else => |format| Scanner(format).scan(window, options, start),
    } catch |err| {
        if (err == error.UnexpectedEndOfInput and window.len < input.len) return error.SizeLimitExceeded;
        return err;
    };

    if (options.reject_trailing_bytes and len != input.len) return error.TrailingData;
    return len;
}

fn Scanner(comptime format: Format) type {
    return struct {
        const Self = @This();

        const encoding = format.encoding();

        const varints = encoding == .bedrock_network;

        data: []const u8,
        offset: usize = 0,
        options: Options,

        fn scan(data: []const u8, options: Options, start: Start) Error!usize {
            var self: Self = .{ .data = data, .options = options };

            const root_type = switch (start) {
                .payload => |tag_type| tag_type,
                .document, .optional_document => blk: {
                    const tag_type = try self.tagType();
                    if (tag_type == .end) {
                        if (start == .optional_document) return 1;
                        return error.InvalidRoot;
                    }

                    try self.string();
                    break :blk tag_type;
                },
            };

            try self.walk(root_type);
            return self.offset;
        }

        fn skip(self: *Self, len: usize) Error!void {
            if (len > self.data.len - self.offset) return error.UnexpectedEndOfInput;
            self.offset += len;
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
            const start = self.offset;
            try self.skip(@sizeOf(T));
            return std.mem.readInt(T, self.data[start..][0..@sizeOf(T)], if (encoding == .java) .big else .little);
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
                    if (current == 0 and self.options.reject_noncanonical_varints) return error.NonCanonicalVarInt;
                    return value | @as(T, current) << (7 * index);
                }

                value |= @as(T, current & 0x7f) << (7 * index);
                if (current & 0x80 == 0) {
                    if (index != 0 and current == 0 and self.options.reject_noncanonical_varints) return error.NonCanonicalVarInt;
                    return value;
                }
            }
        }

        /// Skips ints or longs, the only scalars that may be varints.
        fn integers(self: *Self, comptime T: type, count: usize) Error!void {
            if (!varints) return self.skip(count * @sizeOf(T));
            if (count == 0) return;

            // Only where each varint ends matters, so this walks the bytes and checks the
            // final byte of every value, failing on the same byte the decoder would.
            const max_len = (@bitSizeOf(T) + 6) / 7;
            const last_bits = @bitSizeOf(T) - 7 * (max_len - 1);
            const lanes = 16;
            const Chunk = @Vector(lanes, u8);
            const data = self.data;
            var offset = self.offset;
            var remaining = count;

            var batch: usize = 0;

            while (remaining != 0) {
                // Small values are one byte each, and a run of those needs no checks at all.
                // A miss means wider values, so the next batch goes one by one before checking again.
                if (batch == 0) {
                    if (remaining >= lanes and data.len - offset >= lanes) {
                        const chunk: Chunk = data[offset..][0..lanes].*;
                        if (@reduce(.And, chunk < @as(Chunk, @splat(0x80)))) {
                            offset += lanes;
                            remaining -= lanes;
                            continue;
                        }
                    }

                    batch = lanes;
                }

                batch -= 1;
                var width: usize = 0;
                const last = while (true) {
                    if (offset >= data.len) return error.UnexpectedEndOfInput;
                    const current = data[offset];
                    offset += 1;
                    width += 1;

                    if (width == max_len) {
                        if (current >> last_bits != 0) return error.VarIntOverflow;
                        break current;
                    }
                    if (current & 0x80 == 0) break current;
                };

                if (width > 1 and last == 0 and self.options.reject_noncanonical_varints) return error.NonCanonicalVarInt;
                remaining -= 1;
            }

            self.offset = offset;
        }

        fn length(self: *Self) Error!usize {
            const value: i32 = if (varints) blk: {
                const raw = try self.varUInt(u32);
                break :blk @bitCast((raw >> 1) ^ (0 -% (raw & 1)));
            } else @bitCast(try self.fixed(u32));

            if (value < 0) return error.InvalidLength;

            const len: usize = @intCast(value);
            if (len > self.options.max_collection_length) return error.SizeLimitExceeded;

            return len;
        }

        fn string(self: *Self) Error!void {
            const len: usize = if (varints)
                std.math.cast(usize, try self.varUInt(u32)) orelse return error.SizeLimitExceeded
            else
                try self.fixed(u16);

            if (len > self.options.max_string_bytes) return error.SizeLimitExceeded;

            const start = self.offset;
            try self.skip(len);
            if (format.rawStrings()) return;

            const bytes = self.data[start..self.offset];
            if (encoding == .java) {
                if (utf8.isModifiedPlain(bytes) and utf8.validate(bytes)) return;
                if (!utf8.validateModified(bytes)) return error.InvalidModifiedUtf8;
            } else if (!utf8.validate(bytes)) {
                return error.InvalidUtf8;
            }
        }

        fn array(self: *Self, comptime T: type) Error!void {
            const len = try self.length();
            if (T == u8 and len > self.options.max_byte_array_length) return error.SizeLimitExceeded;

            const size = std.math.mul(usize, len, @sizeOf(T)) catch return error.SizeLimitExceeded;
            if (!varints or T == u8) return self.skip(size);

            if (len > self.data.len - self.offset) return error.UnexpectedEndOfInput;
            try self.integers(T, len);
        }

        /// Smallest encoded payload, used to reject impossible lengths up front.
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

        /// Walks one value with an explicit stack, so nesting costs no native stack.
        fn walk(self: *Self, root_type: TagType) Error!void {
            // Each open container is a list owing `counts` more `elements`, or a compound
            // marked by `.end` whose count is the entries seen so far. Split arrays keep this
            // under a page, so it costs no stack probe.
            var counts: [Options.max_supported_depth]u32 = undefined;
            var elements: [Options.max_supported_depth]TagType = undefined;
            // Past 2^32 entries a compound is far beyond any real input limit anyway.
            const entry_limit: u32 = @intCast(@min(self.options.max_compound_entries, self.options.max_collection_length, std.math.maxInt(u32)));
            var depth: usize = 0;
            var tag_type = root_type;

            while (true) {
                switch (tag_type) {
                    .end => return error.InvalidTag,
                    .byte => try self.skip(1),
                    .short => try self.skip(2),
                    .int => try self.integers(i32, 1),
                    .long => try self.integers(i64, 1),
                    .float => try self.skip(4),
                    .double => try self.skip(8),
                    .byte_array => try self.array(u8),
                    .int_array => try self.array(i32),
                    .long_array => try self.array(i64),
                    .string => try self.string(),

                    .list => {
                        const element = try self.tagType();
                        const len = try self.length();

                        if (element == .end and len != 0) return error.InvalidListType;
                        if (len != 0 and depth + 1 >= self.options.max_depth) return error.DepthLimitExceeded;

                        // Matches the decoder, which would allocate this many tags.
                        _ = std.math.mul(usize, len, @sizeOf(Tag)) catch return error.SizeLimitExceeded;

                        const min_bytes = std.math.mul(usize, len, minSize(element)) catch return error.SizeLimitExceeded;
                        if (min_bytes > self.data.len - self.offset) return error.UnexpectedEndOfInput;

                        if (len != 0) switch (element) {
                            .byte, .short, .float, .double => self.offset += min_bytes,
                            .int => try self.integers(i32, len),
                            .long => try self.integers(i64, len),
                            else => {
                                counts[depth] = @intCast(len);
                                elements[depth] = element;
                                depth += 1;
                            },
                        };
                    },

                    .compound => {
                        counts[depth] = 0;
                        elements[depth] = .end;
                        depth += 1;
                    },
                }

                tag_type = next: while (depth != 0) {
                    const count = &counts[depth - 1];
                    const element = elements[depth - 1];

                    if (element != .end) {
                        if (count.* == 0) {
                            depth -= 1;
                            continue;
                        }

                        count.* -= 1;
                        break :next element;
                    }

                    const child = try self.tagType();
                    if (child == .end) {
                        depth -= 1;
                        continue;
                    }

                    if (depth >= self.options.max_depth) return error.DepthLimitExceeded;
                    if (count.* >= entry_limit) return error.SizeLimitExceeded;

                    count.* += 1;
                    try self.string();
                    break :next child;
                } else return;
            }
        }
    };
}

test "the scanner never references an allocator" {
    const source = @embedFile("scan.zig");
    // Split so the needles do not match this test itself.
    for ([_][]const u8{ "Alloc" ++ "ator", "std." ++ "heap", ".alloc" ++ "(", "create" ++ "(" }) |needle| {
        try std.testing.expectEqual(null, std.mem.indexOf(u8, source, needle));
    }
}
