const std = @import("std");

pub const builder = @import("builder.zig");
const codec = @import("codec.zig");
pub const CodecError = codec.Error;
const compression = @import("compression.zig");
pub const CompressionError = compression.Error;
const bounded_buffer = @import("internal/bounded_buffer.zig");
const options = @import("options.zig");
pub const Encoding = options.Encoding;
pub const Compression = options.Compression;
pub const Options = options.Options;
const types = @import("types.zig");
pub const TagType = types.TagType;
pub const Tag = types.Tag;
pub const List = types.List;
pub const Entry = types.Entry;
pub const Compound = types.Compound;
pub const Document = types.Document;

pub const Error = CodecError || CompressionError || std.mem.Allocator.Error;

/// Parses an owned document. Uncompressed slices are read in place.
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: Options,
) Error!Document {
    try opts.validate();

    if (input.len > opts.max_input_bytes) return error.SizeLimitExceeded;
    if (opts.compression == .none) return codec.decode(allocator, input, opts);

    const plain = try compression.decompress(
        allocator,
        input,
        opts.compression,
        opts.max_decompressed_bytes,
        opts.reject_trailing_bytes,
    );
    defer allocator.free(plain);

    return codec.decode(allocator, plain, opts);
}

/// Serializes a document. The caller owns the returned bytes.
pub fn serialize(
    allocator: std.mem.Allocator,
    document: Document,
    opts: Options,
) Error![]u8 {
    try opts.validate();

    const plain = try codec.encode(allocator, document, opts);
    if (opts.compression == .none) return plain;

    defer allocator.free(plain);

    return compression.compress(
        allocator,
        plain,
        opts.compression,
        opts.max_output_bytes,
    );
}

/// Buffers the remaining input, then parses it. The caller keeps the reader.
pub fn parseReader(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    opts: Options,
) (Error || std.Io.Reader.Error)!Document {
    try opts.validate();

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    while (reader.peekGreedy(1)) |chunk| {
        const new_len = std.math.add(
            usize,
            bytes.items.len,
            chunk.len,
        ) catch return error.SizeLimitExceeded;

        try bounded_buffer.ensureCapacity(
            &bytes,
            allocator,
            new_len,
            opts.max_input_bytes,
        );

        bytes.appendSliceAssumeCapacity(chunk);
        reader.toss(chunk.len);
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return error.ReadFailed,
    }

    return parse(allocator, bytes.items, opts);
}

/// Writes a serialized document. The caller keeps the writer.
pub fn writeDocument(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    document: Document,
    opts: Options,
) (Error || std.Io.Writer.Error)!void {
    const bytes = try serialize(allocator, document, opts);
    defer allocator.free(bytes);

    try writer.writeAll(bytes);
}
