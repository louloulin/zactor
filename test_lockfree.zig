const std = @import("std");
const LockFreeQueue = @import("src/lockfree_queue.zig").LockFreeQueue;

pub fn main() !void {
    std.log.info("🚀 === LockFree Queue Test ===", .{});

    var queue = LockFreeQueue(u32).init();
    
    std.log.info("Queue initialized, capacity: {}", .{queue.capacity()});
    std.log.info("Queue empty: {}", .{queue.isEmpty()});
    
    // Test basic operations
    const test_values = [_]u32{ 1, 2, 3, 4, 5 };
    
    // Push values
    for (test_values) |value| {
        const success = queue.push(value);
        std.log.info("Pushed {}: {}", .{ value, success });
    }
    
    std.log.info("Queue size after push: {}", .{queue.size()});
    
    // Pop values
    var popped_count: u32 = 0;
    while (queue.pop()) |value| {
        std.log.info("Popped: {}", .{value});
        popped_count += 1;
    }
    
    std.log.info("Popped {} values", .{popped_count});
    std.log.info("Queue empty: {}", .{queue.isEmpty()});
    
    // Test batch operations
    const batch_values = [_]u32{ 10, 20, 30, 40, 50 };
    const pushed = queue.pushBatch(&batch_values);
    std.log.info("Batch pushed {} values", .{pushed});
    
    var batch_buffer: [10]u32 = undefined;
    const popped_batch = queue.popBatch(&batch_buffer);
    std.log.info("Batch popped {} values", .{popped_batch});
    
    for (batch_buffer[0..popped_batch]) |value| {
        std.log.info("Batch value: {}", .{value});
    }
    
    std.log.info("✅ === LockFree Queue Test Complete ===", .{});
}
