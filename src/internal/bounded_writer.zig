const std = @import("std");
const bounded_buffer = @import("bounded_buffer.zig");

/// A size-limited allocating writer. `failure` explains `WriteFailed`.
pub const BoundedWriter = struct {
    allocator: std.mem.Allocator,
    writer: std.Io.Writer,
    max_len: usize,
    failure: Failure = .none,

    pub const Failure = enum { none, limit, out_of_memory };

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.noopFlush,
        .rebase = rebase,
    };

    pub fn init(allocator: std.mem.Allocator, max_len: usize) std.mem.Allocator.Error!BoundedWriter {
        const capacity = @min(max_len, 64);
        return .{
            .allocator = allocator,
            .writer = .{
                .buffer = try allocator.alloc(u8, capacity),
                .vtable = &vtable,
            },
            .max_len = max_len,
        };
    }

    pub fn deinit(self: *BoundedWriter) void {
        self.allocator.free(self.writer.buffer);
        self.* = undefined;
    }

    pub fn toOwnedSlice(self: *BoundedWriter) (bounded_buffer.Error || std.mem.Allocator.Error)![]u8 {
        if (self.writer.end > self.max_len) return error.SizeLimitExceeded;
        var list: std.ArrayList(u8) = .{
            .items = self.writer.buffer[0..self.writer.end],
            .capacity = self.writer.buffer.len,
        };
        errdefer {
            self.writer.buffer = list.allocatedSlice();
            self.writer.end = list.items.len;
        }
        const owned = try list.toOwnedSlice(self.allocator);
        self.writer.buffer = &.{};
        self.writer.end = 0;
        return owned;
    }

    fn fail(self: *BoundedWriter, reason: Failure) std.Io.Writer.Error {
        self.failure = reason;
        return error.WriteFailed;
    }

    fn ensureCapacity(self: *BoundedWriter, needed: usize) std.Io.Writer.Error!void {
        const capacity = bounded_buffer.nextCapacity(self.writer.buffer.len, needed, self.max_len) catch return self.fail(.limit);
        if (capacity == self.writer.buffer.len) return;
        self.writer.buffer = self.allocator.realloc(self.writer.buffer, capacity) catch return self.fail(.out_of_memory);
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BoundedWriter = @fieldParentPtr("writer", writer);
        const pattern = data[data.len - 1];
        var external_len: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            external_len = std.math.add(usize, external_len, bytes.len) catch return self.fail(.limit);
        }
        const repeated = std.math.mul(usize, pattern.len, splat) catch return self.fail(.limit);
        external_len = std.math.add(usize, external_len, repeated) catch return self.fail(.limit);
        const needed = std.math.add(usize, writer.end, external_len) catch return self.fail(.limit);
        try self.ensureCapacity(needed);

        for (data[0 .. data.len - 1]) |bytes| {
            @memcpy(writer.buffer[writer.end..][0..bytes.len], bytes);
            writer.end += bytes.len;
        }
        for (0..splat) |_| {
            @memcpy(writer.buffer[writer.end..][0..pattern.len], pattern);
            writer.end += pattern.len;
        }
        return external_len;
    }

    fn rebase(writer: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        _ = preserve;
        const self: *BoundedWriter = @fieldParentPtr("writer", writer);
        const needed = std.math.add(usize, writer.end, minimum_len) catch return self.fail(.limit);
        try self.ensureCapacity(needed);
    }
};
