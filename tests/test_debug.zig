const std = @import("std");
const FastMessage = @import("src/message_pool.zig").FastMessage;
const MessagePool = @import("src/message_pool.zig").MessagePool;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === Debug Test ===", .{});

    // Test message pool
    std.log.info("Creating message pool...", .{});
    var pool = try MessagePool.init(allocator);
    defer pool.deinit();
    std.log.info("✅ Message pool created", .{});

    // Test message creation
    std.log.info("Creating message...", .{});
    if (pool.acquire()) |msg| {
        msg.* = FastMessage.createUserString(1, 0, 0, "test");
        std.log.info("✅ Message created: type={}, string='{s}'", .{ msg.msg_type, msg.getString() });
        pool.release(msg);
    }

    std.log.info("✅ === Debug Test Complete ===", .{});
}
