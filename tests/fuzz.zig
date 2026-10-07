const std = @import("std");
const nbt = @import("nbt");
const config = @import("config");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    var corpus: [9][]u8 = undefined;
    var initialized: usize = 0;
    defer for (corpus[0..initialized]) |seed| allocator.free(seed);
    for (&corpus, 0..) |*seed, index| {
        seed.* = try makeSeed(allocator, caseOptions(index));
        initialized += 1;
    }

    var prng: std.Random.DefaultPrng = .init(0x4e42545a4947);
    var random = prng.random();
    var bytes: [4096]u8 = undefined;

    for (0..config.iterations) |index| {
        const variant = random.uintLessThan(usize, corpus.len);
        var options = caseOptions(variant);
        var len: usize = undefined;
        if (index % 4 == 0) {
            len = random.uintLessThan(usize, bytes.len + 1);
            random.bytes(bytes[0..len]);
        } else {
            const seed = corpus[variant];
            @memcpy(bytes[0..seed.len], seed);
            len = seed.len;
            if (index % 4 == 1) {
                for (0..random.uintLessThan(usize, 4) + 1) |_| {
                    bytes[random.uintLessThan(usize, len)] ^= random.int(u8);
                }
            } else if (index % 4 == 2) {
                len = random.uintLessThan(usize, len + 1);
            }
        }
        options.max_depth = 32;
        options.max_collection_length = 1024;
        options.max_compound_entries = 1024;
        options.max_string_bytes = 1024;
        options.max_input_bytes = bytes.len;
        options.max_decompressed_bytes = 64 * 1024;
        options.max_output_bytes = 64 * 1024;
        options.max_total_decoded_bytes = 64 * 1024;
        options.reject_trailing_bytes = true;

        if (nbt.parse(allocator, bytes[0..len], options)) |document_value| {
            var document = document_value;
            defer document.deinit(allocator);
            const encoded = try nbt.serialize(allocator, document, options);
            defer allocator.free(encoded);
            var reparsed = try nbt.parse(allocator, encoded, options);
            defer reparsed.deinit(allocator);
            if (!document.eql(reparsed)) return error.RoundTripMismatch;
        } else |_| {}
    }
}

fn caseOptions(index: usize) nbt.Options {
    return .{
        .encoding = switch (index / 3) {
            0 => .java,
            1 => .bedrock,
            else => .bedrock_network,
        },
        .compression = switch (index % 3) {
            0 => .none,
            1 => .gzip,
            else => .zlib,
        },
    };
}

fn makeSeed(allocator: std.mem.Allocator, options: nbt.Options) ![]u8 {
    const wire: []const u8 = switch (options.encoding) {
        .java => &.{ 9, 0, 0, 10, 0, 0, 0, 1, 7, 0, 1, 'b', 0, 0, 0, 4, 0, 1, 2, 3, 0 },
        .bedrock => &.{ 9, 0, 0, 10, 1, 0, 0, 0, 7, 1, 0, 'b', 4, 0, 0, 0, 0, 1, 2, 3, 0 },
        .bedrock_network => &.{ 9, 0, 10, 2, 7, 1, 'b', 8, 0, 1, 2, 3, 0 },
    };
    var plain_options = options;
    plain_options.compression = .none;
    var document = try nbt.parse(allocator, wire, plain_options);
    defer document.deinit(allocator);
    return nbt.serialize(allocator, document, options);
}
