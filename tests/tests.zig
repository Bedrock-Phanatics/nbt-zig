const std = @import("std");
const nbt = @import("nbt");

fn ownedDocument(allocator: std.mem.Allocator) !nbt.Document {
    const name = try allocator.dupe(u8, "root");
    errdefer allocator.free(name);
    const entries = try allocator.alloc(nbt.Entry, 12);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| {
            allocator.free(entry.name);
            entry.value.deinit(allocator);
        }
        allocator.free(entries);
    }
    const specs = [_]struct { []const u8, nbt.Tag }{
        .{ "byte", .{ .byte = -1 } },
        .{ "short", .{ .short = -3210 } },
        .{ "int", .{ .int = -123456 } },
        .{ "long", .{ .long = -9_876_543_210 } },
        .{ "float", .{ .float = 1.25 } },
        .{ "double", .{ .double = -99.125 } },
        .{ "text", .{ .string = try allocator.dupe(u8, "héllø 🌍") } },
        .{ "bytes", .{ .byte_array = try allocator.dupe(u8, &.{ 0, 1, 127, 255 }) } },
        .{ "ints", .{ .int_array = try allocator.dupe(i32, &.{ std.math.minInt(i32), 0, std.math.maxInt(i32) }) } },
        .{ "longs", .{ .long_array = try allocator.dupe(i64, &.{ std.math.minInt(i64), 0, std.math.maxInt(i64) }) } },
        .{ "list", .{ .list = .{ .element_type = .string, .items = blk: {
            const items = try allocator.alloc(nbt.Tag, 3);
            items[0] = .{ .string = try allocator.dupe(u8, "a") };
            items[1] = .{ .string = try allocator.dupe(u8, "b") };
            items[2] = .{ .string = try allocator.dupe(u8, "c") };
            break :blk items;
        } } } },
        .{ "empty", .{ .compound = .{ .entries = try allocator.alloc(nbt.Entry, 0) } } },
    };
    for (specs) |spec| {
        entries[initialized] = .{ .name = try allocator.dupe(u8, spec[0]), .value = spec[1] };
        initialized += 1;
    }
    return .{ .name = name, .root = .{ .compound = .{ .entries = entries } } };
}

test "Java golden payload" {
    const allocator = std.testing.allocator;
    const entries = try allocator.alloc(nbt.Entry, 1);
    entries[0] = .{ .name = try allocator.dupe(u8, "name"), .value = .{ .string = try allocator.dupe(u8, "Bananrama") } };
    var document: nbt.Document = .{ .name = try allocator.dupe(u8, "hello world"), .root = .{ .compound = .{ .entries = entries } } };
    defer document.deinit(allocator);
    const bytes = try nbt.serialize(allocator, document, .java);
    defer allocator.free(bytes);
    var expected: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "0A000B68656C6C6F20776F726C640800046E616D65000942616E616E72616D6100");
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "all encodings round trip every tag family" {
    const allocator = std.testing.allocator;
    inline for (.{ nbt.Options.java, nbt.Options.bedrock, nbt.Options.bedrock_network }) |options| {
        var document = try ownedDocument(allocator);
        defer document.deinit(allocator);
        const bytes = try nbt.serialize(allocator, document, options);
        defer allocator.free(bytes);
        var decoded = try nbt.parse(allocator, bytes, options);
        defer decoded.deinit(allocator);
        try std.testing.expect(document.eql(decoded));
    }
}

test "Java modified UTF-8 null and supplementary scalar" {
    const allocator = std.testing.allocator;
    var document: nbt.Document = .{ .name = try allocator.dupe(u8, "\x00😀"), .root = .{ .string = try allocator.dupe(u8, "\x00😀") } };
    defer document.deinit(allocator);
    const data = try nbt.serialize(allocator, document, .java);
    defer allocator.free(data);
    const expected = [_]u8{ 8, 0, 8, 0xc0, 0x80, 0xed, 0xa0, 0xbd, 0xed, 0xb8, 0x80, 0, 8, 0xc0, 0x80, 0xed, 0xa0, 0xbd, 0xed, 0xb8, 0x80 };
    try std.testing.expectEqualSlices(u8, &expected, data);
    var parsed = try nbt.parse(allocator, data, .java);
    defer parsed.deinit(allocator);
    try std.testing.expect(document.eql(parsed));
}

test "Bedrock network golden signed length" {
    const allocator = std.testing.allocator;
    const items = try allocator.alloc(nbt.Tag, 1);
    items[0] = .{ .byte = 127 };
    var document: nbt.Document = .{ .name = try allocator.dupe(u8, ""), .root = .{ .list = .{ .element_type = .byte, .items = items } } };
    defer document.deinit(allocator);
    const data = try nbt.serialize(allocator, document, .bedrock_network);
    defer allocator.free(data);
    try std.testing.expectEqualSlices(u8, &.{ 9, 0, 1, 2, 127 }, data);
}

test "gzip and zlib round trip" {
    const allocator = std.testing.allocator;
    inline for (.{ nbt.Compression.gzip, nbt.Compression.zlib }) |compression| {
        var document = try ownedDocument(allocator);
        defer document.deinit(allocator);
        const options: nbt.Options = .{ .compression = compression };
        const bytes = try nbt.serialize(allocator, document, options);
        defer allocator.free(bytes);
        var decoded = try nbt.parse(allocator, bytes, options);
        defer decoded.deinit(allocator);
        try std.testing.expect(document.eql(decoded));
    }
}

test "malformed inputs and limits fail safely" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidTag, nbt.parse(allocator, &.{99}, .java));
    try std.testing.expectError(error.UnexpectedEndOfInput, nbt.parse(allocator, &.{ 10, 0, 0 }, .java));
    try std.testing.expectError(error.VarIntOverflow, nbt.parse(allocator, &.{ 3, 0, 0xff, 0xff, 0xff, 0xff, 0x1f }, .bedrock_network));
    try std.testing.expectError(error.InvalidListType, nbt.parse(allocator, &.{ 9, 0, 0, 0, 0, 0, 0, 1 }, .java));
    try std.testing.expectError(error.InvalidModifiedUtf8, nbt.parse(allocator, &.{ 8, 0, 1, 0xc0 }, .java));

    var document = try ownedDocument(allocator);
    defer document.deinit(allocator);
    const bytes = try nbt.serialize(allocator, document, .java);
    defer allocator.free(bytes);
    var limited: nbt.Options = .java;
    limited.max_collection_length = 2;
    try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, bytes, limited));
}

test "truncation at every boundary never leaks" {
    const allocator = std.testing.allocator;
    var document = try ownedDocument(allocator);
    defer document.deinit(allocator);
    const bytes = try nbt.serialize(allocator, document, .java);
    defer allocator.free(bytes);
    for (0..bytes.len) |end| {
        if (nbt.parse(allocator, bytes[0..end], .java)) |unexpected_value| {
            var unexpected = unexpected_value;
            unexpected.deinit(allocator);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "depth, list homogeneity, trailing data, and duplicate names" {
    const allocator = std.testing.allocator;
    const empty_entries = try allocator.alloc(nbt.Entry, 0);
    const nested_items = try allocator.alloc(nbt.Tag, 1);
    nested_items[0] = .{ .compound = .{ .entries = empty_entries } };
    var nested: nbt.Document = .{ .name = try allocator.dupe(u8, ""), .root = .{ .list = .{ .element_type = .compound, .items = nested_items } } };
    defer nested.deinit(allocator);
    var shallow: nbt.Options = .java;
    shallow.max_depth = 1;
    try std.testing.expectError(error.DepthLimitExceeded, nbt.serialize(allocator, nested, shallow));

    const wrong_items = try allocator.alloc(nbt.Tag, 1);
    wrong_items[0] = .{ .string = try allocator.dupe(u8, "x") };
    var wrong: nbt.Document = .{ .name = try allocator.dupe(u8, ""), .root = .{ .list = .{ .element_type = .int, .items = wrong_items } } };
    defer wrong.deinit(allocator);
    try std.testing.expectError(error.TypeMismatch, nbt.serialize(allocator, wrong, .java));

    const valid = [_]u8{ 1, 0, 0, 7, 42 };
    var strict: nbt.Options = .java;
    strict.reject_trailing_bytes = true;
    try std.testing.expectError(error.TrailingData, nbt.parse(allocator, &valid, strict));
}

test "fuzz-friendly decoder entry point" {
    const allocator = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x4e4254);
    var random = prng.random();
    var buffer: [256]u8 = undefined;
    for (0..1000) |_| {
        const len = random.uintLessThan(usize, buffer.len + 1);
        random.bytes(buffer[0..len]);
        var options: nbt.Options = .bedrock_network;
        options.max_depth = 16;
        options.max_collection_length = 128;
        options.max_compound_entries = 128;
        options.max_string_bytes = 128;
        options.max_total_decoded_bytes = 4096;
        if (nbt.parse(allocator, buffer[0..len], options)) |document_value| {
            var document = document_value;
            document.deinit(allocator);
        } else |_| {}
    }
}

test "ownership-safe builders" {
    const allocator = std.testing.allocator;
    var list_builder = nbt.builder.List.init(allocator, .int);
    defer list_builder.deinit();
    try list_builder.append(.{ .int = 1 });
    try list_builder.append(.{ .int = 2 });
    var list_tag = try list_builder.finish();
    var list_owned = true;
    defer if (list_owned) list_tag.deinit(allocator);

    var compound_builder = nbt.builder.Compound.init(allocator);
    defer compound_builder.deinit();
    try compound_builder.add("values", list_tag);
    list_owned = false;
    var root = try compound_builder.finish();
    var root_owned = true;
    defer if (root_owned) root.deinit(allocator);
    var document = try nbt.Document.init(allocator, "built", root);
    root_owned = false;
    defer document.deinit(allocator);

    const bytes = try nbt.serialize(allocator, document, .bedrock);
    defer allocator.free(bytes);
    var parsed = try nbt.parse(allocator, bytes, .bedrock);
    defer parsed.deinit(allocator);
    try std.testing.expect(document.eql(parsed));
}

fn sampleTag(allocator: std.mem.Allocator, tag_type: nbt.TagType) !nbt.Tag {
    return switch (tag_type) {
        .end => .{ .end = {} },
        .byte => .{ .byte = -128 },
        .short => .{ .short = std.math.minInt(i16) },
        .int => .{ .int = std.math.maxInt(i32) },
        .long => .{ .long = std.math.minInt(i64) },
        .float => .{ .float = -0.0 },
        .double => .{ .double = std.math.inf(f64) },
        .byte_array => try nbt.builder.byteArray(allocator, &.{ 0, 255 }),
        .string => try nbt.builder.string(allocator, "list value"),
        .int_array => try nbt.builder.intArray(allocator, &.{ std.math.minInt(i32), std.math.maxInt(i32) }),
        .long_array => try nbt.builder.longArray(allocator, &.{ std.math.minInt(i64), std.math.maxInt(i64) }),
        .list => blk: {
            const inner_items = try allocator.alloc(nbt.Tag, 1);
            inner_items[0] = .{ .byte = 7 };
            break :blk .{ .list = .{ .element_type = .byte, .items = inner_items } };
        },
        .compound => blk: {
            const entries = try allocator.alloc(nbt.Entry, 1);
            errdefer allocator.free(entries);
            entries[0] = .{ .name = try allocator.dupe(u8, "nested"), .value = .{ .int = 42 } };
            break :blk .{ .compound = .{ .entries = entries } };
        },
    };
}

test "lists of every legal element type and nested containers" {
    const allocator = std.testing.allocator;
    inline for (.{
        nbt.TagType.byte,
        nbt.TagType.short,
        nbt.TagType.int,
        nbt.TagType.long,
        nbt.TagType.float,
        nbt.TagType.double,
        nbt.TagType.byte_array,
        nbt.TagType.string,
        nbt.TagType.list,
        nbt.TagType.compound,
        nbt.TagType.int_array,
        nbt.TagType.long_array,
    }) |tag_type| {
        const items = try allocator.alloc(nbt.Tag, 1);
        items[0] = try sampleTag(allocator, tag_type);
        var document = try nbt.Document.init(allocator, "", .{ .list = .{ .element_type = tag_type, .items = items } });
        defer document.deinit(allocator);
        const bytes = try nbt.serialize(allocator, document, .bedrock_network);
        defer allocator.free(bytes);
        var parsed = try nbt.parse(allocator, bytes, .bedrock_network);
        defer parsed.deinit(allocator);
        try std.testing.expect(document.eql(parsed));
    }

    const empty = try allocator.alloc(nbt.Tag, 0);
    var end_list = try nbt.Document.init(allocator, "", .{ .list = .{ .element_type = .end, .items = empty } });
    defer end_list.deinit(allocator);
    const bytes = try nbt.serialize(allocator, end_list, .java);
    defer allocator.free(bytes);
    var parsed = try nbt.parse(allocator, bytes, .java);
    defer parsed.deinit(allocator);
    try std.testing.expect(end_list.eql(parsed));
}

fn minimalListElement(allocator: std.mem.Allocator, tag_type: nbt.TagType) !nbt.Tag {
    return switch (tag_type) {
        .end => .{ .end = {} },
        .byte => .{ .byte = 0 },
        .short => .{ .short = 0 },
        .int => .{ .int = 0 },
        .long => .{ .long = 0 },
        .float => .{ .float = 0 },
        .double => .{ .double = 0 },
        .byte_array => try nbt.builder.byteArray(allocator, &.{}),
        .string => try nbt.builder.string(allocator, ""),
        .int_array => try nbt.builder.intArray(allocator, &.{}),
        .long_array => try nbt.builder.longArray(allocator, &.{}),
        .list => blk: {
            const items = try allocator.alloc(nbt.Tag, 0);
            break :blk .{ .list = .{ .element_type = .end, .items = items } };
        },
        .compound => .{ .compound = .{
            .entries = try allocator.alloc(nbt.Entry, 0),
        } },
    };
}

test "minimum-size list elements decode in every encoding" {
    const allocator = std.testing.allocator;

    inline for (.{
        nbt.Options.java,
        nbt.Options.bedrock,
        nbt.Options.bedrock_network,
    }) |options| {
        inline for (.{
            nbt.TagType.byte,
            nbt.TagType.short,
            nbt.TagType.int,
            nbt.TagType.long,
            nbt.TagType.float,
            nbt.TagType.double,
            nbt.TagType.byte_array,
            nbt.TagType.string,
            nbt.TagType.list,
            nbt.TagType.compound,
            nbt.TagType.int_array,
            nbt.TagType.long_array,
        }) |tag_type| {
            {
                const items = try allocator.alloc(nbt.Tag, 1);
                items[0] = try minimalListElement(allocator, tag_type);

                var document = try nbt.Document.init(
                    allocator,
                    "",
                    .{ .list = .{
                        .element_type = tag_type,
                        .items = items,
                    } },
                );
                defer document.deinit(allocator);

                const bytes = try nbt.serialize(allocator, document, options);
                defer allocator.free(bytes);

                var parsed = try nbt.parse(allocator, bytes, options);
                defer parsed.deinit(allocator);

                try std.testing.expect(document.eql(parsed));
            }
        }

        {
            const items = try allocator.alloc(nbt.Tag, 0);
            var document = try nbt.Document.init(
                allocator,
                "",
                .{ .list = .{
                    .element_type = .end,
                    .items = items,
                } },
            );
            defer document.deinit(allocator);

            const bytes = try nbt.serialize(allocator, document, options);
            defer allocator.free(bytes);

            var parsed = try nbt.parse(allocator, bytes, options);
            defer parsed.deinit(allocator);

            try std.testing.expect(document.eql(parsed));
        }
    }
}

test "number arrays reject impossible payloads before allocation" {
    const allocator = std.testing.allocator;

    const java_int_array = [_]u8{ 11, 0, 0, 0x00, 0x0F, 0x42, 0x40 };
    const java_long_array = [_]u8{ 12, 0, 0, 0x00, 0x0F, 0x42, 0x40 };
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        nbt.parse(allocator, &java_int_array, .java),
    );
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        nbt.parse(allocator, &java_long_array, .java),
    );

    const bedrock_int_array = [_]u8{ 11, 0, 0, 0x40, 0x42, 0x0F, 0x00 };
    const bedrock_long_array = [_]u8{ 12, 0, 0, 0x40, 0x42, 0x0F, 0x00 };
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        nbt.parse(allocator, &bedrock_int_array, .bedrock),
    );
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        nbt.parse(allocator, &bedrock_long_array, .bedrock),
    );

    const network_int_array = [_]u8{ 11, 0, 0x80, 0x89, 0x7A };
    const network_long_array = [_]u8{ 12, 0, 0x80, 0x89, 0x7A };
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        nbt.parse(allocator, &network_int_array, .bedrock_network),
    );
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        nbt.parse(allocator, &network_long_array, .bedrock_network),
    );
}

test "malformed compression and decompression limits" {
    const allocator = std.testing.allocator;
    var gzip_options: nbt.Options = .java;
    gzip_options.compression = .gzip;
    try std.testing.expectError(error.MalformedCompressedData, nbt.parse(allocator, &.{ 0x1f, 0x8b, 8 }, gzip_options));

    var payload: [256]u8 = @splat(0xaa);
    var document = try nbt.Document.init(allocator, "", try nbt.builder.byteArray(allocator, &payload));
    defer document.deinit(allocator);
    const compressed = try nbt.serialize(allocator, document, gzip_options);
    defer allocator.free(compressed);
    var limited = gzip_options;
    limited.max_input_bytes = 64;
    limited.max_total_decoded_bytes = 64;
    try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, compressed, limited));
}

test "input output option validation and strict modified UTF-8" {
    const allocator = std.testing.allocator;
    const minimal = [_]u8{ 1, 0, 0, 0 };

    var input_limited: nbt.Options = .java;
    input_limited.max_input_bytes = minimal.len - 1;
    try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, &minimal, input_limited));

    var invalid_compressed: nbt.Options = .java;
    invalid_compressed.compression = .gzip;
    invalid_compressed.max_depth = 0;
    try std.testing.expectError(error.InvalidOptions, nbt.parse(allocator, &.{ 0x1f, 0x8b }, invalid_compressed));

    try std.testing.expectError(error.InvalidModifiedUtf8, nbt.parse(allocator, &.{ 8, 0, 1, 0 }, .java));

    var document = try nbt.Document.init(allocator, "", .{ .byte = 0 });
    defer document.deinit(allocator);
    var output_limited: nbt.Options = .java;
    output_limited.max_output_bytes = minimal.len - 1;
    try std.testing.expectError(error.SizeLimitExceeded, nbt.serialize(allocator, document, output_limited));
}

test "builder permits only an empty TAG_End list" {
    const allocator = std.testing.allocator;
    var list_builder = nbt.builder.List.init(allocator, .end);
    defer list_builder.deinit();
    try std.testing.expectError(error.InvalidListType, list_builder.append(.{ .end = {} }));
    var list = try list_builder.finish();
    defer list.deinit(allocator);
    try std.testing.expectEqual(nbt.TagType.end, list.list.element_type);
    try std.testing.expectEqual(@as(usize, 0), list.list.items.len);
}

test "stream APIs propagate success and I/O failures" {
    const allocator = std.testing.allocator;
    var document = try nbt.Document.init(allocator, "stream", .{ .int = 42 });
    defer document.deinit(allocator);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try nbt.writeDocument(allocator, &output.writer, document, .bedrock);

    var input: std.Io.Reader = .fixed(output.written());
    var parsed = try nbt.parseReader(allocator, &input, .bedrock);
    defer parsed.deinit(allocator);
    try std.testing.expect(document.eql(parsed));

    var failing_writer: std.Io.Writer = .failing;
    try std.testing.expectError(
        error.WriteFailed,
        nbt.writeDocument(allocator, &failing_writer, document, .bedrock),
    );
    var failing_buffer: [1]u8 = undefined;
    var failing_reader: std.Io.Reader = .failing;
    failing_reader.buffer = &failing_buffer;
    try std.testing.expectError(
        error.ReadFailed,
        nbt.parseReader(allocator, &failing_reader, .bedrock),
    );

    var limited: nbt.Options = .bedrock;
    limited.max_input_bytes = output.written().len - 1;
    var limited_input: std.Io.Reader = .fixed(output.written());
    try std.testing.expectError(
        error.SizeLimitExceeded,
        nbt.parseReader(allocator, &limited_input, limited),
    );
}

test "duplicate names and rejected builder values remain safe" {
    const allocator = std.testing.allocator;
    const duplicate_wire = [_]u8{
        10,  0, 0,
        3,   0, 1,
        'x', 0, 0,
        0,   1, 3,
        0,   1, 'x',
        0,   0, 0,
        2,   0,
    };
    try std.testing.expectError(error.DuplicateName, nbt.parse(allocator, &duplicate_wire, .java));

    const entries = try allocator.alloc(nbt.Entry, 2);
    entries[0] = .{ .name = try allocator.dupe(u8, "x"), .value = .{ .int = 1 } };
    entries[1] = .{ .name = try allocator.dupe(u8, "x"), .value = .{ .int = 2 } };
    var duplicate_document = try nbt.Document.init(allocator, "", .{ .compound = .{ .entries = entries } });
    defer duplicate_document.deinit(allocator);
    try std.testing.expectError(error.DuplicateName, nbt.serialize(allocator, duplicate_document, .java));

    var compound_builder = nbt.builder.Compound.init(allocator);
    defer compound_builder.deinit();
    try compound_builder.add("x", .{ .int = 1 });
    try std.testing.expectError(error.DuplicateName, compound_builder.add("x", .{ .int = 2 }));
    try std.testing.expectError(error.InvalidTag, compound_builder.add("end", .{ .end = {} }));

    var list_builder = nbt.builder.List.init(allocator, .int);
    defer list_builder.deinit();
    var rejected = try nbt.builder.string(allocator, "caller still owns this");
    defer rejected.deinit(allocator);
    try std.testing.expectError(error.TypeMismatch, list_builder.append(rejected));

    try std.testing.expectError(error.InvalidRoot, nbt.Document.init(allocator, "", .{ .end = {} }));
}

test "compressed and decompressed output limits are independent" {
    const allocator = std.testing.allocator;
    var document = try nbt.Document.init(allocator, "", .{ .byte = 0 });
    defer document.deinit(allocator);

    inline for (.{ nbt.Compression.gzip, nbt.Compression.zlib }) |kind| {
        var options: nbt.Options = .java;
        options.compression = kind;
        const compressed = try nbt.serialize(allocator, document, options);
        defer allocator.free(compressed);

        var decompressed_limited = options;
        decompressed_limited.max_input_bytes = compressed.len;
        decompressed_limited.max_decompressed_bytes = 3;
        try std.testing.expectError(
            error.SizeLimitExceeded,
            nbt.parse(allocator, compressed, decompressed_limited),
        );

        var compressed_limited = options;
        compressed_limited.max_output_bytes = 4;
        try std.testing.expectError(
            error.SizeLimitExceeded,
            nbt.serialize(allocator, document, compressed_limited),
        );

        for (0..compressed.len) |end| {
            if (nbt.parse(allocator, compressed[0..end], options)) |unexpected_value| {
                var unexpected = unexpected_value;
                unexpected.deinit(allocator);
                return error.TestUnexpectedResult;
            } else |_| {}
        }
    }
}

test "truncation is rejected for every encoding" {
    const allocator = std.testing.allocator;
    inline for (.{ nbt.Options.java, nbt.Options.bedrock, nbt.Options.bedrock_network }) |options| {
        var document = try ownedDocument(allocator);
        defer document.deinit(allocator);
        const bytes = try nbt.serialize(allocator, document, options);
        defer allocator.free(bytes);
        for (0..bytes.len) |end| {
            if (nbt.parse(allocator, bytes[0..end], options)) |unexpected_value| {
                var unexpected = unexpected_value;
                unexpected.deinit(allocator);
                return error.TestUnexpectedResult;
            } else |_| {}
        }
    }
}

test "strict parsing rejects trailing compressed bytes" {
    const allocator = std.testing.allocator;
    var document = try nbt.Document.init(allocator, "", .{ .int = 42 });
    defer document.deinit(allocator);

    inline for (.{ nbt.Compression.gzip, nbt.Compression.zlib }) |kind| {
        var options: nbt.Options = .java;
        options.compression = kind;
        const compressed = try nbt.serialize(allocator, document, options);
        defer allocator.free(compressed);
        const with_junk = try std.mem.concat(allocator, u8, &.{ compressed, &.{0xaa} });
        defer allocator.free(with_junk);

        var permissive = try nbt.parse(allocator, with_junk, options);
        permissive.deinit(allocator);
        options.reject_trailing_bytes = true;
        try std.testing.expectError(error.TrailingData, nbt.parse(allocator, with_junk, options));
    }
}

test "defensive decoder limits have deterministic boundaries" {
    const allocator = std.testing.allocator;

    const string_wire = [_]u8{ 8, 0, 0, 0, 1, 'a' };
    var string_reject: nbt.Options = .java;
    string_reject.max_string_bytes = 0;
    try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, &string_wire, string_reject));
    var string_ok = try nbt.parse(allocator, &string_wire, .java);
    string_ok.deinit(allocator);

    const compound_wire = [_]u8{ 10, 0, 0, 1, 0, 1, 'x', 7, 0 };
    var compound_reject: nbt.Options = .java;
    compound_reject.max_compound_entries = 0;
    try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, &compound_wire, compound_reject));
    var compound_ok = try nbt.parse(allocator, &compound_wire, .java);
    compound_ok.deinit(allocator);

    const nested_list = [_]u8{ 9, 0, 0, 9, 0, 0, 0, 1, 1, 0, 0, 0, 0 };
    var shallow: nbt.Options = .java;
    shallow.max_depth = 1;
    try std.testing.expectError(error.DepthLimitExceeded, nbt.parse(allocator, &nested_list, shallow));
    shallow.max_depth = 2;
    var nested_ok = try nbt.parse(allocator, &nested_list, shallow);
    nested_ok.deinit(allocator);

    const huge_network_string = [_]u8{ 8, 0, 0xff, 0xff, 0xff, 0xff, 0x0f };
    try std.testing.expectError(
        error.SizeLimitExceeded,
        nbt.parse(allocator, &huge_network_string, .bedrock_network),
    );
}

test "builders roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, builderAllocationScenario, .{});
}

fn builderAllocationScenario(allocator: std.mem.Allocator) !void {
    var builder = nbt.builder.Compound.init(allocator);
    defer builder.deinit();

    var first = try nbt.builder.string(allocator, "first");
    var first_owned = true;
    errdefer if (first_owned) first.deinit(allocator);
    try builder.add("first", first);
    first_owned = false;

    var second = try nbt.builder.string(allocator, "second");
    var second_owned = true;
    errdefer if (second_owned) second.deinit(allocator);
    try builder.add("second", second);
    second_owned = false;

    var root = try builder.finish();
    defer root.deinit(allocator);
}

test "TAG_List truncated huge length rejects before large allocation (Java)" {
    const allocator = std.testing.allocator;
    const wire = [_]u8{ 9, 0, 0, 1, 0x00, 0x0F, 0x42, 0x40 };
    try std.testing.expectError(error.UnexpectedEndOfInput, nbt.parse(allocator, &wire, .java));
}

test "TAG_List truncated huge length rejects before large allocation (Bedrock)" {
    const allocator = std.testing.allocator;
    const wire = [_]u8{ 9, 0, 0, 1, 0x40, 0x42, 0x0F, 0x00 };
    try std.testing.expectError(error.UnexpectedEndOfInput, nbt.parse(allocator, &wire, .bedrock));
}

test "TAG_List truncated huge length rejects before large allocation (Bedrock Network)" {
    const allocator = std.testing.allocator;
    // in bedrock_network len = 1_000_000 zigzag encoded is 2_000_000
    // varint = 0x80, 0x89, 0x7A
    const wire = [_]u8{ 9, 0, 1, 0x80, 0x89, 0x7A };
    try std.testing.expectError(error.UnexpectedEndOfInput, nbt.parse(allocator, &wire, .bedrock_network));
}

test "TAG_List with TAG_End and non-zero length returns InvalidListType" {
    const allocator = std.testing.allocator;
    const wire = [_]u8{ 9, 0, 0, 0, 0, 0, 0, 1 };
    try std.testing.expectError(error.InvalidListType, nbt.parse(allocator, &wire, .java));
}

test "TAG_List valid lists decode correctly" {
    const allocator = std.testing.allocator;

    const empty_end_list = [_]u8{ 9, 0, 0, 0, 0, 0, 0, 0 };
    var doc1 = try nbt.parse(allocator, &empty_end_list, .java);
    defer doc1.deinit(allocator);
    try std.testing.expectEqual(nbt.TagType.end, doc1.root.list.element_type);
    try std.testing.expectEqual(@as(usize, 0), doc1.root.list.items.len);

    const byte_list = [_]u8{ 9, 0, 0, 1, 0, 0, 0, 2, 42, 43 };
    var doc2 = try nbt.parse(allocator, &byte_list, .java);
    defer doc2.deinit(allocator);
    try std.testing.expectEqual(nbt.TagType.byte, doc2.root.list.element_type);
    try std.testing.expectEqual(@as(usize, 2), doc2.root.list.items.len);
    try std.testing.expectEqual(@as(i8, 42), doc2.root.list.items[0].byte);
    try std.testing.expectEqual(@as(i8, 43), doc2.root.list.items[1].byte);
}

test "TAG_List boundary: exact minimum input vs one byte less" {
    const allocator = std.testing.allocator;

    const exact_wire = [_]u8{
        9, 0, 0, 3,  0, 0, 0, 2,
        0, 0, 0, 10, 0, 0, 0, 20,
    };
    var doc = try nbt.parse(allocator, &exact_wire, .java);
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), doc.root.list.items.len);
    try std.testing.expectEqual(@as(i32, 10), doc.root.list.items[0].int);
    try std.testing.expectEqual(@as(i32, 20), doc.root.list.items[1].int);

    const truncated_by_one = exact_wire[0 .. exact_wire.len - 1];
    try std.testing.expectError(error.UnexpectedEndOfInput, nbt.parse(allocator, truncated_by_one, .java));
}

test "TAG_List multiplication or reserve limit returns SizeLimitExceeded" {
    const allocator = std.testing.allocator;

    var opts = nbt.Options.java;
    opts.max_total_decoded_bytes = 100;
    const wire = [_]u8{ 9, 0, 0, 1, 0, 0, 0, 10 };
    try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, &wire, opts));
}

test "TAG_List proof: truncated input causes zero Tag allocation before error" {
    var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const tracking_alloc = failing_alloc.allocator();

    const wire = [_]u8{ 9, 0, 0, 1, 0x00, 0x0F, 0x42, 0x40 };
    try std.testing.expectError(error.UnexpectedEndOfInput, nbt.parse(tracking_alloc, &wire, .java));
}
