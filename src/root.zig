const std = @import("std");
const Allocator = std.mem.Allocator;

const BoundedWriter = @import("internal/BoundedWriter.zig");
const compression = @import("compression.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const options = @import("options.zig");
const scan = @import("scan.zig");
const types = @import("types.zig");

pub const builder = @import("builder.zig");

pub const Encoding = options.Encoding;
pub const Compression = options.Compression;
pub const Options = options.Options;
pub const DuplicateNames = options.DuplicateNames;

pub const TagType = types.TagType;
pub const Tag = types.Tag;
pub const List = types.List;
pub const Entry = types.Entry;
pub const Compound = types.Compound;
pub const Document = types.Document;

pub const CodecError = types.CodecError;
pub const CompressionError = compression.Error;
pub const Error = CodecError || CompressionError || Allocator.Error;
pub const ScanError = scan.Error;

pub const scanDocument = scan.scanDocument;
pub const scanOptionalDocument = scan.scanOptionalDocument;
pub const scanPayload = scan.scanPayload;

pub const Parsed = decode.Decoded;
pub const ParsedPayload = decode.DecodedPayload;

pub fn parse(allocator: Allocator, input: []const u8, opts: Options) Error!Document {
    try opts.validate();
    if (input.len > opts.max_input_bytes) return error.SizeLimitExceeded;
    if (opts.compression == .none) return (try decode.decode(allocator, input, opts)).document;

    var plain = try compression.decompress(
        allocator,
        input,
        opts.compression,
        opts.max_decompressed_bytes,
        opts.reject_trailing_bytes,
    );
    defer plain.deinit();

    return (try decode.decode(allocator, try plain.written(), opts)).document;
}

/// Parses the uncompressed document at the start of `input` and reports how many bytes
/// it used, for documents inside a larger buffer or several in a row. Reading stops at
/// `max_input_bytes` like the scanner.
pub fn parsePrefix(allocator: Allocator, input: []const u8, opts: Options) Error!Parsed {
    try checkPlain(opts);
    return clipped(input, opts, decode.decode(allocator, clip(input, opts), opts));
}

/// Parses a headerless uncompressed payload whose type the caller already knows.
pub fn parsePayload(allocator: Allocator, input: []const u8, tag_type: TagType, opts: Options) Error!ParsedPayload {
    try checkPlain(opts);
    return clipped(input, opts, decode.decodePayload(allocator, clip(input, opts), tag_type, opts));
}

fn checkPlain(opts: Options) Error!void {
    try opts.validate();
    if (opts.compression != .none) return error.InvalidOptions;
}

fn clip(input: []const u8, opts: Options) []const u8 {
    return input[0..@min(input.len, opts.max_input_bytes)];
}

fn clipped(input: []const u8, opts: Options, result: anytype) @TypeOf(result) {
    return result catch |err| {
        if (err == error.UnexpectedEndOfInput and input.len > opts.max_input_bytes) return error.SizeLimitExceeded;
        return err;
    };
}

pub fn serialize(allocator: Allocator, document: Document, opts: Options) Error![]u8 {
    try opts.validate();

    const plain = try encode.encode(allocator, document, opts);
    if (opts.compression == .none) return plain;
    defer allocator.free(plain);

    return compression.compress(allocator, plain, opts.compression, opts.max_output_bytes);
}

/// Serializes a headerless uncompressed payload.
pub fn serializePayload(allocator: Allocator, tag: Tag, opts: Options) Error![]u8 {
    try checkPlain(opts);
    return encode.encodePayload(allocator, tag, opts);
}

/// Exact uncompressed size `serialize` gives a `Document`, or `serializePayload` a `Tag`,
/// whenever they succeed. Handy for writing straight into a buffer of the right size.
pub fn encodedLength(value: anytype, opts: Options) Error!usize {
    try opts.validate();
    return encode.encodedLength(value, opts);
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

/// Streams a headerless uncompressed payload with the same caveats as `writeDocument`.
pub fn writePayload(allocator: Allocator, writer: *std.Io.Writer, tag: Tag, opts: Options) (Error || std.Io.Writer.Error)!void {
    try checkPlain(opts);
    return encode.writePayload(allocator, writer, tag, opts);
}

test {
    _ = scan;
}
