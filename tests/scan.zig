const std = @import("std");
const nbt = @import("nbt");
const fixtures = @import("fixtures");

const testing = std.testing;
const encodings = [_]nbt.Options{ .java, .bedrock, .bedrock_network };

/// One of every tag type, including nested containers and strings that need modified UTF-8.
fn sampleDocument(allocator: std.mem.Allocator) !nbt.Document {
    var root = nbt.builder.Compound.init(allocator);
    defer root.deinit();

    try root.add("byte", .{ .byte = -7 });
    try root.add("short", .{ .short = -300 });
    try root.add("int", .{ .int = std.math.minInt(i32) });
    try root.add("long", .{ .long = std.math.maxInt(i64) });
    try root.add("float", .{ .float = 1.5 });
    try root.add("double", .{ .double = -2.25 });
    try addOwned(&root, "bytes", try nbt.builder.byteArray(allocator, &.{ 0, 1, 255 }));
    try addOwned(&root, "ints", try nbt.builder.intArray(allocator, &.{ -1, 0, 1 << 30 }));
    try addOwned(&root, "longs", try nbt.builder.longArray(allocator, &.{ std.math.minInt(i64), 5 }));
    try addOwned(&root, "text", try nbt.builder.string(allocator, "héllo \x00 🌍"));

    var numbers = nbt.builder.List.init(allocator, .int);
    defer numbers.deinit();
    for (0..40) |index| try numbers.append(.{ .int = @as(i32, @intCast(index)) * 1000 - 7 });
    try addOwned(&root, "numbers", try numbers.finish());

    var compounds = nbt.builder.List.init(allocator, .compound);
    defer compounds.deinit();
    for (0..3) |index| {
        var child = nbt.builder.Compound.init(allocator);
        defer child.deinit();
        try child.add("index", .{ .byte = @intCast(index) });
        var nested = nbt.builder.List.init(allocator, .list);
        defer nested.deinit();
        var empty_strings = nbt.builder.List.init(allocator, .string);
        var inner = try empty_strings.finish();
        nested.append(inner) catch |err| {
            inner.deinit(allocator);
            return err;
        };
        try addOwned(&child, "nested", try nested.finish());
        var value = try child.finish();
        compounds.append(value) catch |err| {
            value.deinit(allocator);
            return err;
        };
    }
    try addOwned(&root, "compounds", try compounds.finish());
    var empty = nbt.builder.List.init(allocator, .end);
    try addOwned(&root, "empty", try empty.finish());

    var tag = try root.finish();
    errdefer tag.deinit(allocator);
    return nbt.Document.init(allocator, "sample", tag);
}

fn addOwned(compound: *nbt.builder.Compound, name: []const u8, value: nbt.Tag) !void {
    var owned = value;
    compound.add(name, owned) catch |err| {
        owned.deinit(compound.allocator);
        return err;
    };
}

test "scanner spans match the decoder on every fixture and encoding" {
    const allocator = testing.allocator;
    for (fixtures.documents) |fixture| {
        try testing.expectEqual(fixture.bytes.len, try nbt.scanDocument(fixture.bytes, fixture.options));
        var parsed = try nbt.parsePrefix(allocator, fixture.bytes, fixture.options);
        defer parsed.document.deinit(allocator);
        try testing.expectEqual(fixture.bytes.len, parsed.len);
    }

    var document = try sampleDocument(allocator);
    defer document.deinit(allocator);
    for (encodings) |options| {
        const bytes = try nbt.serialize(allocator, document, options);
        defer allocator.free(bytes);
        try testing.expectEqual(bytes.len, try nbt.scanDocument(bytes, options));
        try testing.expectEqual(bytes.len, try nbt.encodedLength(document, options));
    }
}

test "concatenated documents are walked by offset without copying" {
    const allocator = testing.allocator;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    var lengths: std.ArrayList(usize) = .empty;
    defer lengths.deinit(allocator);

    for (fixtures.documents) |fixture| {
        if (fixture.options.encoding != .bedrock) continue;
        try joined.appendSlice(allocator, fixture.bytes);
        try lengths.append(allocator, fixture.bytes.len);
    }
    try joined.append(allocator, 0xff);

    var offset: usize = 0;
    for (lengths.items) |expected| {
        try testing.expectEqual(expected, try nbt.scanDocument(joined.items[offset..], .bedrock));
        var parsed = try nbt.parsePrefix(allocator, joined.items[offset..], .bedrock);
        parsed.document.deinit(allocator);
        try testing.expectEqual(expected, parsed.len);
        offset += expected;
    }

    try testing.expectError(error.InvalidTag, nbt.scanDocument(joined.items[offset..], .bedrock));
    var strict: nbt.Options = .bedrock;
    strict.reject_trailing_bytes = true;
    try testing.expectError(error.TrailingData, nbt.scanDocument(joined.items, strict));
}

test "headerless payloads round trip and report their span" {
    const allocator = testing.allocator;
    var document = try sampleDocument(allocator);
    defer document.deinit(allocator);

    for (encodings) |options| {
        for (document.root.compound.entries) |entry| {
            const bytes = try nbt.serializePayload(allocator, entry.value, options);
            defer allocator.free(bytes);
            try testing.expectEqual(bytes.len, try nbt.encodedLength(entry.value, options));

            const padded = try std.mem.concat(allocator, u8, &.{ bytes, &.{ 1, 2, 3 } });
            defer allocator.free(padded);
            try testing.expectEqual(bytes.len, try nbt.scanPayload(padded, entry.value.tagType(), options));

            var parsed = try nbt.parsePayload(allocator, padded, entry.value.tagType(), options);
            defer parsed.tag.deinit(allocator);
            try testing.expectEqual(bytes.len, parsed.len);
            try testing.expect(parsed.tag.eql(entry.value));

            var buffer: [4096]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try nbt.writePayload(allocator, &writer, entry.value, options);
            try testing.expectEqualSlices(u8, bytes, writer.buffered());
        }

        try testing.expectError(error.InvalidTag, nbt.scanPayload(&.{0}, .end, options));
    }

    var compressed: nbt.Options = .{ .compression = .gzip };
    try testing.expectError(error.InvalidOptions, nbt.scanPayload(&.{1}, .byte, compressed));
    try testing.expectError(error.InvalidOptions, nbt.parsePayload(allocator, &.{1}, .byte, compressed));
    try testing.expectError(error.InvalidOptions, nbt.serializePayload(allocator, .{ .byte = 1 }, compressed));
    compressed.compression = .zlib;
    try testing.expectError(error.InvalidOptions, nbt.parsePrefix(allocator, &.{ 1, 0, 0, 1 }, compressed));
}

test "absent NBT is a lone TAG_End only where asked for" {
    const allocator = testing.allocator;
    for (encodings) |options| {
        try testing.expectEqual(@as(usize, 1), try nbt.scanOptionalDocument(&.{ 0, 0xaa }, options));
        try testing.expectError(error.InvalidRoot, nbt.scanDocument(&.{0}, options));
        try testing.expectError(error.InvalidRoot, nbt.parse(allocator, &.{0}, options));
        try testing.expectError(error.UnexpectedEndOfInput, nbt.scanOptionalDocument(&.{}, options));

        var strict = options;
        strict.reject_trailing_bytes = true;
        try testing.expectEqual(@as(usize, 1), try nbt.scanOptionalDocument(&.{0}, strict));
        try testing.expectError(error.TrailingData, nbt.scanOptionalDocument(&.{ 0, 0 }, strict));
    }
}

test "every truncation of every document is rejected by the scanner" {
    const allocator = testing.allocator;
    var document = try sampleDocument(allocator);
    defer document.deinit(allocator);

    for (encodings) |options| {
        const bytes = try nbt.serialize(allocator, document, options);
        defer allocator.free(bytes);
        for (0..bytes.len) |end| {
            try testing.expectError(error.UnexpectedEndOfInput, nbt.scanDocument(bytes[0..end], options));
        }
    }

    for (fixtures.documents) |fixture| {
        for (0..fixture.bytes.len) |end| {
            try testing.expectError(error.UnexpectedEndOfInput, nbt.scanDocument(fixture.bytes[0..end], fixture.options));
        }
    }
}

test "malformed structures fail the scanner the same way they fail the decoder" {
    const cases = [_]struct { []const u8, nbt.Options, anyerror }{
        .{ &.{99}, .java, error.InvalidTag },
        .{ &.{ 9, 0, 0, 0, 0, 0, 0, 1 }, .java, error.InvalidListType },
        .{ &.{ 9, 0, 0, 13, 0, 0, 0, 0 }, .java, error.InvalidTag },
        .{ &.{ 7, 0, 0, 0xff, 0xff, 0xff, 0xff }, .java, error.InvalidLength },
        .{ &.{ 3, 0, 0xff, 0xff, 0xff, 0xff, 0x1f }, .bedrock_network, error.VarIntOverflow },
        .{ &.{ 8, 0, 1, 0xc0 }, .java, error.InvalidModifiedUtf8 },
        .{ &.{ 8, 0, 0, 1, 0, 0xff }, .bedrock, error.InvalidUtf8 },
        .{ &.{ 11, 0, 0, 0x00, 0x0f, 0x42, 0x40 }, .java, error.UnexpectedEndOfInput },
        .{ &.{ 9, 0, 1, 0x80, 0x89, 0x7a }, .bedrock_network, error.UnexpectedEndOfInput },
        .{ &.{ 8, 0, 0xff, 0xff, 0xff, 0xff, 0x0f }, .bedrock_network, error.SizeLimitExceeded },
        .{ &.{ 10, 0, 0, 3, 0, 0, 0 }, .java, error.UnexpectedEndOfInput },
    };
    for (cases) |case| {
        try testing.expectError(case[2], nbt.scanDocument(case[0], case[1]));
        try testing.expectError(case[2], nbt.parse(testing.allocator, case[0], case[1]));
    }

    var shallow: nbt.Options = .java;
    shallow.max_depth = 1;
    try testing.expectError(error.DepthLimitExceeded, nbt.scanDocument(&.{ 9, 0, 0, 9, 0, 0, 0, 1, 1, 0, 0, 0, 0 }, shallow));
    shallow.max_depth = 2;
    try testing.expectEqual(@as(usize, 13), try nbt.scanDocument(&.{ 9, 0, 0, 9, 0, 0, 0, 1, 1, 0, 0, 0, 0 }, shallow));
}

test "the deepest allowed nesting scans and one more level does not" {
    const allocator = testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    for (0..nbt.Options.max_supported_depth) |_| try wire.appendSlice(allocator, &.{ 10, 0, 0 });
    try wire.appendNTimes(allocator, 0, nbt.Options.max_supported_depth);

    try testing.expectEqual(wire.items.len, try nbt.scanDocument(wire.items, .java));
    var shallow: nbt.Options = .java;
    shallow.max_depth = nbt.Options.max_supported_depth - 1;
    try testing.expectError(error.DepthLimitExceeded, nbt.scanDocument(wire.items, shallow));

    try wire.insertSlice(allocator, 0, &.{ 10, 0, 0 });
    try wire.append(allocator, 0);
    try testing.expectError(error.DepthLimitExceeded, nbt.scanDocument(wire.items, .java));

    // Lists of lists nest without a compound in between.
    var lists: std.ArrayList(u8) = .empty;
    defer lists.deinit(allocator);
    try lists.appendSlice(allocator, &.{ 9, 0, 0 });
    for (0..nbt.Options.max_supported_depth - 2) |_| try lists.appendSlice(allocator, &.{ 9, 0, 0, 0, 1 });
    try lists.appendSlice(allocator, &.{ 1, 0, 0, 0, 0 });
    try testing.expectEqual(lists.items.len, try nbt.scanDocument(lists.items, .java));
    var parsed = try nbt.parse(allocator, lists.items, .java);
    parsed.deinit(allocator);
}

test "deep scans fit in a small thread stack" {
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, deepScan, .{&result});
    thread.join();
    try result;
}

fn deepScan(result: *anyerror!void) void {
    var wire: [nbt.Options.max_supported_depth * 4]u8 = undefined;
    for (0..nbt.Options.max_supported_depth) |index| wire[index * 3 ..][0..3].* = .{ 10, 0, 0 };
    @memset(wire[nbt.Options.max_supported_depth * 3 ..], 0);
    result.* = if (nbt.scanDocument(&wire, .java)) |len| (if (len == wire.len) {} else error.WrongLength) else |err| err;
}

test "max_input_bytes caps how far scans and prefix parses read" {
    const allocator = testing.allocator;
    const bytes = fixtures.documents[0].bytes;
    var options = fixtures.documents[0].options;

    const padded = try std.mem.concat(allocator, u8, &.{ bytes, &.{ 0xaa, 0xbb } });
    defer allocator.free(padded);

    options.max_input_bytes = bytes.len;
    try testing.expectEqual(bytes.len, try nbt.scanDocument(padded, options));
    var parsed = try nbt.parsePrefix(allocator, padded, options);
    parsed.document.deinit(allocator);

    options.max_input_bytes = bytes.len - 1;
    try testing.expectError(error.SizeLimitExceeded, nbt.scanDocument(padded, options));
    try testing.expectError(error.SizeLimitExceeded, nbt.parsePrefix(allocator, padded, options));
    try testing.expectError(error.UnexpectedEndOfInput, nbt.scanDocument(bytes[0 .. bytes.len - 1], options));
}

test "noncanonical varints are rejected only when asked" {
    const allocator = testing.allocator;
    const cases = [_][]const u8{
        &.{ 3, 0x80, 0, 0x80, 0 },
        &.{ 4, 0, 0x81, 0x80, 0 },
        &.{ 7, 0, 0x80, 0 },
        &.{ 3, 0, 0x80, 0x80, 0x80, 0x80, 0 },
    };
    var strict: nbt.Options = .bedrock_network;
    strict.reject_noncanonical_varints = true;

    for (cases) |wire| {
        try testing.expectEqual(wire.len, try nbt.scanDocument(wire, .bedrock_network));
        var parsed = try nbt.parse(allocator, wire, .bedrock_network);
        parsed.deinit(allocator);

        try testing.expectError(error.NonCanonicalVarInt, nbt.scanDocument(wire, strict));
        try testing.expectError(error.NonCanonicalVarInt, nbt.parse(allocator, wire, strict));
    }

    try testing.expectEqual(@as(usize, 7), try nbt.scanDocument(&.{ 3, 0, 0xff, 0xff, 0xff, 0xff, 0x0f }, strict));
}

test "raw strings keep their exact bytes" {
    const allocator = testing.allocator;
    var raw: nbt.Options = .bedrock;
    raw.raw_strings = true;

    const invalid = [_]u8{ 8, 0, 0, 3, 0, 0xff, 0xc0, 0x80 };
    try testing.expectError(error.InvalidUtf8, nbt.parse(allocator, &invalid, .bedrock));
    try testing.expectEqual(invalid.len, try nbt.scanDocument(&invalid, raw));

    var parsed = try nbt.parse(allocator, &invalid, raw);
    defer parsed.deinit(allocator);
    try testing.expectEqualSlices(u8, invalid[5..], parsed.root.string);

    const bytes = try nbt.serialize(allocator, parsed, raw);
    defer allocator.free(bytes);
    try testing.expectEqualSlices(u8, &invalid, bytes);

    var java_raw: nbt.Options = .java;
    java_raw.raw_strings = true;
    const java_bytes = try nbt.serialize(allocator, parsed, java_raw);
    defer allocator.free(java_bytes);
    try testing.expectEqualSlices(u8, &.{ 8, 0, 0, 0, 3, 0xff, 0xc0, 0x80 }, java_bytes);
    try testing.expectEqual(java_bytes.len, try nbt.encodedLength(parsed, java_raw));
}

test "keep_first drops later duplicate names without leaking" {
    const allocator = testing.allocator;
    for ([_]usize{ 6, 40 }) |count| {
        const distinct = count / 2;
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(allocator);
        try wire.appendSlice(allocator, &.{ 10, 0, 0 });
        for (0..count) |index| {
            try wire.appendSlice(allocator, &.{ 8, 0, 2, 'k', @intCast('a' + index % distinct) });
            try wire.appendSlice(allocator, &.{ 0, 1, @intCast('0' + index / distinct) });
        }
        try wire.append(allocator, 0);

        try testing.expectError(error.DuplicateName, nbt.parse(allocator, wire.items, .java));
        try testing.expectEqual(wire.items.len, try nbt.scanDocument(wire.items, .java));

        var lenient: nbt.Options = .java;
        lenient.duplicate_names = .keep_first;
        var parsed = try nbt.parse(allocator, wire.items, lenient);
        defer parsed.deinit(allocator);

        try testing.expectEqual(distinct, parsed.root.compound.entries.len);
        for (parsed.root.compound.entries) |entry| try testing.expectEqualStrings("0", entry.value.string);

        var backing = testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
        try testing.checkAllAllocationFailures(backing.allocator(), keepFirstScenario, .{ wire.items, lenient });
    }
}

fn keepFirstScenario(allocator: std.mem.Allocator, wire: []const u8, options: nbt.Options) !void {
    var parsed = try nbt.parse(allocator, wire, options);
    parsed.deinit(allocator);
}

test "byte array limit applies to scans, parses and serialization" {
    const allocator = testing.allocator;
    var document = try nbt.Document.init(allocator, "", try nbt.builder.byteArray(allocator, &.{ 1, 2, 3, 4 }));
    defer document.deinit(allocator);

    for (encodings) |preset| {
        var options = preset;
        const bytes = try nbt.serialize(allocator, document, options);
        defer allocator.free(bytes);

        options.max_byte_array_length = 4;
        try testing.expectEqual(bytes.len, try nbt.scanDocument(bytes, options));

        options.max_byte_array_length = 3;
        try testing.expectError(error.SizeLimitExceeded, nbt.scanDocument(bytes, options));
        try testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, bytes, options));
        try testing.expectError(error.SizeLimitExceeded, nbt.serialize(allocator, document, options));
    }
}

test "encoded length is exact for awkward varints and strings" {
    const allocator = testing.allocator;
    const values = [_]nbt.Tag{
        .{ .int = 0 },                     .{ .int = -1 },                    .{ .int = 63 },
        .{ .int = 64 },                    .{ .int = std.math.minInt(i32) },  .{ .int = std.math.maxInt(i32) },
        .{ .long = std.math.minInt(i64) }, .{ .long = std.math.maxInt(i64) }, .{ .long = 1 << 40 },
    };
    for (values) |value| {
        for (encodings) |options| {
            const bytes = try nbt.serializePayload(allocator, value, options);
            defer allocator.free(bytes);
            try testing.expectEqual(bytes.len, try nbt.encodedLength(value, options));
        }
    }

    const text = try allocator.alloc(u8, 200);
    defer allocator.free(text);
    @memset(text, 'x');
    var long_name = try nbt.Document.init(allocator, text, try nbt.builder.string(allocator, "\x00😀"));
    defer long_name.deinit(allocator);
    for (encodings) |options| {
        const bytes = try nbt.serialize(allocator, long_name, options);
        defer allocator.free(bytes);
        try testing.expectEqual(bytes.len, try nbt.encodedLength(long_name, options));
    }
}

test "random and mutated input never makes the scanner disagree with the decoder" {
    const allocator = testing.allocator;
    var document = try sampleDocument(allocator);
    defer document.deinit(allocator);

    var seeds: [encodings.len][]u8 = undefined;
    var initialized: usize = 0;
    defer for (seeds[0..initialized]) |seed| allocator.free(seed);
    for (&seeds, encodings) |*seed, options| {
        seed.* = try nbt.serialize(allocator, document, options);
        initialized += 1;
    }

    var prng: std.Random.DefaultPrng = .init(0x5ca1ab1e);
    const random = prng.random();
    var buffer: [2048]u8 = undefined;

    for (0..20_000) |iteration| {
        const which = random.uintLessThan(usize, encodings.len);
        var options = encodings[which];
        options.max_depth = 16;
        options.max_total_decoded_bytes = std.math.maxInt(usize);
        options.reject_noncanonical_varints = random.boolean();

        const seed = seeds[which];
        const len = @min(seed.len, buffer.len);
        @memcpy(buffer[0..len], seed[0..len]);
        for (0..random.uintLessThan(usize, 4) + 1) |_| buffer[random.uintLessThan(usize, len)] ^= random.int(u8);
        const input = if (iteration % 5 == 0) buffer[0..random.uintLessThan(usize, len + 1)] else buffer[0..len];

        try expectAgreement(allocator, input, options);
    }
}

pub fn expectAgreement(allocator: std.mem.Allocator, input: []const u8, options: nbt.Options) !void {
    const scanned = nbt.scanDocument(input, options);
    if (nbt.parsePrefix(allocator, input, options)) |parsed_value| {
        var parsed = parsed_value;
        defer parsed.document.deinit(allocator);
        try testing.expectEqual(parsed.len, try scanned);
    } else |err| switch (err) {
        // Only the decoder looks for duplicate names or runs out of memory.
        error.DuplicateName, error.OutOfMemory => {},
        else => try testing.expectError(err, scanned),
    }
}

test "network varint arrays of mixed widths round trip, scan and reject truncation" {
    const allocator = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x7a7a);
    const random = prng.random();

    for ([_]usize{ 0, 1, 15, 16, 17, 31, 33, 100, 1000 }) |len| {
        for (0..4) |pattern| {
            const ints = try allocator.alloc(i32, len);
            defer allocator.free(ints);
            const longs = try allocator.alloc(i64, len);
            defer allocator.free(longs);

            for (ints, longs, 0..) |*int, *long, index| {
                const small = random.intRangeAtMost(i32, -64, 63);
                int.* = switch (pattern) {
                    0 => small,
                    1 => if (index % 17 == 3) random.int(i32) else small,
                    2 => random.int(i32),
                    else => if (index % 2 == 0) std.math.minInt(i32) else small,
                };
                long.* = if (pattern == 0) small else random.int(i64);
            }

            var root = nbt.builder.Compound.init(allocator);
            defer root.deinit();
            try addOwned(&root, "ints", try nbt.builder.intArray(allocator, ints));
            try addOwned(&root, "longs", try nbt.builder.longArray(allocator, longs));
            var tag = try root.finish();
            var document = nbt.Document.init(allocator, "", tag) catch |err| {
                tag.deinit(allocator);
                return err;
            };
            defer document.deinit(allocator);

            for (encodings) |options| {
                const bytes = try nbt.serialize(allocator, document, options);
                defer allocator.free(bytes);
                try testing.expectEqual(bytes.len, try nbt.encodedLength(document, options));
                try testing.expectEqual(bytes.len, try nbt.scanDocument(bytes, options));

                var parsed = try nbt.parse(allocator, bytes, options);
                defer parsed.deinit(allocator);
                try testing.expect(document.eql(parsed));

                var buffer: [16 * 1024]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buffer);
                try nbt.writeDocument(allocator, &writer, document, options);
                try testing.expectEqualSlices(u8, bytes, writer.buffered());

                if (len <= 33) for (0..bytes.len) |end| {
                    try testing.expectError(error.UnexpectedEndOfInput, nbt.scanDocument(bytes[0..end], options));
                    try testing.expectError(error.UnexpectedEndOfInput, nbt.parse(allocator, bytes[0..end], options));
                };
            }
        }
    }
}
