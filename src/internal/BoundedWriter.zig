const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const BoundedWriter = @This();

allocator: Allocator,
writer: Writer,
limit: usize,
/// Why the last `WriteFailed` happened.
failure: Failure = .none,

pub const Failure = enum {
    none,
    limit,
    out_of_memory,
};

pub const Error = error{SizeLimitExceeded} || Allocator.Error;

/// Flate's bit writer asks for eight writable bytes but may commit fewer.
const scratch_len = 8;

const vtable: Writer.VTable = .{
    .drain = drain,
    .flush = Writer.noopFlush,
    .rebase = rebase,
};

/// A zero hint allocates nothing until the first write.
pub fn init(allocator: Allocator, limit: usize, capacity_hint: usize) Allocator.Error!BoundedWriter {
    const capacity = @min(capacity_hint, limit +| scratch_len);

    return .{
        .allocator = allocator,
        .writer = .{
            .buffer = try allocator.alloc(u8, capacity),
            .vtable = &vtable,
        },
        .limit = limit,
    };
}

pub fn deinit(self: *BoundedWriter) void {
    self.allocator.free(self.writer.buffer);
    self.* = undefined;
}

pub fn err(self: *const BoundedWriter) Error {
    return switch (self.failure) {
        .limit => error.SizeLimitExceeded,
        .out_of_memory, .none => error.OutOfMemory,
    };
}

pub fn written(self: *const BoundedWriter) error{SizeLimitExceeded}![]u8 {
    if (self.writer.end > self.limit) return error.SizeLimitExceeded;
    return self.writer.buffer[0..self.writer.end];
}

pub fn toOwnedSlice(self: *BoundedWriter) Error![]u8 {
    const len = (try self.written()).len;
    const owned = if (len == self.writer.buffer.len)
        self.writer.buffer
    else
        try self.allocator.realloc(self.writer.buffer, len);

    self.writer.buffer = &.{};
    self.writer.end = 0;

    return owned;
}

fn fail(self: *BoundedWriter, reason: Failure) Writer.Error {
    self.failure = reason;
    return error.WriteFailed;
}

fn grow(self: *BoundedWriter, minimum: usize) Writer.Error!void {
    const buffer = self.writer.buffer;
    if (minimum <= buffer.len) return;

    const grown = @min(@max(buffer.len *| 2, 64), self.limit +| scratch_len);
    self.writer.buffer = self.allocator.realloc(buffer, @max(minimum, grown)) catch
        return self.fail(.out_of_memory);
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *BoundedWriter = @fieldParentPtr("writer", w);
    const pattern = data[data.len - 1];

    var len = std.math.mul(usize, pattern.len, splat) catch return self.fail(.limit);
    for (data[0 .. data.len - 1]) |bytes| {
        len = std.math.add(usize, len, bytes.len) catch return self.fail(.limit);
    }

    const needed = std.math.add(usize, w.end, len) catch return self.fail(.limit);
    if (needed > self.limit) return self.fail(.limit);
    try self.grow(needed);

    for (data[0 .. data.len - 1]) |bytes| {
        @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
        w.end += bytes.len;
    }

    for (0..splat) |_| {
        @memcpy(w.buffer[w.end..][0..pattern.len], pattern);
        w.end += pattern.len;
    }

    return len;
}

fn rebase(w: *Writer, preserve: usize, minimum_len: usize) Writer.Error!void {
    const self: *BoundedWriter = @fieldParentPtr("writer", w);

    const needed = std.math.add(usize, w.end, minimum_len) catch return self.fail(.limit);
    if (w.end > self.limit or needed > self.limit +| scratch_len) return self.fail(.limit);

    // Nothing is ever discarded, but inflate still expects room for its whole history window.
    try self.grow(@max(needed, preserve +| minimum_len));
}
