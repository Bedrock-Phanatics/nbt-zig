const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const BoundedWriter = @import("internal/BoundedWriter.zig");
const Compression = @import("options.zig").Compression;

pub const Error = error{
    MalformedCompressedData,
    SizeLimitExceeded,
    TrailingData,
};

const gzip_header = flate.Container.gzip.header();

/// Deflate never expands data more than this, so it bounds trusted size hints.
const max_ratio = 1032;

const CompressWorkspace = struct {
    history: [flate.max_window_len]u8,
    compressor: flate.Compress,
};

/// Kept out of line so the uncompressed path stays lean.
pub noinline fn compress(allocator: Allocator, input: []const u8, kind: Compression, max_output: usize) (Error || Allocator.Error)![]u8 {
    std.debug.assert(kind != .none);
    if (max_output < 9) return error.SizeLimitExceeded;

    var output = try BoundedWriter.init(allocator, max_output, input.len / 2 + 64);
    defer output.deinit();

    const workspace = try allocator.create(CompressWorkspace);
    defer allocator.destroy(workspace);

    deflate(&output.writer, workspace, input, kind) catch return output.err();

    return output.toOwnedSlice();
}

fn deflate(output: *std.Io.Writer, workspace: *CompressWorkspace, input: []const u8, kind: Compression) std.Io.Writer.Error!void {
    // Gzip is framed here so the checksum can use the faster crc32 below.
    if (kind == .gzip) try output.writeAll(gzip_header);

    workspace.compressor = try .init(output, &workspace.history, if (kind == .gzip) .raw else .zlib, .fastest);
    try workspace.compressor.writer.writeAll(input);
    try workspace.compressor.finish();

    if (kind == .gzip) {
        try output.writeInt(u32, crc32(input), .little);
        try output.writeInt(u32, @truncate(input.len), .little);
    }
}

/// Returns the decompressed bytes in a writer the caller must deinit.
pub noinline fn decompress(
    allocator: Allocator,
    input: []const u8,
    kind: Compression,
    max_output: usize,
    reject_trailing_bytes: bool,
) (Error || Allocator.Error)!BoundedWriter {
    std.debug.assert(kind != .none);
    validateHeader(input, kind) catch return error.MalformedCompressedData;

    var output = try BoundedWriter.init(allocator, max_output, sizeHint(input, kind, max_output));
    errdefer output.deinit();

    var source: std.Io.Reader = .fixed(input);
    // An empty buffer makes the inflater use the output as its history window.
    var inflater: flate.Decompress = .init(&source, if (kind == .gzip) .gzip else .zlib, &.{});

    _ = inflater.reader.streamRemaining(&output.writer) catch |err| return switch (err) {
        error.ReadFailed => error.MalformedCompressedData,
        error.WriteFailed => output.err(),
    };

    const plain = try output.written();

    // The standard library parses but does not verify these footers.
    const valid = switch (inflater.container_metadata) {
        .gzip => |footer| footer.crc == crc32(plain) and footer.count == @as(u32, @truncate(plain.len)),
        .zlib => |footer| footer.adler == std.hash.Adler32.hash(plain),
        .raw => unreachable,
    };

    if (!valid) return error.MalformedCompressedData;
    if (reject_trailing_bytes and source.bufferedLen() != 0) return error.TrailingData;

    return output;
}

fn sizeHint(input: []const u8, kind: Compression, max_output: usize) usize {
    const guess = if (kind == .gzip and input.len >= 18)
        std.mem.readInt(u32, input[input.len - 4 ..][0..4], .little)
    else
        input.len *| 4;

    return @min(guess, max_output, input.len *| max_ratio);
}

fn validateHeader(input: []const u8, kind: Compression) !void {
    var reader: std.Io.Reader = .fixed(input);

    if (kind == .zlib) {
        const header = try reader.takeArray(2);
        if (std.mem.readInt(u16, header, .big) % 31 != 0 or header[1] & 0x20 != 0) return error.MalformedCompressedData;
        return;
    }

    const header = try reader.takeArray(10);
    const flags = header[3];
    if (flags & 0xe0 != 0) return error.MalformedCompressedData;

    if (flags & 4 != 0) try reader.discardAll(try reader.takeInt(u16, .little));
    if (flags & 8 != 0) _ = try reader.discardDelimiterInclusive(0);
    if (flags & 16 != 0) _ = try reader.discardDelimiterInclusive(0);

    if (flags & 2 != 0) {
        const checksum: u16 = @truncate(crc32(input[0..reader.seek]));
        if (try reader.takeInt(u16, .little) != checksum) return error.MalformedCompressedData;
    }
}

const crc_tables = blk: {
    @setEvalBranchQuota(100_000);

    var tables: [8][256]u32 = undefined;
    for (&tables[0], 0..) |*entry, index| {
        var crc: u32 = index;
        for (0..8) |_| crc = if (crc & 1 != 0) (crc >> 1) ^ 0xedb88320 else crc >> 1;
        entry.* = crc;
    }

    for (1..8) |table| {
        for (0..256) |index| {
            const previous = tables[table - 1][index];
            tables[table][index] = (previous >> 8) ^ tables[0][previous & 0xff];
        }
    }

    break :blk tables;
};

/// CRC-32/ISO-HDLC with slicing-by-8, several times faster than `std.hash.Crc32`.
pub fn crc32(bytes: []const u8) u32 {
    const t = &crc_tables;
    var crc: u32 = 0xffffffff;
    var rest = bytes;

    while (rest.len >= 8) : (rest = rest[8..]) {
        const low = std.mem.readInt(u32, rest[0..4], .little) ^ crc;
        const high = std.mem.readInt(u32, rest[4..8], .little);

        crc = t[7][low & 0xff] ^ t[6][(low >> 8) & 0xff] ^ t[5][(low >> 16) & 0xff] ^ t[4][low >> 24] ^
            t[3][high & 0xff] ^ t[2][(high >> 8) & 0xff] ^ t[1][(high >> 16) & 0xff] ^ t[0][high >> 24];
    }

    for (rest) |byte| crc = t[0][(crc ^ byte) & 0xff] ^ (crc >> 8);

    return ~crc;
}
