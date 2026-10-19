const std = @import("std");
const nbt = @import("nbt");
const phpz = @import("phpz");
const c = phpz.c;
const zend = phpz.zend;
const Zval = phpz.Zval;
const errors = phpz.errors;

const allocator = phpz.heap.php_allocator;

comptime {
    phpz.namedFunctions(.{
        .nbt_bench_decode_int_array = decodeIntArray,
        .nbt_bench_encode_int_array = encodeIntArray,
        .nbt_bench_scan = scan,
        .nbt_bench_decode = decode,
    });

    const extension = @import("extension_info");
    phpz.module(.{ .name = extension.name, .version = extension.version });
}

/// 0 is Java, 1 Bedrock and 2 Bedrock network, read the way PocketMine does.
fn options(encoding: i64) !nbt.Options {
    var result: nbt.Options = switch (encoding) {
        0 => .java,
        1 => .bedrock,
        2 => .bedrock_network,
        else => return errors.argumentValueError(2, "must be 0, 1 or 2", .{}),
    };
    result.raw_strings = true;
    result.duplicate_names = .keep_first;
    return result;
}

fn fail(err: anyerror) errors.Exception {
    return errors.throwExceptionEx(.from(phpz.globals.class.entry("Exception")), 0, "%s", .{@errorName(err).ptr});
}

fn decodeIntArray(bytes: []const u8, encoding: i64) !*zend.Array {
    var parsed = nbt.parsePayload(allocator, bytes, .int_array, try options(encoding)) catch |err| return fail(err);
    defer parsed.tag.deinit(allocator);
    return ints(parsed.tag.int_array);
}

fn encodeIntArray(values: *zend.Array, encoding: i64) !*zend.String {
    const opts = try options(encoding);
    const buffer = allocator.alloc(i32, values.len()) catch |err| return fail(err);
    defer allocator.free(buffer);

    var count: usize = 0;
    var valid = true;
    values.eachValue(struct {
        fn callback(zv: *c.zval, out: []i32, index: *usize, ok: *bool) void {
            const value = if (Zval.raw.is(zv, .int)) std.math.cast(i32, Zval.raw.asUnchecked(zv, .int)) else null;
            out[index.*] = value orelse blk: {
                ok.* = false;
                break :blk 0;
            };
            index.* += 1;
        }
    }.callback, .{ buffer, &count, &valid });
    if (!valid) return errors.argumentValueError(1, "must only hold 32-bit ints", .{});

    const tag: nbt.Tag = .{ .int_array = buffer };
    const len = nbt.encodedLength(tag, opts) catch |err| return fail(err);
    const result = zend.String.alloc(len, false);
    var writer: std.Io.Writer = .fixed(result.mutableSlice()[0..len]);
    nbt.writePayload(allocator, &writer, tag, opts) catch |err| {
        result.release();
        return fail(err);
    };
    return result;
}

fn scan(bytes: []const u8, encoding: i64) !i64 {
    const len = nbt.scanDocument(bytes, try options(encoding)) catch |err| return fail(err);
    return @intCast(len);
}

/// Returns `[name, value]` with compounds as string-keyed arrays and lists as lists.
fn decode(bytes: []const u8, encoding: i64) !*zend.Array {
    var document = nbt.parse(allocator, bytes, try options(encoding)) catch |err| return fail(err);
    defer document.deinit(allocator);

    var list = zend.Array.ListBuilder.init(2);
    list.appendAssumeCapacity(.string, document.name);
    var root: c.zval = undefined;
    toZval(&root, &document.root);
    list.appendValue(&root);
    return list.finish();
}

fn ints(values: anytype) *zend.Array {
    var list = zend.Array.ListBuilder.init(@intCast(values.len));
    for (values) |value| list.appendAssumeCapacity(.int, value);
    return list.finish();
}

fn toZval(zv: *c.zval, tag: *const nbt.Tag) void {
    switch (tag.*) {
        .end => Zval.raw.set(zv, .null, {}),
        inline .byte, .short, .int, .long => |value| Zval.raw.set(zv, .int, value),
        inline .float, .double => |value| Zval.raw.set(zv, .float, value),
        .string, .byte_array => |value| Zval.raw.set(zv, .string, value),
        inline .int_array, .long_array => |values| Zval.raw.set(zv, .array, ints(values)),
        .list => |value| {
            var list = zend.Array.ListBuilder.init(@intCast(value.items.len));
            for (value.items) |*item| {
                var element: c.zval = undefined;
                toZval(&element, item);
                list.appendValue(&element);
            }
            Zval.raw.set(zv, .array, list.finish());
        },
        .compound => |value| {
            const array = zend.Array.init(@intCast(value.entries.len));
            for (value.entries) |*entry| {
                var element: c.zval = undefined;
                toZval(&element, &entry.value);
                _ = array.update(entry.name, &element);
            }
            Zval.raw.set(zv, .array, array);
        },
    }
}
