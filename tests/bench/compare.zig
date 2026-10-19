//! Zig half of the ext-encoding and PocketMine comparison. tests/bench/php/compare.php
//! runs the same operations on the same bytes, see docs/benchmarks.md.

const std = @import("std");
const nbt = @import("nbt");
const fixtures = @import("fixtures");

const batches = 31;
const target_batch_ns = 20 * std.time.ns_per_ms;
const array_len = 4096;

var io: std.Io = undefined;
/// Inputs are also written here when a directory is given, so PHP reads the same bytes.
var export_dir: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        export_dir = args[1];
        try std.Io.Dir.cwd().createDirPath(io, args[1]);
    }
    std.debug.print("{s:<40} {s:>12} {s:>12} {s:>12} {s:>10} {s:>8}\n", .{ "case", "median ns", "p10 ns", "p90 ns", "MiB/s", "allocs" });

    var small: [array_len]i32 = undefined;
    var mixed: [array_len]i32 = undefined;
    for (&small, &mixed, 0..) |*s, *m, i| {
        s.* = @as(i32, @intCast((i * 7919) % 128)) - 64;
        m.* = @bitCast(@as(u32, @truncate(i *% 2654435761)));
    }

    inline for (.{ .{ "small", &small }, .{ "mixed", &mixed } }) |set| {
        const values = set[1];
        try arrayCases(allocator, "varint int[4096] " ++ set[0], "varint-" ++ set[0], values, .bedrock_network);
        try arrayCases(allocator, "LE int[4096] " ++ set[0], "le-" ++ set[0], values, .bedrock);
        try arrayCases(allocator, "BE int[4096] " ++ set[0], "be-" ++ set[0], values, .java);
    }

    // PocketMine reads strings as raw bytes and keeps the first of duplicate names.
    var pocketmine: nbt.Options = .bedrock;
    pocketmine.raw_strings = true;
    pocketmine.duplicate_names = .keep_first;

    for (fixtures.documents) |fixture| {
        if (fixture.options.encoding != .bedrock) continue;
        try save(fixture.name, fixture.bytes);
        try documentCases(allocator, fixture.name, fixture.bytes, pocketmine);
    }
}

fn save(name: []const u8, bytes: []const u8) !void {
    const dir = export_dir orelse return;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path, "{s}/{s}.bin", .{ dir, name }), .data = bytes });
}

fn arrayCases(allocator: std.mem.Allocator, comptime name: []const u8, comptime file: []const u8, values: []const i32, comptime preset: nbt.Options) !void {
    const tag: nbt.Tag = .{ .int_array = @constCast(values) };
    const bytes = try nbt.serializePayload(allocator, tag, preset);
    defer allocator.free(bytes);
    try save(file, bytes);

    var parsed = try nbt.parsePayload(allocator, bytes, .int_array, preset);
    defer parsed.tag.deinit(allocator);
    if (!std.mem.eql(i32, parsed.tag.int_array, values)) return error.WrongValues;

    const Ops = struct {
        fn decode(context: Context) !void {
            var result = try nbt.parsePayload(context.allocator, context.bytes, .int_array, preset);
            std.mem.doNotOptimizeAway(result.tag.int_array.ptr);
            result.tag.deinit(context.allocator);
        }
        fn encode(context: Context) !void {
            context.allocator.free(try nbt.serializePayload(context.allocator, context.tag, preset));
        }
        fn write(context: Context) !void {
            var writer: std.Io.Writer = .fixed(context.buffer);
            try nbt.writePayload(context.allocator, &writer, context.tag, preset);
            std.mem.doNotOptimizeAway(writer.end);
        }
        fn scan(context: Context) !void {
            std.mem.doNotOptimizeAway(try nbt.scanPayload(context.bytes, .int_array, preset));
        }
    };

    const buffer = try allocator.alloc(u8, bytes.len);
    defer allocator.free(buffer);
    const context: Context = .{ .allocator = allocator, .bytes = bytes, .tag = tag, .buffer = buffer };
    try run(name ++ " decode", bytes.len, context, Ops.decode);
    try run(name ++ " encode", bytes.len, context, Ops.encode);
    try run(name ++ " write to buffer", bytes.len, context, Ops.write);
    try run(name ++ " scan", bytes.len, context, Ops.scan);
}

fn documentCases(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8, options: nbt.Options) !void {
    var document = try nbt.parse(allocator, bytes, options);
    defer document.deinit(allocator);
    if (try nbt.scanDocument(bytes, options) != bytes.len) return error.WrongLength;

    const Ops = struct {
        fn read(context: Context) !void {
            var result = try nbt.parse(context.allocator, context.bytes, context.options);
            result.deinit(context.allocator);
        }
        fn write(context: Context) !void {
            context.allocator.free(try nbt.serialize(context.allocator, context.document, context.options));
        }
        fn length(context: Context) !void {
            std.mem.doNotOptimizeAway(try nbt.scanDocument(context.bytes, context.options));
        }
    };

    const context: Context = .{ .allocator = allocator, .bytes = bytes, .document = document, .options = options };
    var label: [64]u8 = undefined;
    try run(try std.fmt.bufPrint(&label, "nbt {s} read", .{name}), bytes.len, context, Ops.read);
    try run(try std.fmt.bufPrint(&label, "nbt {s} write", .{name}), bytes.len, context, Ops.write);
    try run(try std.fmt.bufPrint(&label, "nbt {s} consumed length", .{name}), bytes.len, context, Ops.length);
}

const Context = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    tag: nbt.Tag = .{ .byte = 0 },
    document: nbt.Document = undefined,
    options: nbt.Options = .bedrock,
    buffer: []u8 = &.{},
};

fn run(name: []const u8, bytes_per_op: usize, context: Context, comptime op: fn (Context) anyerror!void) !void {
    // Size batches so each takes about target_batch_ns, after a warmup.
    var iterations: usize = 1;
    while (true) {
        const elapsed = try timed(context, op, iterations);
        if (elapsed >= target_batch_ns / 4) {
            iterations = @max(1, iterations * target_batch_ns / elapsed);
            break;
        }
        iterations *= 2;
    }

    var samples: [batches]f64 = undefined;
    for (&samples) |*sample| {
        sample.* = @as(f64, @floatFromInt(try timed(context, op, iterations))) / @as(f64, @floatFromInt(iterations));
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));

    var counting: Counting = .{ .child = context.allocator };
    var counted = context;
    counted.allocator = counting.allocator();
    try op(counted);

    const median = samples[batches / 2];
    const mib = @as(f64, @floatFromInt(bytes_per_op)) / median * 1e9 / (1024 * 1024);
    std.debug.print("{s:<40} {d:>12.1} {d:>12.1} {d:>12.1} {d:>10.1} {d:>8}\n", .{ name, median, samples[batches / 10], samples[batches * 9 / 10], mib, counting.count });
}

fn timed(context: Context, comptime op: fn (Context) anyerror!void, iterations: usize) !u64 {
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| try op(context);
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}

const Counting = struct {
    child: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};
