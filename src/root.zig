const std = @import("std");
const codec = @import("codec.zig");
const compression = @import("compression.zig");
const bounded_buffer = @import("internal/bounded_buffer.zig");

pub const TagType = @import("types.zig").TagType;
pub const Tag = @import("types.zig").Tag;
pub const List = @import("types.zig").List;
pub const Entry = @import("types.zig").Entry;
pub const Compound = @import("types.zig").Compound;
pub const Document = @import("types.zig").Document;
pub const builder = @import("builder.zig");
pub const Encoding = @import("options.zig").Encoding;
pub const Compression = @import("options.zig").Compression;
pub const Options = @import("options.zig").Options;
pub const CodecError = codec.Error;
pub const CompressionError = compression.Error;
pub const Error = CodecError || CompressionError || std.mem.Allocator.Error;

/// Parses an owned document. Uncompressed slices are read in place.
pub fn parse(allocator: std.mem.Allocator, input: []const u8, options: Options) Error!Document {
    try options.validate();
    if (input.len > options.max_input_bytes) return error.SizeLimitExceeded;
    if (options.compression == .none) return codec.decode(allocator, input, options);
    const plain = try compression.decompress(
        allocator,
        input,
        options.compression,
        options.max_decompressed_bytes,
        options.reject_trailing_bytes,
    );
    defer allocator.free(plain);
    return codec.decode(allocator, plain, options);
}

/// Serializes a document. The caller owns the returned bytes.
pub fn serialize(allocator: std.mem.Allocator, document: Document, options: Options) Error![]u8 {
    try options.validate();
    const plain = try codec.encode(allocator, document, options);
    if (options.compression == .none) return plain;
    defer allocator.free(plain);
    return compression.compress(allocator, plain, options.compression, options.max_output_bytes);
}

/// Buffers the remaining input, then parses it. The caller keeps the reader.
pub fn parseReader(allocator: std.mem.Allocator, reader: *std.Io.Reader, options: Options) (Error || std.Io.Reader.Error)!Document {
    try options.validate();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    while (reader.peekGreedy(1)) |chunk| {
        const new_len = std.math.add(usize, bytes.items.len, chunk.len) catch return error.SizeLimitExceeded;
        try bounded_buffer.ensureCapacity(&bytes, allocator, new_len, options.max_input_bytes);
        bytes.appendSliceAssumeCapacity(chunk);
        reader.toss(chunk.len);
    } else |err| switch (err) {
        error.EndOfStream => {}, // NOOP: normal EOF.
        error.ReadFailed => return error.ReadFailed,
    }
    return parse(allocator, bytes.items, options);
}

/// Writes a serialized document. The caller keeps the writer.
pub fn writeDocument(allocator: std.mem.Allocator, writer: *std.Io.Writer, document: Document, options: Options) (Error || std.Io.Writer.Error)!void {
    const bytes = try serialize(allocator, document, options);
    defer allocator.free(bytes);
    try writer.writeAll(bytes);
}
