const std = @import("std");
const nbt = @import("nbt");
const fixtures = @import("fixtures");

const sample_count = 7;
const Shape = enum { byte_array, structured, compound, fixture, int_list, string_list, palette, nested };
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
    std.debug.print("MiB/s counts uncompressed NBT bytes; arena = decode into a reused ArenaAllocator\n", .{});
    inline for ([_]Case{
        .{ .name = "bedrock-item", .shape = .fixture, .payload_size = 0, .iterations = 2_000, .options = .bedrock },
        .{ .name = "bedrock-entity", .shape = .fixture, .payload_size = 1, .iterations = 500, .options = .bedrock },
        .{ .name = "bedrock-structure", .shape = .fixture, .payload_size = 2, .iterations = 100, .options = .bedrock },
        .{ .name = "network-entity", .shape = .fixture, .payload_size = 3, .iterations = 500, .options = .bedrock_network },
        .{ .name = "java-level", .shape = .fixture, .payload_size = 4, .iterations = 200, .options = .java },
        .{ .name = "compound-4", .shape = .compound, .payload_size = 4, .iterations = 20_000, .options = .bedrock },
        .{ .name = "compound-16", .shape = .compound, .payload_size = 16, .iterations = 10_000, .options = .bedrock },
        .{ .name = "compound-64", .shape = .compound, .payload_size = 64, .iterations = 2_000, .options = .bedrock },
        .{ .name = "large-compound", .shape = .compound, .payload_size = 4096, .iterations = 100, .options = .bedrock },
        .{ .name = "nested-256", .shape = .nested, .payload_size = 256, .iterations = 1_000, .options = .bedrock },
        .{ .name = "palette-1024", .shape = .palette, .payload_size = 1024, .iterations = 100, .options = .bedrock },
        .{ .name = "network-palette-1024", .shape = .palette, .payload_size = 1024, .iterations = 100, .options = .bedrock_network },
        .{ .name = "int-list-64k", .shape = .int_list, .payload_size = 64 * 1024, .iterations = 100, .options = .bedrock },
        .{ .name = "string-list-4k", .shape = .string_list, .payload_size = 4096, .iterations = 100, .options = .bedrock },
        .{ .name = "java-byte-array", .shape = .byte_array, .payload_size = 64 * 1024, .iterations = 200, .options = .java },
        .{ .name = "java-structured-mutf8", .shape = .structured, .payload_size = 128, .iterations = 2_000, .options = .java },
        .{ .name = "bedrock-structured", .shape = .structured, .payload_size = 128, .iterations = 2_000, .options = .bedrock },
        .{ .name = "network-varints", .shape = .structured, .payload_size = 128, .iterations = 2_000, .options = .bedrock_network },
        .{ .name = "gzip-byte-array", .shape = .byte_array, .payload_size = 64 * 1024, .iterations = 100, .options = .{ .compression = .gzip } },
        .{ .name = "zlib-byte-array", .shape = .byte_array, .payload_size = 64 * 1024, .iterations = 100, .options = .{ .compression = .zlib } },
        .{ .name = "large-byte-array", .shape = .byte_array, .payload_size = 4 * 1024 * 1024, .iterations = 10, .options = .java },
    }) |case| try runCase(allocator, init.io, case);
    try runMalformed(allocator, init.io);
    try profileCompression(allocator, init.io);
}

/// Counts calls and tracks peak live bytes of the wrapped allocator.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grow(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        self.live = self.live - old_len + new_len;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.grow(0, len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.grow(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.allocations += 1;
        self.grow(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.live -= memory.len;
    }
};

fn runCase(allocator: std.mem.Allocator, io: std.Io, case: Case) !void {
    var document = try makeDocument(allocator, case);
    defer document.deinit(allocator);
    const encoded = try nbt.serialize(allocator, document, case.options);
    defer allocator.free(encoded);
    var logical_options = case.options;
    logical_options.compression = .none;
    const logical = try nbt.serialize(allocator, document, logical_options);
    defer allocator.free(logical);
    const buffer = try allocator.alloc(u8, encoded.len);
    defer allocator.free(buffer);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const warmup_iterations = @max(case.iterations / 20, 1);
    var results: [Op.count]u64 = undefined;
    inline for (0..Op.count) |op| {
        var samples: [sample_count]u64 = undefined;
        _ = try measure(@fromBackingInt(@intCast(op)), allocator, &arena, io, &document, encoded, buffer, case.options, warmup_iterations);
        for (&samples) |*sample| {
            sample.* = try measure(@fromBackingInt(@intCast(op)), allocator, &arena, io, &document, encoded, buffer, case.options, case.iterations);
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        results[op] = samples[sample_count / 2] / case.iterations;
    }

    std.debug.print("{s} ({d} B):\n  decode {d} ns/op ({d:.1} MiB/s), arena {d} ns/op, encode {d} ns/op ({d:.1} MiB/s), write {d} ns/op ({d:.1} MiB/s), walk {d} ns/op", .{
        case.name,                                                logical.len,
        results[@backingInt(Op.decode)],                          throughput(logical.len, results[@backingInt(Op.decode)]),
        results[@backingInt(Op.arena)],                           results[@backingInt(Op.encode)],
        throughput(logical.len, results[@backingInt(Op.encode)]), results[@backingInt(Op.write)],
        throughput(logical.len, results[@backingInt(Op.write)]),  results[@backingInt(Op.walk)],
    });
    if (document.root == .compound and document.root.compound.entries.len != 0) {
        std.debug.print(", lookup {d} ns/key", .{results[@backingInt(Op.lookup)] / document.root.compound.entries.len});
    }
    std.debug.print("\n", .{});

    var decode_alloc: CountingAllocator = .{ .child = allocator };
    var parsed = try nbt.parse(decode_alloc.allocator(), encoded, case.options);
    const retained = decode_alloc.live;
    parsed.deinit(decode_alloc.allocator());
    var encode_alloc: CountingAllocator = .{ .child = allocator };
    encode_alloc.allocator().free(try nbt.serialize(encode_alloc.allocator(), document, case.options));
    var write_alloc: CountingAllocator = .{ .child = allocator };
    var writer: std.Io.Writer = .fixed(buffer);
    try nbt.writeDocument(write_alloc.allocator(), &writer, document, case.options);
    std.debug.print("  allocs/op, peak temporary bytes: decode {d}, {d} (+{d} retained), encode {d}, {d}, write {d}, {d}\n", .{
        decode_alloc.allocations, decode_alloc.peak - retained, retained,
        encode_alloc.allocations, encode_alloc.peak,            write_alloc.allocations,
        write_alloc.peak,
    });
}

const Op = enum {
    decode,
    arena,
    encode,
    write,
    walk,
    lookup,
    const count = std.enums.values(Op).len;
};

fn measure(
    comptime op: Op,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    document: *const nbt.Document,
    encoded: []const u8,
    buffer: []u8,
    options: nbt.Options,
    iterations: usize,
) !u64 {
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| switch (op) {
        .decode => {
            var parsed = try nbt.parse(allocator, encoded, options);
            parsed.deinit(allocator);
        },
        .arena => {
            _ = arena.reset(.retain_capacity);
            std.mem.doNotOptimizeAway(try nbt.parse(arena.allocator(), encoded, options));
        },
        .encode => allocator.free(try nbt.serialize(allocator, document.*, options)),
        .write => {
            var writer: std.Io.Writer = .fixed(buffer);
            try nbt.writeDocument(allocator, &writer, document.*, options);
            std.mem.doNotOptimizeAway(writer.end);
        },
        .walk => std.mem.doNotOptimizeAway(walk(document.root)),
        .lookup => if (document.root == .compound) {
            for (document.root.compound.entries) |entry| {
                std.mem.doNotOptimizeAway(document.root.compound.get(entry.name));
            }
        },
    };
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}

/// Visits every tag and sums payload lengths, like a read-only consumer would.
fn walk(tag: nbt.Tag) usize {
    return switch (tag) {
        .list => |list| blk: {
            var total: usize = list.items.len;
            for (list.items) |item| total += walk(item);
            break :blk total;
        },
        .compound => |compound| blk: {
            var total: usize = compound.entries.len;
            for (compound.entries) |entry| total += entry.name.len + walk(entry.value);
            break :blk total;
        },
        .string, .byte_array => |bytes| bytes.len,
        .int_array => |values| values.len,
        .long_array => |values| values.len,
        else => 1,
    };
}

/// Little-endian Bedrock NBT bytes for synthetic shapes.
const Raw = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn int(self: *Raw, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.bytes.appendSlice(self.allocator, &buffer);
    }

    fn tag(self: *Raw, tag_type: nbt.TagType, name: []const u8) !void {
        try self.bytes.append(self.allocator, @backingInt(tag_type));
        try self.string(name);
    }

    fn string(self: *Raw, value: []const u8) !void {
        try self.int(u16, @intCast(value.len));
        try self.bytes.appendSlice(self.allocator, value);
    }

    fn list(self: *Raw, element_type: nbt.TagType, len: usize) !void {
        try self.bytes.append(self.allocator, @backingInt(element_type));
        try self.int(i32, @intCast(len));
    }

    fn end(self: *Raw) !void {
        try self.bytes.append(self.allocator, 0);
    }
};

fn makeRaw(allocator: std.mem.Allocator, shape: Shape, size: usize) ![]u8 {
    var raw: Raw = .{ .allocator = allocator };
    errdefer raw.bytes.deinit(allocator);
    var name: [64]u8 = undefined;
    switch (shape) {
        .int_list => {
            try raw.tag(.list, "values");
            try raw.list(.int, size);
            for (0..size) |index| try raw.int(i32, @intCast(index * 7919));
        },
        .string_list => {
            try raw.tag(.list, "lore");
            try raw.list(.string, size);
            for (0..size) |index| try raw.string(try std.fmt.bufPrint(&name, "minecraft:item_{d}_with_a_longer_name", .{index}));
        },
        .palette => {
            try raw.tag(.list, "block_palette");
            try raw.list(.compound, size);
            for (0..size) |index| {
                try raw.tag(.string, "name");
                try raw.string(try std.fmt.bufPrint(&name, "minecraft:block_{d}", .{index}));
                try raw.tag(.compound, "states");
                try raw.tag(.string, "facing_direction");
                try raw.string("north");
                try raw.tag(.byte, "open_bit");
                try raw.bytes.append(allocator, @intCast(index & 1));
                try raw.tag(.int, "age");
                try raw.int(i32, @intCast(index % 16));
                try raw.end();
                try raw.tag(.int, "version");
                try raw.int(i32, 18_163_713);
                try raw.end();
            }
        },
        .nested => {
            try raw.tag(.compound, "");
            for (0..size - 1) |index| {
                try raw.tag(.int, "depth");
                try raw.int(i32, @intCast(index));
                try raw.tag(.compound, "child");
            }
            for (0..size) |_| try raw.end();
        },
        else => unreachable,
    }
    return raw.bytes.toOwnedSlice(allocator);
}

fn makeDocument(allocator: std.mem.Allocator, case: Case) !nbt.Document {
    switch (case.shape) {
        .fixture => {
            const fixture = fixtures.documents[case.payload_size];
            return nbt.parse(allocator, fixture.bytes, fixture.options);
        },
        .int_list, .string_list, .palette, .nested => {
            const bytes = try makeRaw(allocator, case.shape, case.payload_size);
            defer allocator.free(bytes);
            return nbt.parse(allocator, bytes, .bedrock);
        },
        .compound => {
            var compound = nbt.builder.Compound.init(allocator);
            defer compound.deinit();
            for (0..case.payload_size) |index| {
                var name: [32]u8 = undefined;
                try compound.add(try std.fmt.bufPrint(&name, "field{d}", .{index}), .{ .int = @intCast(index) });
            }
            var root = try compound.finish();
            errdefer root.deinit(allocator);
            return nbt.Document.init(allocator, "benchmark", root);
        },
        .byte_array => {
            const payload = try allocator.alloc(u8, case.payload_size);
            errdefer allocator.free(payload);
            for (payload, 0..) |*byte, i| byte.* = @truncate(i *% 31);
            return nbt.Document.init(allocator, "benchmark", .{ .byte_array = payload });
        },
        .structured => {},
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

/// Rejection cost and peak memory for hostile inputs. Fails if a limit stops holding.
fn runMalformed(allocator: std.mem.Allocator, io: std.Io) !void {
    var raw: Raw = .{ .allocator = allocator };
    defer raw.bytes.deinit(allocator);

    // 600 nested single-item lists against the 512 depth limit.
    try raw.tag(.list, "");
    for (0..600) |_| try raw.list(.list, 1);
    const depth_bomb = try raw.bytes.toOwnedSlice(allocator);
    defer allocator.free(depth_bomb);

    // A million-entry compound list backed by six bytes.
    try raw.tag(.list, "");
    try raw.list(.compound, 1_000_000);
    const length_bomb = try raw.bytes.toOwnedSlice(allocator);
    defer allocator.free(length_bomb);

    // 1,000 distinct names, then a duplicate of the first.
    try raw.tag(.compound, "");
    var name: [32]u8 = undefined;
    for (0..1001) |index| {
        try raw.tag(.byte, try std.fmt.bufPrint(&name, "key{d}", .{index % 1000}));
        try raw.bytes.append(allocator, 0);
    }
    try raw.end();
    const duplicate = try raw.bytes.toOwnedSlice(allocator);
    defer allocator.free(duplicate);

    const structure = fixtures.documents[2].bytes;
    const Malformed = struct { name: []const u8, bytes: []const u8, expected: nbt.Error };
    for ([_]Malformed{
        .{ .name = "truncated-structure", .bytes = structure[0 .. structure.len / 2], .expected = error.UnexpectedEndOfInput },
        .{ .name = "depth-bomb-600", .bytes = depth_bomb, .expected = error.DepthLimitExceeded },
        .{ .name = "length-bomb-1M", .bytes = length_bomb, .expected = error.UnexpectedEndOfInput },
        .{ .name = "duplicate-name-1001", .bytes = duplicate, .expected = error.DuplicateName },
    }) |case| {
        const iterations = 200;
        var samples: [sample_count]u64 = undefined;
        for (&samples) |*sample| {
            const start = std.Io.Clock.awake.now(io);
            for (0..iterations) |_| {
                if (nbt.parse(allocator, case.bytes, .bedrock)) |parsed| {
                    var document = parsed;
                    document.deinit(allocator);
                    return error.MalformedInputAccepted;
                } else |err| if (err != case.expected) return err;
            }
            sample.* = @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        var counting: CountingAllocator = .{ .child = allocator };
        _ = nbt.parse(counting.allocator(), case.bytes, .bedrock) catch {};
        if (counting.live != 0) return error.LeakOnRejection;
        std.debug.print("malformed {s} ({d} B): rejected in {d} ns/op, {d} allocs, peak {d} B\n", .{
            case.name, case.bytes.len, samples[sample_count / 2] / iterations, counting.allocations, counting.peak,
        });
    }
}

fn profileCompression(allocator: std.mem.Allocator, io: std.Io) !void {
    const plain = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(plain);
    for (plain, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    var root = try nbt.builder.byteArray(allocator, plain);
    var document = nbt.Document.init(allocator, "profile", root) catch |err| {
        root.deinit(allocator);
        return err;
    };
    defer document.deinit(allocator);
    const logical = try nbt.serialize(allocator, document, .java);
    defer allocator.free(logical);
    const workspace = try allocator.create(struct {
        history: [std.compress.flate.max_window_len]u8,
        inflater: std.compress.flate.Decompress,
    });
    defer allocator.destroy(workspace);
    inline for (.{ nbt.Compression.gzip, nbt.Compression.zlib }) |kind| {
        const encoded = try nbt.serialize(allocator, document, .{ .compression = kind });
        defer allocator.free(encoded);
        const container: std.compress.flate.Container = if (kind == .gzip) .gzip else .zlib;
        inline for (.{ false, true }) |checksum| {
            var samples: [sample_count]u64 = undefined;
            for (&samples) |*sample| {
                const start = std.Io.Clock.awake.now(io);
                for (0..200) |_| {
                    var source: std.Io.Reader = .fixed(encoded);
                    workspace.inflater = .init(&source, container, &workspace.history);
                    var hasher = std.compress.flate.Container.Hasher.init(container);
                    while (workspace.inflater.reader.peekGreedy(1)) |chunk| {
                        if (checksum) hasher.update(chunk);
                        workspace.inflater.reader.toss(chunk.len);
                    } else |err| if (err != error.EndOfStream) return err;
                    std.mem.doNotOptimizeAway(hasher);
                }
                sample.* = @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
            }
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            std.debug.print("profile {s} inflate{s}: {d} ns/op (reused workspace, no output allocation/copy)\n", .{
                @tagName(kind), if (checksum) "+checksum" else " only", samples[sample_count / 2] / 200,
            });
        }
        var samples: [sample_count]u64 = undefined;
        for (&samples) |*sample| {
            const start = std.Io.Clock.awake.now(io);
            for (0..200) |_| {
                var hasher = std.compress.flate.Container.Hasher.init(container);
                hasher.update(logical);
                std.mem.doNotOptimizeAway(hasher);
            }
            sample.* = @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.debug.print("profile {s} checksum only: {d} ns/op\n", .{ @tagName(kind), samples[sample_count / 2] / 200 });
    }
}

fn throughput(bytes: usize, nanoseconds: u64) f64 {
    if (nanoseconds == 0) return 0;
    return @as(f64, @floatFromInt(bytes)) * 1_000_000_000.0 /
        @as(f64, @floatFromInt(nanoseconds)) / (1024.0 * 1024.0);
}
