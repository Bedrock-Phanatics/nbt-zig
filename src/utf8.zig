//! UTF-8 checks plus Java's modified UTF-8, where NUL is two bytes and
//! supplementary characters are surrogate pairs.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Short strings skip std's per-byte loop when they are plain ASCII, which most NBT names are.
/// Longer ones already get std's vectorized ASCII scan.
pub fn validate(bytes: []const u8) bool {
    if (bytes.len >= std.simd.suggestVectorLength(u8) orelse 16) return std.unicode.utf8ValidateSlice(bytes);

    var high: u8 = 0;
    for (bytes) |byte| high |= byte;

    return high < 0x80 or std.unicode.utf8ValidateSlice(bytes);
}

/// True when valid UTF-8 `bytes` are encoded the same way in modified UTF-8,
/// meaning there is no NUL and no four-byte sequence.
pub fn isModifiedPlain(bytes: []const u8) bool {
    const lanes = 16;
    const Chunk = @Vector(lanes, u8);

    // Wrapping 0 to 0xff lets one compare catch both NUL and 0xf0 and above.
    var index: usize = 0;
    while (index + lanes <= bytes.len) : (index += lanes) {
        const chunk: Chunk = bytes[index..][0..lanes].*;
        if (@reduce(.Or, chunk -% @as(Chunk, @splat(1)) >= @as(Chunk, @splat(0xef)))) return false;
    }

    for (bytes[index..]) |byte| {
        if (byte -% 1 >= 0xef) return false;
    }

    return true;
}

/// Converts modified UTF-8 to standard UTF-8. The result is never longer than the input.
pub fn decodeModified(allocator: Allocator, encoded: []const u8) (error{InvalidModifiedUtf8} || Allocator.Error)![]u8 {
    const result = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(result);

    var len: usize = 0;
    var index: usize = 0;
    var pending_high: ?u16 = null;

    while (index < encoded.len) {
        const unit = try nextUnit(encoded, &index);

        if (pending_high) |high| {
            if (unit < 0xdc00 or unit > 0xdfff) return error.InvalidModifiedUtf8;

            const scalar: u21 = @intCast(0x10000 + ((@as(u32, high) - 0xd800) << 10) + (unit - 0xdc00));
            len += std.unicode.utf8Encode(scalar, result[len..][0..4]) catch unreachable;
            pending_high = null;
        } else if (unit >= 0xd800 and unit <= 0xdbff) {
            pending_high = unit;
        } else {
            if (unit >= 0xdc00 and unit <= 0xdfff) return error.InvalidModifiedUtf8;

            len += std.unicode.utf8Encode(unit, result[len..]) catch unreachable;
        }
    }

    if (pending_high != null) return error.InvalidModifiedUtf8;
    if (len == result.len) return result;

    return allocator.realloc(result, len);
}

fn nextUnit(encoded: []const u8, index: *usize) error{InvalidModifiedUtf8}!u16 {
    const rest = encoded[index.*..];
    const first = rest[0];

    if (first <= 0x7f) {
        if (first == 0) return error.InvalidModifiedUtf8;
        index.* += 1;
        return first;
    }

    if (first & 0xe0 == 0xc0) {
        if (rest.len < 2 or rest[1] & 0xc0 != 0x80) return error.InvalidModifiedUtf8;

        const unit = (@as(u16, first & 0x1f) << 6) | (rest[1] & 0x3f);
        if (unit != 0 and unit < 0x80) return error.InvalidModifiedUtf8;

        index.* += 2;
        return unit;
    }

    if (first & 0xf0 == 0xe0) {
        if (rest.len < 3 or rest[1] & 0xc0 != 0x80 or rest[2] & 0xc0 != 0x80) return error.InvalidModifiedUtf8;

        const unit = (@as(u16, first & 0x0f) << 12) | (@as(u16, rest[1] & 0x3f) << 6) | (rest[2] & 0x3f);
        if (unit < 0x800) return error.InvalidModifiedUtf8;

        index.* += 3;
        return unit;
    }

    return error.InvalidModifiedUtf8;
}

/// Length of `utf8` once encoded. NUL grows by one byte and every four-byte
/// sequence by two. Exact for valid UTF-8 and harmless on anything else.
pub fn modifiedLen(utf8: []const u8) usize {
    var len = utf8.len;
    for (utf8) |byte| len += @as(usize, @intFromBool(byte == 0)) + 2 * @as(usize, @intFromBool(byte >= 0xf0));

    return len;
}

pub fn encodeModified(codepoint: u21, out: *[6]u8) []const u8 {
    if (codepoint <= 0xffff) return out[0..encodeUnit(@intCast(codepoint), out[0..3])];

    const adjusted = codepoint - 0x10000;
    _ = encodeUnit(@intCast(0xd800 + (adjusted >> 10)), out[0..3]);
    _ = encodeUnit(@intCast(0xdc00 + (adjusted & 0x3ff)), out[3..6]);

    return out;
}

fn encodeUnit(unit: u16, out: *[3]u8) usize {
    if (unit != 0 and unit <= 0x7f) {
        out[0] = @intCast(unit);
        return 1;
    }

    if (unit <= 0x7ff) {
        out[0] = @intCast(0xc0 | (unit >> 6));
        out[1] = @intCast(0x80 | (unit & 0x3f));
        return 2;
    }

    out[0] = @intCast(0xe0 | (unit >> 12));
    out[1] = @intCast(0x80 | ((unit >> 6) & 0x3f));
    out[2] = @intCast(0x80 | (unit & 0x3f));
    return 3;
}
