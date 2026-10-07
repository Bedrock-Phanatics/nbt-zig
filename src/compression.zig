const std = @import("std");

const Compression = @import("options.zig").Compression;
const bounded_buffer = @import("internal/bounded_buffer.zig");
const BoundedWriter = @import("internal/bounded_writer.zig").BoundedWriter;

pub const Error = error{
    MalformedCompressedData,
    SizeLimitExceeded,
    TrailingData,
};

const CompressWorkspace = struct {
    history: [std.compress.flate.max_window_len]u8,
    compressor: std.compress.flate.Compress,
};

const DecompressWorkspace = struct {
    history: [std.compress.flate.max_window_len]u8,
    inflater: std.compress.flate.Decompress,
};

fn outputFailure(output: *const BoundedWriter) (Error || std.mem.Allocator.Error) {
    return switch (output.failure) {
        .limit => error.SizeLimitExceeded,
        .out_of_memory, .none => error.OutOfMemory,
    };
}

pub fn compress(
    allocator: std.mem.Allocator,
    input: []const u8,
    kind: Compression,
    max_output: usize,
) (Error || std.mem.Allocator.Error)![]u8 {
    if (kind == .none) {
        if (input.len > max_output) return error.SizeLimitExceeded;
        return allocator.dupe(u8, input);
    }

    if (max_output < 9) return error.SizeLimitExceeded;

    var output = try BoundedWriter.init(allocator, max_output);
    defer output.deinit();

    const workspace = try allocator.create(CompressWorkspace);
    defer allocator.destroy(workspace);

    const container: std.compress.flate.Container =
        if (kind == .gzip) .gzip else .zlib;

    workspace.compressor = std.compress.flate.Compress.init(
        &output.writer,
        &workspace.history,
        container,
        .fastest,
    ) catch return outputFailure(&output);

    workspace.compressor.writer.writeAll(input) catch
        return outputFailure(&output);

    workspace.compressor.finish() catch
        return outputFailure(&output);

    return output.toOwnedSlice();
}

pub fn decompress(
    allocator: std.mem.Allocator,
    input: []const u8,
    kind: Compression,
    max_output: usize,
    reject_trailing_bytes: bool,
) (Error || std.mem.Allocator.Error)![]u8 {
    if (kind == .none) {
        if (input.len > max_output) return error.SizeLimitExceeded;
        return allocator.dupe(u8, input);
    }

    validateHeader(input, kind) catch return error.MalformedCompressedData;

    var source: std.Io.Reader = .fixed(input);

    const workspace = try allocator.create(DecompressWorkspace);
    defer allocator.destroy(workspace);

    const container: std.compress.flate.Container =
        if (kind == .gzip) .gzip else .zlib;

    workspace.inflater = .init(
        &source,
        container,
        &workspace.history,
    );

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    while (workspace.inflater.reader.peekGreedy(1)) |chunk| {
        const new_len = std.math.add(
            usize,
            output.items.len,
            chunk.len,
        ) catch return error.SizeLimitExceeded;

        try bounded_buffer.ensureCapacity(
            &output,
            allocator,
            new_len,
            max_output,
        );

        output.appendSliceAssumeCapacity(chunk);
        workspace.inflater.reader.toss(chunk.len);
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return error.MalformedCompressedData,
    }

    switch (workspace.inflater.container_metadata) {
        .gzip => |metadata| {
            if (metadata.crc != std.hash.Crc32.hash(output.items) or
                metadata.count != @as(u32, @truncate(output.items.len)))
                return error.MalformedCompressedData;
        },
        .zlib => |metadata| {
            if (metadata.adler != std.hash.Adler32.hash(output.items))
                return error.MalformedCompressedData;
        },
        .raw => {},
    }

    const has_trailing_data =
        reject_trailing_bytes and
        source.bufferedLen() != 0;

    if (has_trailing_data) return error.TrailingData;

    return output.toOwnedSlice(allocator);
}

fn validateHeader(input: []const u8, kind: Compression) !void {
    var reader: std.Io.Reader = .fixed(input);
    if (kind == .zlib) {
        const header = try reader.takeArray(2);
        if (std.mem.readInt(u16, header, .big) % 31 != 0 or header[1] & 0x20 != 0)
            return error.MalformedCompressedData;
    } else {
        const header = try reader.takeArray(10);
        const flags = header[3];
        if (flags & 0xe0 != 0) return error.MalformedCompressedData;
        if (flags & 4 != 0) {
            const extra_len = try reader.takeInt(u16, .little);
            try reader.discardAll(extra_len);
        }
        if (flags & 8 != 0) _ = try reader.discardDelimiterInclusive(0);
        if (flags & 16 != 0) _ = try reader.discardDelimiterInclusive(0);
        if (flags & 2 != 0) {
            const checksum: u16 = @truncate(std.hash.Crc32.hash(input[0..reader.seek]));
            if (try reader.takeInt(u16, .little) != checksum)
                return error.MalformedCompressedData;
        }
    }
}
