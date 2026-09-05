const std = @import("std");
const nbt = @import("nbt");
const config = @import("config");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    var prng: std.Random.DefaultPrng = .init(0x4e42545a4947);
    var random = prng.random();
    var bytes: [4096]u8 = undefined;

    for (0..config.iterations) |_| {
        const len = random.uintLessThan(usize, bytes.len + 1);
        random.bytes(bytes[0..len]);
        var options: nbt.Options = switch (random.enumValue(nbt.Encoding)) {
            .java => .java,
            .bedrock => .bedrock,
            .bedrock_network => .bedrock_network,
        };
        options.max_depth = 32;
        options.max_collection_length = 1024;
        options.max_compound_entries = 1024;
        options.max_string_bytes = 1024;
        options.max_input_bytes = bytes.len;
        options.max_total_decoded_bytes = 64 * 1024;

        if (nbt.parse(allocator, bytes[0..len], options)) |document_value| {
            var document = document_value;
            document.deinit(allocator);
        } else |_| {}
    }
}
