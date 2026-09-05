const std = @import("std");

pub const Error = error{SizeLimitExceeded};

/// Returns a geometric capacity capped at limit.
pub fn nextCapacity(current: usize, needed: usize, limit: usize) Error!usize {
    if (needed > limit) return error.SizeLimitExceeded;
    if (needed <= current) return current;

    var capacity = @min(@max(current, 8), limit);
    while (capacity < needed) {
        capacity = std.math.add(usize, capacity, capacity / 2 + 8) catch limit;
        if (capacity >= limit) {
            capacity = limit;
            break;
        }
    }
    if (capacity < needed) return error.SizeLimitExceeded;
    return capacity;
}

pub fn ensureCapacity(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    needed: usize,
    limit: usize,
) (Error || std.mem.Allocator.Error)!void {
    const capacity = try nextCapacity(list.capacity, needed, limit);
    if (capacity > list.capacity) try list.ensureTotalCapacityPrecise(allocator, capacity);
}

test "capacity growth is geometric and bounded" {
    var capacity: usize = 0;
    var growths: usize = 0;
    for (1..1_000_001) |needed| {
        const next = try nextCapacity(capacity, needed, 1_000_000);
        if (next != capacity) growths += 1;
        capacity = next;
    }
    try std.testing.expectEqual(@as(usize, 1_000_000), capacity);
    try std.testing.expect(growths < 40);
    try std.testing.expectError(error.SizeLimitExceeded, nextCapacity(capacity, capacity + 1, capacity));
}
