/// Byte swaps every element in place, a vector at a time.
pub fn swapAll(comptime T: type, items: []align(1) T) void {
    const lanes = 32 / @sizeOf(T);
    var index: usize = 0;

    while (index + lanes <= items.len) : (index += lanes) {
        const chunk: @Vector(lanes, T) = items[index..][0..lanes].*;
        items[index..][0..lanes].* = @byteSwap(chunk);
    }

    for (items[index..]) |*item| item.* = @byteSwap(item.*);
}
