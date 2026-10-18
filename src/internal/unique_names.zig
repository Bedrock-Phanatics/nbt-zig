const std = @import("std");
const Allocator = std.mem.Allocator;

const Entry = @import("../types.zig").Entry;

/// Compounds up to this size are checked by scanning instead of hashing.
pub const small_limit = 16;

pub const Error = error{ DuplicateName, SizeLimitExceeded } || Allocator.Error;

/// Scratch index reused across compounds, so only the largest one allocates.
pub const Checker = struct {
    index: std.StringHashMapUnmanaged(void) = .empty,
    /// A separate map type keeps `keepFirst` from sharing, and so slowing, the hash
    /// code `check` inlines.
    seen: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Checker, allocator: Allocator) void {
        self.index.deinit(allocator);
        self.seen.deinit(allocator);
    }

    pub fn check(self: *Checker, allocator: Allocator, entries: []const Entry) Error!void {
        if (entries.len <= small_limit) {
            for (entries, 0..) |entry, index| {
                if (contains(entries[0..index], entry.name)) return error.DuplicateName;
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

    /// Frees later duplicates, compacts the rest in order and returns how many remain.
    /// Nothing changes if this fails.
    pub fn keepFirst(self: *Checker, allocator: Allocator, entries: []Entry) Error!usize {
        const small = entries.len <= small_limit;
        if (!small) {
            self.seen.clearRetainingCapacity();
            try self.seen.ensureTotalCapacity(allocator, entries.len);
        }

        var kept: usize = 0;
        for (entries) |*entry| {
            const duplicate = if (small) contains(entries[0..kept], entry.name) else self.seen.getOrPutAssumeCapacity(entry.name).found_existing;
            if (duplicate) {
                entry.deinit(allocator);
                continue;
            }

            entries[kept] = entry.*;
            kept += 1;
        }

        return kept;
    }
};

fn contains(entries: []const Entry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }

    return false;
}
