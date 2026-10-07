const std = @import("std");
const nbt = @import("nbt");

const sample_count = 7;
const Shape = enum { byte_array, structured, compound };
const Case = struct {
    name: []const u8,
    shape: Shape,
    payload_size: usize,
    iterations: usize,
    options: nbt.Options,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    std.debug.print("nbt benchmark (Zig 0.17, ReleaseFast; median of {d} samples)\n", .{sample_count});
    inline for ([_]Case{
        .{ .name = "bedrock-item", .shape = .compound, .payload_size = 4, .iterations = 2_000, .options = .bedrock },
        .{ .name = "bedrock-entity", .shape = .compound, .payload_size = 64, .iterations = 500, .options = .bedrock },
        .{ .name = "large-compound", .shape = .compound, .payload_size = 4096, .iterations = 10, .options = .bedrock },
        .{ .name = "java-byte-array", .shape = .byte_array, .payload_size = 64 * 1024, .iterations = 200, .options = .java },
        .{ .name = "java-structured-mutf8", .shape = .structured, .payload_size = 128, .iterations = 2_000, .options = .java },
        .{ .name = "bedrock-structured", .shape = .structured, .payload_size = 128, .iterations = 2_000, .options = .bedrock },
        .{ .name = "network-varints", .shape = .structured, .payload_size = 128, .iterations = 2_000, .options = .bedrock_network },
        .{ .name = "gzip-byte-array", .shape = .byte_array, .payload_size = 64 * 1024, .iterations = 100, .options = .{ .compression = .gzip } },
        .{ .name = "zlib-byte-array", .shape = .byte_array, .payload_size = 64 * 1024, .iterations = 100, .options = .{ .compression = .zlib } },
        .{ .name = "large-byte-array", .shape = .byte_array, .payload_size = 4 * 1024 * 1024, .iterations = 10, .options = .java },
    }) |case| try runCase(allocator, init.io, case);
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, case: Case) !void {
    var document = try makeDocument(allocator, case);
    defer document.deinit(allocator);
    const encoded = try nbt.serialize(allocator, document, case.options);
    defer allocator.free(encoded);
    var logical_options = case.options;
    logical_options.compression = .none;
    const logical = try nbt.serialize(allocator, document, logical_options);
    defer allocator.free(logical);

    const warmup_iterations = @max(case.iterations / 20, 1);
    _ = try measureDecode(allocator, io, encoded, case.options, warmup_iterations);
    _ = try measureEncode(allocator, io, document, case.options, warmup_iterations);

    var decode_samples: [sample_count]u64 = undefined;
    var encode_samples: [sample_count]u64 = undefined;
    var write_samples: [sample_count]u64 = undefined;
    const buffer = try allocator.alloc(u8, encoded.len);
    defer allocator.free(buffer);
    for (0..sample_count) |index| {
        decode_samples[index] = try measureDecode(allocator, io, encoded, case.options, case.iterations);
        encode_samples[index] = try measureEncode(allocator, io, document, case.options, case.iterations);
        write_samples[index] = try measureWrite(allocator, io, document, case.options, buffer, case.iterations);
    }
    std.mem.sort(u64, &decode_samples, {}, std.sort.asc(u64));
    std.mem.sort(u64, &encode_samples, {}, std.sort.asc(u64));
    std.mem.sort(u64, &write_samples, {}, std.sort.asc(u64));
    const decode_ns = decode_samples[sample_count / 2];
    const encode_ns = encode_samples[sample_count / 2];
    const write_ns = write_samples[sample_count / 2];
    const total_bytes = logical.len * case.iterations;
    std.debug.print("{s}: decode {d:.2} MiB/s ({d:.1} us/op), encode {d:.2} MiB/s ({d:.1} us/op), write {d:.2} MiB/s ({d:.1} us/op)\n", .{
        case.name,
        throughput(total_bytes, decode_ns),
        microsPerOp(decode_ns, case.iterations),
        throughput(total_bytes, encode_ns),
        microsPerOp(encode_ns, case.iterations),
        throughput(total_bytes, write_ns),
        microsPerOp(write_ns, case.iterations),
    });
    var decode_alloc = std.testing.FailingAllocator.init(allocator, .{});
    var parsed = try nbt.parse(decode_alloc.allocator(), encoded, case.options);
    parsed.deinit(decode_alloc.allocator());
    var encode_alloc = std.testing.FailingAllocator.init(allocator, .{});
    const output = try nbt.serialize(encode_alloc.allocator(), document, case.options);
    encode_alloc.allocator().free(output);
    var write_alloc = std.testing.FailingAllocator.init(allocator, .{});
    var writer: std.Io.Writer = .fixed(buffer);
    try nbt.writeDocument(write_alloc.allocator(), &writer, document, case.options);
    std.debug.print("  allocations / cumulative allocated bytes: decode {d}/{d}, encode {d}/{d}, write {d}/{d}\n", .{
        decode_alloc.allocations, decode_alloc.allocated_bytes,
        encode_alloc.allocations, encode_alloc.allocated_bytes,
        write_alloc.allocations,  write_alloc.allocated_bytes,
    });
}

fn makeDocument(allocator: std.mem.Allocator, case: Case) !nbt.Document {
    if (case.shape == .compound) {
        var compound = nbt.builder.Compound.init(allocator);
        defer compound.deinit();
        for (0..case.payload_size) |index| {
            var name: [32]u8 = undefined;
            try compound.add(try std.fmt.bufPrint(&name, "field{d}", .{index}), .{ .int = @intCast(index) });
        }
        var root = try compound.finish();
        errdefer root.deinit(allocator);
        return nbt.Document.init(allocator, "benchmark", root);
    }
    if (case.shape == .byte_array) {
        const payload = try allocator.alloc(u8, case.payload_size);
        errdefer allocator.free(payload);
        for (payload, 0..) |*byte, i| byte.* = @truncate(i *% 31);
        return nbt.Document.init(allocator, "benchmark", .{ .byte_array = payload });
    }

    const numbers = try allocator.alloc(i32, case.payload_size);
    var numbers_owned = true;
    errdefer if (numbers_owned) allocator.free(numbers);
    for (numbers, 0..) |*number, i| number.* = @intCast(@as(i64, @intCast(i)) * 65_537 - 4_000_000);

    var compound = nbt.builder.Compound.init(allocator);
    defer compound.deinit();
    var message = try nbt.builder.string(allocator, "héllø \x00 Zig 🌍");
    var message_owned = true;
    errdefer if (message_owned) message.deinit(allocator);
    try compound.add("message", message);
    message_owned = false;
    try compound.add("numbers", .{ .int_array = numbers });
    numbers_owned = false;

    var root = try compound.finish();
    var root_owned = true;
    errdefer if (root_owned) root.deinit(allocator);
    const document = try nbt.Document.init(allocator, "structured", root);
    root_owned = false;
    return document;
}

fn measureDecode(
    allocator: std.mem.Allocator,
    io: std.Io,
    encoded: []const u8,
    options: nbt.Options,
    iterations: usize,
) !u64 {
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        var parsed = try nbt.parse(allocator, encoded, options);
        parsed.deinit(allocator);
    }
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}

fn measureEncode(
    allocator: std.mem.Allocator,
    io: std.Io,
    document: nbt.Document,
    options: nbt.Options,
    iterations: usize,
) !u64 {
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        const output = try nbt.serialize(allocator, document, options);
        allocator.free(output);
    }
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}

fn measureWrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    document: nbt.Document,
    options: nbt.Options,
    buffer: []u8,
    iterations: usize,
) !u64 {
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        var writer: std.Io.Writer = .fixed(buffer);
        try nbt.writeDocument(allocator, &writer, document, options);
        std.mem.doNotOptimizeAway(writer.end);
    }
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}

fn throughput(bytes: usize, nanoseconds: u64) f64 {
    if (nanoseconds == 0) return 0;
    return @as(f64, @floatFromInt(bytes)) * 1_000_000_000.0 /
        @as(f64, @floatFromInt(nanoseconds)) / (1024.0 * 1024.0);
}

fn microsPerOp(nanoseconds: u64, iterations: usize) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) /
        @as(f64, @floatFromInt(iterations)) / 1000.0;
}
