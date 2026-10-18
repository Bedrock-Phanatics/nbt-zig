const std = @import("std");
const Allocator = std.mem.Allocator;

const Entry = @import("../types.zig").Entry;

/// Compounds up to this size are checked by scanning instead of hashing.
pub const small_limit = 16;

pub const Error = error{ DuplicateName, SizeLimitExceeded } || Allocator.Error;

/// Scratch index reused across compounds, so only the largest one allocates.
pub const Checker = struct {
    index: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Checker, allocator: Allocator) void {
        self.index.deinit(allocator);
    }

    pub fn check(self: *Checker, allocator: Allocator, entries: []const Entry) Error!void {
        if (entries.len <= small_limit) {
            for (entries, 0..) |entry, index| {
                for (entries[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.name, entry.name)) return error.DuplicateName;
                }
            }

            return;
        }

        const count = std.math.cast(u32, entries.len) orelse return error.SizeLimitExceeded;
        self.index.clearRetainingCapacity();
        try self.index.ensureTotalCapacity(allocator, count);

        for (entries) |entry| {
            if (self.index.getOrPutAssumeCapacity(entry.name).found_existing) return error.DuplicateName;
        }
    }
};
