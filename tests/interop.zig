const std = @import("std");
const nbt = @import("nbt");
const fixtures = @import("fixtures");

test "depth rejection precedes child allocation" {
    const inputs = [_][]const u8{
        &.{ 9, 0, 0, 1, 0, 0, 0, 2, 7, 8 },
        &.{ 10, 0, 0, 8, 0, 1, 'x', 0, 1, 'a', 0 },
    };
    for (inputs) |input| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var options: nbt.Options = .java;
        options.max_depth = 1;
        try std.testing.expectError(error.DepthLimitExceeded, nbt.parse(failing.allocator(), input, options));
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    }
}

test "duplicate detection crosses the small compound threshold" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 1, 15, 16, 17, 32, 65 }) |count| {
        var builder = nbt.builder.Compound.init(allocator);
        defer builder.deinit();
        for (0..count) |index| {
            var name: [20]u8 = undefined;
            try builder.add(try std.fmt.bufPrint(&name, "field{d}", .{index}), .{ .byte = 7 });
        }
        var root = try builder.finish();
        var document = nbt.Document.init(allocator, "", root) catch |err| {
            root.deinit(allocator);
            return err;
        };
        defer document.deinit(allocator);
        var shallow: nbt.Options = .bedrock;
        shallow.max_depth = 1;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        var shallow_buffer: [4096]u8 = undefined;
        var shallow_writer: std.Io.Writer = .fixed(&shallow_buffer);
        try std.testing.expectError(error.DepthLimitExceeded, nbt.writeDocument(failing.allocator(), &shallow_writer, document, shallow));
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        const encoded = try nbt.serialize(allocator, document, .bedrock);
        defer allocator.free(encoded);
        var parsed = try nbt.parse(allocator, encoded, .bedrock);
        defer parsed.deinit(allocator);
        try std.testing.expect(document.eql(parsed));
        if (count == 17 or count == 65) {
            var backing = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
            try std.testing.checkAllAllocationFailures(backing.allocator(), fixtureAllocationScenario, .{
                fixtures.Fixture{ .name = "indexed-compound", .bytes = encoded, .options = .bedrock },
            });
        }
        // Append a duplicate of the first name immediately before TAG_End.
        const duplicate = try std.mem.concat(allocator, u8, &.{ encoded[0 .. encoded.len - 1], &.{ 1, 6, 0 }, "field0", &.{ 8, 0 } });
        defer allocator.free(duplicate);
        try std.testing.expectError(error.DuplicateName, nbt.parse(allocator, duplicate, .bedrock));
        if (count > 1) {
            const last = &document.root.compound.entries[count - 1];
            const original = last.name;
            last.name = document.root.compound.entries[0].name;
            defer last.name = original;
            try std.testing.expectError(error.DuplicateName, nbt.serialize(allocator, document, .bedrock));
            var buffer: [4096]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try std.testing.expectError(error.DuplicateName, nbt.writeDocument(allocator, &writer, document, .bedrock));
        }
    }
}

test "realistic trees roll back every allocation failure" {
    for (fixtures.documents ++ fixtures.compressed) |fixture| {
        var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        try std.testing.checkAllAllocationFailures(backing.allocator(), fixtureAllocationScenario, .{fixture});
    }
}

fn fixtureAllocationScenario(allocator: std.mem.Allocator, fixture: fixtures.Fixture) !void {
    var reader: std.Io.Reader = .fixed(fixture.bytes);
    var document = try nbt.parseReader(allocator, &reader, fixture.options);
    defer document.deinit(allocator);
    const encoded = try nbt.serialize(allocator, document, fixture.options);
    defer allocator.free(encoded);
    const buffer = try allocator.alloc(u8, encoded.len);
    defer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    try nbt.writeDocument(allocator, &writer, document, fixture.options);
    try std.testing.expectEqualSlices(u8, encoded, writer.buffered());
}

test "growing builders preserve every owned value on failure" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), growingBuilderScenario, .{});
}

fn growingBuilderScenario(allocator: std.mem.Allocator) !void {
    var compound = nbt.builder.Compound.init(allocator);
    defer compound.deinit();
    for (0..32) |index| {
        var list = nbt.builder.List.init(allocator, .string);
        defer list.deinit();
        for (0..16) |_| {
            var text = try nbt.builder.string(allocator, "owned \u{1f30d}");
            list.append(text) catch |err| {
                text.deinit(allocator);
                return err;
            };
        }
        var value = try list.finish();
        var name: [20]u8 = undefined;
        compound.add(try std.fmt.bufPrint(&name, "field{d}", .{index}), value) catch |err| {
            value.deinit(allocator);
            return err;
        };
    }
    var bytes = try nbt.builder.byteArray(allocator, &.{ 0, 1, 2 });
    defer bytes.deinit(allocator);
    var ints = try nbt.builder.intArray(allocator, &.{ -1, std.math.maxInt(i32) });
    defer ints.deinit(allocator);
    var longs = try nbt.builder.longArray(allocator, &.{ std.math.minInt(i64), std.math.maxInt(i64) });
    defer longs.deinit(allocator);
    var root = try compound.finish();
    var owned = true;
    defer if (owned) root.deinit(allocator);
    var document = try nbt.Document.init(allocator, "growing", root);
    owned = false;
    defer document.deinit(allocator);
}

test "collection string compound and decoded budgets have exact boundaries" {
    const allocator = std.testing.allocator;
    for ([_]nbt.TagType{ .byte_array, .int_array, .long_array, .list, .compound, .string }) |tag_type| {
        var root = switch (tag_type) {
            .byte_array => try nbt.builder.byteArray(allocator, &.{ 0, 1, 2 }),
            .int_array => try nbt.builder.intArray(allocator, &.{ -1, 0, std.math.maxInt(i32) }),
            .long_array => try nbt.builder.longArray(allocator, &.{ std.math.minInt(i64), 0, std.math.maxInt(i64) }),
            .string => try nbt.builder.string(allocator, "\x00\u{1f30d}"),
            .list => blk: {
                var list = nbt.builder.List.init(allocator, .byte);
                defer list.deinit();
                for (0..3) |_| try list.append(.{ .byte = 7 });
                break :blk try list.finish();
            },
            .compound => blk: {
                var compound = nbt.builder.Compound.init(allocator);
                defer compound.deinit();
                for ([_][]const u8{ "a", "b", "c" }) |name| try compound.add(name, .{ .byte = 7 });
                break :blk try compound.finish();
            },
            else => unreachable,
        };
        var document = nbt.Document.init(allocator, "", root) catch |err| {
            root.deinit(allocator);
            return err;
        };
        defer document.deinit(allocator);
        for ([_]nbt.Options{ .java, .bedrock, .bedrock_network }) |preset| {
            var options = preset;
            options.max_collection_length = 3;
            options.max_compound_entries = 3;
            options.max_string_bytes = if (preset.encoding == .java) 8 else 5;
            const encoded = try nbt.serialize(allocator, document, options);
            defer allocator.free(encoded);
            var parsed = try nbt.parse(allocator, encoded, options);
            defer parsed.deinit(allocator);
            try std.testing.expect(document.eql(parsed));
            var writer_buffer: [256]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&writer_buffer);
            try nbt.writeDocument(allocator, &writer, document, options);
            try std.testing.expectEqualSlices(u8, encoded, writer.buffered());
            if (tag_type == .string) {
                options.max_string_bytes -= 1;
            } else {
                options.max_collection_length -= 1;
            }
            try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, encoded, options));
            try std.testing.expectError(error.SizeLimitExceeded, nbt.serialize(allocator, document, options));
            writer = .fixed(&writer_buffer);
            try std.testing.expectError(error.SizeLimitExceeded, nbt.writeDocument(allocator, &writer, document, options));
            if (tag_type == .compound) {
                options.max_collection_length = 3;
                options.max_compound_entries = 2;
                try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, encoded, options));
                try std.testing.expectError(error.SizeLimitExceeded, nbt.serialize(allocator, document, options));
                writer = .fixed(&writer_buffer);
                try std.testing.expectError(error.SizeLimitExceeded, nbt.writeDocument(allocator, &writer, document, options));
            }
        }
    }
    const wire = &[_]u8{ 11, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2 };
    var options: nbt.Options = .java;
    options.max_total_decoded_bytes = 8;
    var parsed = try nbt.parse(allocator, wire, options);
    parsed.deinit(allocator);
    options.max_total_decoded_bytes -= 1;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(failing.allocator(), wire, options));
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "invalid options and oversized reader input reject before allocation" {
    const fields = .{ "max_depth", "max_input_bytes", "max_decompressed_bytes", "max_output_bytes", "max_total_decoded_bytes" };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const input = &[_]u8{ 1, 0, 0, 7 };
    var document = try nbt.parse(std.testing.allocator, input, .java);
    defer document.deinit(std.testing.allocator);
    inline for (fields) |field| {
        var options: nbt.Options = .java;
        @field(options, field) = 0;
        try std.testing.expectError(error.InvalidOptions, nbt.parse(failing.allocator(), input, options));
        try std.testing.expectError(error.InvalidOptions, nbt.serialize(failing.allocator(), document, options));
        var buffer: [4]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectError(error.InvalidOptions, nbt.writeDocument(failing.allocator(), &writer, document, options));
    }
    var options: nbt.Options = .java;
    options.max_depth = 513;
    try std.testing.expectError(error.InvalidOptions, nbt.parse(failing.allocator(), input, options));
    options.max_depth = 512;
    options.max_input_bytes = input.len - 1;
    var reader: std.Io.Reader = .fixed(input);
    try std.testing.expectError(error.SizeLimitExceeded, nbt.parseReader(failing.allocator(), &reader, options));
    options.max_input_bytes = input.len;
    var short_buffer: [3]u8 = undefined;
    var short_writer: std.Io.Writer = .fixed(&short_buffer);
    try std.testing.expectError(error.WriteFailed, nbt.writeDocument(failing.allocator(), &short_writer, document, options));
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "fixed arrays preserve partial final batches and signed extrema" {
    const allocator = std.testing.allocator;
    inline for (.{ i32, i64 }) |T| {
        for ([_]usize{ 0, 1, 31, 32, 33, 63, 64, 65, 257 }) |count| {
            for ([_]nbt.Options{ .java, .bedrock }) |options| {
                const wire = try allocator.alloc(u8, 7 + count * @sizeOf(T));
                defer allocator.free(wire);
                @memset(wire, 0);
                wire[0] = if (T == i32) 11 else 12;
                const big = options.encoding == .java;
                wire[if (big) 5 else 4] = @truncate(count >> 8);
                wire[if (big) 6 else 3] = @truncate(count);
                if (count != 0) wire[7 + (count - 1) * @sizeOf(T) + (if (big) @as(usize, 0) else @sizeOf(T) - 1)] = 0x80;
                var document = try nbt.parse(allocator, wire, options);
                defer document.deinit(allocator);
                if (count != 0) {
                    const values = if (T == i32) document.root.int_array else document.root.long_array;
                    try std.testing.expectEqual(std.math.minInt(T), values[count - 1]);
                }
                const encoded = try nbt.serialize(allocator, document, options);
                defer allocator.free(encoded);
                try std.testing.expectEqualSlices(u8, wire, encoded);
                const output = try allocator.alloc(u8, wire.len);
                defer allocator.free(output);
                var writer: std.Io.Writer = .fixed(output);
                try nbt.writeDocument(allocator, &writer, document, options);
                try std.testing.expectEqualSlices(u8, wire, writer.buffered());
            }
        }
    }
}

test "independent Minecraft-shaped fixtures are canonical owned trees" {
    const allocator = std.testing.allocator;
    for (fixtures.documents) |fixture| {
        var options = fixture.options;
        options.reject_trailing_bytes = true;
        const input = try allocator.dupe(u8, fixture.bytes);
        defer allocator.free(input);
        var parsed = try nbt.parse(allocator, input, options);
        defer parsed.deinit(allocator);
        @memset(input, 0xdd);
        const serialized = try nbt.serialize(allocator, parsed, options);
        defer allocator.free(serialized);
        try std.testing.expectEqualSlices(u8, fixture.bytes, serialized);
        var reparsed = try nbt.parse(allocator, serialized, options);
        defer reparsed.deinit(allocator);
        try std.testing.expect(parsed.eql(reparsed));
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try nbt.writeDocument(allocator, &output.writer, parsed, options);
        try std.testing.expectEqualSlices(u8, fixture.bytes, output.written());
        for (0..fixture.bytes.len) |end| {
            if (nbt.parse(allocator, fixture.bytes[0..end], options)) |unexpected_value| {
                var unexpected = unexpected_value;
                unexpected.deinit(allocator);
                return error.TruncatedFixtureAccepted;
            } else |_| {}
        }
    }
}

test "fixture values match Minecraft field semantics" {
    const allocator = std.testing.allocator;
    var item = try nbt.parse(allocator, fixtures.documents[0].bytes, .bedrock);
    defer item.deinit(allocator);
    try std.testing.expectEqualStrings("minecraft:diamond_sword", item.root.compound.get("Name").?.string);
    try std.testing.expectEqual(@as(i16, 17), item.root.compound.get("Damage").?.short);
    try std.testing.expectEqualStrings("\u{a7}bBlade \u{1f30d}", item.root.compound.get("tag").?.compound.get("display").?.compound.get("Name").?.string);
    inline for (.{ @as(usize, 1), @as(usize, 3) }) |index| {
        const fixture = fixtures.documents[index];
        var entity = try nbt.parse(allocator, fixture.bytes, fixture.options);
        defer entity.deinit(allocator);
        try std.testing.expectEqual(@as(i64, -9_876_543_210), entity.root.compound.get("UniqueID").?.long);
        try std.testing.expectEqual(@as(f32, -456.25), entity.root.compound.get("Pos").?.list.items[2].float);
        try std.testing.expectEqual(@as(usize, 9), entity.root.compound.get("Inventory").?.list.items.len);
    }
    var structure = try nbt.parse(allocator, fixtures.documents[2].bytes, .bedrock);
    defer structure.deinit(allocator);
    const indices = structure.root.compound.get("structure").?.compound.get("block_indices").?.list;
    try std.testing.expectEqual(@as(usize, 4096), indices.items[0].int_array.len);
    try std.testing.expectEqual(@as(i32, -1), indices.items[1].int_array[4095]);
    var java = try nbt.parse(allocator, fixtures.documents[4].bytes, .java);
    defer java.deinit(allocator);
    try std.testing.expectEqualStrings("World \x00 \u{1f30d}", java.root.compound.get("LevelName").?.string);
    const longs = java.root.compound.get("PackedStates").?.long_array;
    try std.testing.expectEqual(@as(usize, 1024), longs.len);
    try std.testing.expectEqual(std.math.minInt(i64), longs[0]);
    try std.testing.expectEqual(std.math.maxInt(i64), longs[1]);
    try std.testing.expectEqual(@as(usize, 4096), java.root.compound.get("Sections").?.list.items[0].compound.get("Blocks").?.byte_array.len);
}

test "Python gzip and zlib interoperate across deflate block types" {
    const allocator = std.testing.allocator;
    var expected = try nbt.parse(allocator, fixtures.documents[4].bytes, .java);
    defer expected.deinit(allocator);
    for (fixtures.compressed) |fixture| {
        var options = fixture.options;
        options.reject_trailing_bytes = true;
        var parsed = try nbt.parse(allocator, fixture.bytes, options);
        defer parsed.deinit(allocator);
        try std.testing.expect(expected.eql(parsed));
        const serialized = try nbt.serialize(allocator, parsed, options);
        defer allocator.free(serialized);
        var reparsed = try nbt.parse(allocator, serialized, options);
        defer reparsed.deinit(allocator);
        try std.testing.expect(parsed.eql(reparsed));
        for (0..fixture.bytes.len) |end| {
            if (nbt.parse(allocator, fixture.bytes[0..end], options)) |unexpected_value| {
                var unexpected = unexpected_value;
                unexpected.deinit(allocator);
                return error.TruncatedCompressedFixtureAccepted;
            } else |_| {}
        }
    }
}

test "strict compression rejects concatenated members and arbitrary trailing bytes" {
    const allocator = std.testing.allocator;
    const garbage: [257]u8 = @splat(0xaa);
    for (fixtures.compressed) |fixture| {
        for ([_][]const u8{ &.{0xaa}, &garbage, fixture.bytes }) |suffix| {
            const input = try std.mem.concat(allocator, u8, &.{ fixture.bytes, suffix });
            defer allocator.free(input);
            var options = fixture.options;
            var permissive = try nbt.parse(allocator, input, options);
            permissive.deinit(allocator);
            options.reject_trailing_bytes = true;
            try std.testing.expectError(error.TrailingData, nbt.parse(allocator, input, options));
        }
    }
}

test "external compression corruption is rejected" {
    const allocator = std.testing.allocator;
    for (fixtures.compressed) |fixture| {
        const input = try allocator.dupe(u8, fixture.bytes);
        defer allocator.free(input);
        inline for (.{ @as(usize, 0), @as(usize, 1) }) |index| {
            input[index] ^= 1;
            defer input[index] ^= 1;
            try std.testing.expectError(error.MalformedCompressedData, nbt.parse(allocator, input, fixture.options));
        }
        const footer_len: usize = if (fixture.options.compression == .gzip) 8 else 4;
        for (input.len - footer_len..input.len) |index| {
            input[index] ^= 1;
            defer input[index] ^= 1;
            try std.testing.expectError(error.MalformedCompressedData, nbt.parse(allocator, input, fixture.options));
        }
    }
    const optional = fixtures.compressed[2].bytes;
    const crc_offset = std.mem.indexOf(u8, optional, "Python interoperability\x00").? + "Python interoperability\x00".len;
    const corrupt = try allocator.dupe(u8, optional);
    defer allocator.free(corrupt);
    corrupt[crc_offset] ^= 1;
    try std.testing.expectError(error.MalformedCompressedData, nbt.parse(allocator, corrupt, fixtures.compressed[2].options));
}

test "external fixtures enforce exact input decompressed and output boundaries" {
    const allocator = std.testing.allocator;
    for (fixtures.compressed) |fixture| {
        var options = fixture.options;
        options.reject_trailing_bytes = true;
        options.max_input_bytes = fixture.bytes.len;
        options.max_decompressed_bytes = fixtures.documents[4].bytes.len;
        var parsed = try nbt.parse(allocator, fixture.bytes, options);
        defer parsed.deinit(allocator);
        options.max_input_bytes -= 1;
        try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, fixture.bytes, options));
        options.max_input_bytes += 1;
        options.max_decompressed_bytes -= 1;
        try std.testing.expectError(error.SizeLimitExceeded, nbt.parse(allocator, fixture.bytes, options));
    }
    for (fixtures.documents) |fixture| {
        var options = fixture.options;
        options.max_input_bytes = fixture.bytes.len;
        options.max_output_bytes = fixture.bytes.len;
        var parsed = try nbt.parse(allocator, fixture.bytes, options);
        defer parsed.deinit(allocator);
        const serialized = try nbt.serialize(allocator, parsed, options);
        defer allocator.free(serialized);
        options.max_output_bytes -= 1;
        try std.testing.expectError(error.SizeLimitExceeded, nbt.serialize(allocator, parsed, options));
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try std.testing.expectError(error.SizeLimitExceeded, nbt.writeDocument(allocator, &output.writer, parsed, options));
        try std.testing.expect(output.written().len <= options.max_output_bytes);
    }
}

test "compressed output includes its footer in the exact byte budget" {
    const allocator = std.testing.allocator;
    var document = try nbt.Document.init(allocator, "", .{ .byte = 7 });
    defer document.deinit(allocator);
    for ([_]nbt.Compression{ .gzip, .zlib }) |kind| {
        var options: nbt.Options = .{ .compression = kind };
        const expected = try nbt.serialize(allocator, document, options);
        defer allocator.free(expected);
        options.max_output_bytes = expected.len;
        var backing = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
        try std.testing.checkAllAllocationFailures(backing.allocator(), fixtureAllocationScenario, .{
            fixtures.Fixture{ .name = "exact-compressed-budget", .bytes = expected, .options = options },
        });
        const exact = try nbt.serialize(allocator, document, options);
        defer allocator.free(exact);
        try std.testing.expectEqualSlices(u8, expected, exact);
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try nbt.writeDocument(allocator, &writer, document, options);
        try std.testing.expectEqualSlices(u8, expected, writer.buffered());
        options.max_output_bytes -= 1;
        try std.testing.expectError(error.SizeLimitExceeded, nbt.serialize(allocator, document, options));
        writer = .fixed(&buffer);
        try std.testing.expectError(error.SizeLimitExceeded, nbt.writeDocument(allocator, &writer, document, options));
        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
}
