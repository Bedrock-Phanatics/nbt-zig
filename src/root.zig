const std = @import("std");
const Allocator = std.mem.Allocator;

const BoundedWriter = @import("internal/BoundedWriter.zig");
const compression = @import("compression.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const options = @import("options.zig");
const types = @import("types.zig");

pub const builder = @import("builder.zig");

pub const Encoding = options.Encoding;
pub const Compression = options.Compression;
pub const Options = options.Options;

pub const TagType = types.TagType;
pub const Tag = types.Tag;
pub const List = types.List;
pub const Entry = types.Entry;
pub const Compound = types.Compound;
pub const Document = types.Document;

pub const CodecError = types.CodecError;
pub const CompressionError = compression.Error;
pub const Error = CodecError || CompressionError || Allocator.Error;

pub fn parse(allocator: Allocator, input: []const u8, opts: Options) Error!Document {
    try opts.validate();
    if (input.len > opts.max_input_bytes) return error.SizeLimitExceeded;
    if (opts.compression == .none) return decode.decode(allocator, input, opts);

    var plain = try compression.decompress(
        allocator,
        input,
        opts.compression,
        opts.max_decompressed_bytes,
        opts.reject_trailing_bytes,
    );
    defer plain.deinit();

    return decode.decode(allocator, try plain.written(), opts);
}

pub fn serialize(allocator: Allocator, document: Document, opts: Options) Error![]u8 {
    try opts.validate();

    const plain = try encode.encode(allocator, document, opts);
    if (opts.compression == .none) return plain;
    defer allocator.free(plain);

    return compression.compress(allocator, plain, opts.compression, opts.max_output_bytes);
}

/// Buffers the rest of the reader, up to `max_input_bytes`, then parses it.
pub fn parseReader(allocator: Allocator, reader: *std.Io.Reader, opts: Options) (Error || error{ReadFailed})!Document {
    try opts.validate();

    var input = try BoundedWriter.init(allocator, opts.max_input_bytes, 0);
    defer input.deinit();

    _ = reader.streamRemaining(&input.writer) catch |err| return switch (err) {
        error.ReadFailed => error.ReadFailed,
        error.WriteFailed => input.err(),
    };

    return parse(allocator, try input.written(), opts);
}

/// Streams uncompressed NBT, compressed output is buffered first. Does not flush,
/// and an error can leave partial output behind.
pub fn writeDocument(
    allocator: Allocator,
    writer: *std.Io.Writer,
    document: Document,
    opts: Options,
) (Error || std.Io.Writer.Error)!void {
    try opts.validate();
    if (opts.compression == .none) return encode.write(allocator, writer, document, opts);

    const bytes = try serialize(allocator, document, opts);
    defer allocator.free(bytes);

    try writer.writeAll(bytes);
}
