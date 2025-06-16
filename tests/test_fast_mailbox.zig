const std = @import("std");
const FastMailbox = @import("src/fast_mailbox.zig").FastMailbox;
const FastMessage = @import("src/message_pool.zig").FastMessage;
const MessagePool = @import("src/message_pool.zig").MessagePool;
const MessageBatch = @import("src/message_pool.zig").MessageBatch;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === FastMailbox Test ===", .{});

    // Create message pool
    var pool = try MessagePool.init(allocator);
    defer pool.deinit();

    // Create mailbox
    var mailbox = FastMailbox.init();
    defer mailbox.deinit();

    std.log.info("Mailbox initialized, empty: {}", .{mailbox.isEmpty()});

    // Test single message operations
    if (pool.acquire()) |msg| {
        msg.* = FastMessage.createUserString(1, 0, 0, "test1");
        const sent = mailbox.send(msg);
        std.log.info("Message sent: {}", .{sent});
    }

    if (pool.acquire()) |msg| {
        msg.* = FastMessage.createUserInt(1, 0, 1, 42);
        const sent = mailbox.send(msg);
        std.log.info("Message sent: {}", .{sent});
    }

    std.log.info("Mailbox size: {}", .{mailbox.size()});

    // Test receiving messages
    var received_count: u32 = 0;
    while (mailbox.receive()) |msg| {
        switch (msg.msg_type) {
            .user_string => {
                std.log.info("Received string: '{s}'", .{msg.getString()});
            },
            .user_int => {
                std.log.info("Received int: {}", .{msg.getInt()});
            },
            else => {
                std.log.info("Received other: {}", .{msg.msg_type});
            },
        }
        received_count += 1;
        pool.release(msg);
    }

    std.log.info("Received {} messages", .{received_count});
    std.log.info("Mailbox empty: {}", .{mailbox.isEmpty()});

    // Test batch operations
    var batch = MessageBatch.init();

    // Create batch of messages
    for (0..5) |i| {
        if (pool.acquire()) |msg| {
            msg.* = FastMessage.createUserInt(1, 0, i, @intCast(i * 10));
            _ = batch.add(msg);
        }
    }

    std.log.info("Created batch with {} messages", .{batch.count});

    // Send batch
    const sent_batch = mailbox.sendBatch(&batch);
    std.log.info("Sent batch: {} messages", .{sent_batch});

    // Receive batch
    var receive_batch = MessageBatch.init();
    const received_batch = mailbox.receiveBatch(&receive_batch);
    std.log.info("Received batch: {} messages", .{received_batch});

    // Process received messages
    for (receive_batch.getMessages()) |msg| {
        std.log.info("Batch message: {}", .{msg.getInt()});
        pool.release(msg);
    }

    // Get stats
    const stats = mailbox.getStats();
    std.log.info("Mailbox stats:", .{});
    std.log.info("  Messages sent: {}", .{stats.messages_sent});
    std.log.info("  Messages received: {}", .{stats.messages_received});
    std.log.info("  Messages dropped: {}", .{stats.messages_dropped});
    std.log.info("  Current size: {}", .{stats.current_size});
    std.log.info("  Capacity: {}", .{stats.capacity});

    std.log.info("✅ === FastMailbox Test Complete ===", .{});
}
