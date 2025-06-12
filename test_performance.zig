const std = @import("std");
const FastMailbox = @import("src/fast_mailbox.zig").FastMailbox;
const FastMessage = @import("src/message_pool.zig").FastMessage;
const MessagePool = @import("src/message_pool.zig").MessagePool;
const MessageBatch = @import("src/message_pool.zig").MessageBatch;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === Performance Test ===", .{});

    // Create message pool
    var pool = try MessagePool.init(allocator);
    defer pool.deinit();

    // Create mailbox
    var mailbox = FastMailbox.init();
    defer mailbox.deinit();

    const num_messages = 50000; // 50K messages for testing
    std.log.info("Testing with {} messages", .{num_messages});

    // Test 1: Individual message sending
    std.log.info("\n=== Test 1: Individual Messages ===", .{});
    const start1 = std.time.nanoTimestamp();

    var sent_count: u32 = 0;
    for (0..num_messages) |i| {
        if (pool.acquire()) |msg| {
            if (i % 2 == 0) {
                msg.* = FastMessage.createUserString(1, 0, i, "test");
            } else {
                msg.* = FastMessage.createUserInt(1, 0, i, @intCast(i));
            }

            if (mailbox.send(msg)) {
                sent_count += 1;
            } else {
                pool.release(msg);
                break;
            }
        }
    }

    const send_end1 = std.time.nanoTimestamp();
    const send_time1 = @divTrunc(send_end1 - start1, 1000000); // ms
    const send_rate1 = if (send_time1 > 0) @divTrunc(sent_count * 1000, @as(u32, @intCast(send_time1))) else 0;

    std.log.info("Sent {} messages in {}ms (rate: {} msg/s)", .{ sent_count, send_time1, send_rate1 });

    // Get stats after sending
    var stats1 = mailbox.getStats();
    std.log.info("After sending - Total sent: {}, mailbox size: {}", .{ stats1.messages_sent, stats1.current_size });

    // Receive all messages
    var received_count: u32 = 0;
    const recv_start1 = std.time.nanoTimestamp();

    while (mailbox.receive()) |msg| {
        received_count += 1;
        pool.release(msg);
    }

    const recv_end1 = std.time.nanoTimestamp();
    const recv_time1 = @divTrunc(recv_end1 - recv_start1, 1000000); // ms
    const recv_rate1 = if (recv_time1 > 0) @divTrunc(received_count * 1000, @as(u32, @intCast(recv_time1))) else 0;

    std.log.info("Received {} messages in {}ms (rate: {} msg/s)", .{ received_count, recv_time1, recv_rate1 });

    // Get stats after receiving
    stats1 = mailbox.getStats();
    std.log.info("After receiving - Total received: {}, mailbox size: {}", .{ stats1.messages_received, stats1.current_size });

    // Test 2: Batch message sending
    std.log.info("\n=== Test 2: Batch Messages ===", .{});
    const batch_size = 1000;
    const num_batches = num_messages / batch_size;

    const start2 = std.time.nanoTimestamp();

    var total_sent: u32 = 0;
    for (0..num_batches) |batch_idx| {
        var batch = MessageBatch.init();

        // Fill batch
        for (0..batch_size) |i| {
            if (pool.acquire()) |msg| {
                const msg_idx = batch_idx * batch_size + i;
                if (msg_idx % 2 == 0) {
                    msg.* = FastMessage.createUserString(1, 0, msg_idx, "batch");
                } else {
                    msg.* = FastMessage.createUserInt(1, 0, msg_idx, @intCast(msg_idx));
                }

                if (!batch.add(msg)) {
                    pool.release(msg);
                    break;
                }
            }
        }

        // Send batch
        const sent_in_batch = mailbox.sendBatch(&batch);
        total_sent += sent_in_batch;

        // Release unsent messages
        if (sent_in_batch < batch.count) {
            for (batch.getMessages()[sent_in_batch..]) |msg| {
                pool.release(msg);
            }
        }
    }

    const send_end2 = std.time.nanoTimestamp();
    const send_time2 = @divTrunc(send_end2 - start2, 1000000); // ms
    const send_rate2 = if (send_time2 > 0) @divTrunc(total_sent * 1000, @as(u32, @intCast(send_time2))) else 0;

    std.log.info("Sent {} messages in {}ms (rate: {} msg/s)", .{ total_sent, send_time2, send_rate2 });

    // Receive in batches
    var total_received: u32 = 0;
    const recv_start2 = std.time.nanoTimestamp();

    while (true) {
        var receive_batch = MessageBatch.init();
        const received_in_batch = mailbox.receiveBatch(&receive_batch);

        if (received_in_batch == 0) break;

        total_received += received_in_batch;

        // Release messages
        for (receive_batch.getMessages()) |msg| {
            pool.release(msg);
        }
    }

    const recv_end2 = std.time.nanoTimestamp();
    const recv_time2 = @divTrunc(recv_end2 - recv_start2, 1000000); // ms
    const recv_rate2 = if (recv_time2 > 0) @divTrunc(total_received * 1000, @as(u32, @intCast(recv_time2))) else 0;

    std.log.info("Received {} messages in {}ms (rate: {} msg/s)", .{ total_received, recv_time2, recv_rate2 });

    // Summary
    std.log.info("\n=== Performance Summary ===", .{});
    std.log.info("Individual messages:", .{});
    std.log.info("  Send rate: {} msg/s", .{send_rate1});
    std.log.info("  Receive rate: {} msg/s", .{recv_rate1});
    std.log.info("Batch messages:", .{});
    std.log.info("  Send rate: {} msg/s", .{send_rate2});
    std.log.info("  Receive rate: {} msg/s", .{recv_rate2});

    const improvement_send = if (send_rate1 > 0) @divTrunc(@as(u64, send_rate2) * 100, send_rate1) else 0;
    const improvement_recv = if (recv_rate1 > 0) @divTrunc(@as(u64, recv_rate2) * 100, recv_rate1) else 0;

    std.log.info("Batch improvement:", .{});
    std.log.info("  Send: {}% of individual", .{improvement_send});
    std.log.info("  Receive: {}% of individual", .{improvement_recv});

    // Get final stats
    const stats = mailbox.getStats();
    std.log.info("\nFinal mailbox stats:", .{});
    std.log.info("  Total sent: {}", .{stats.messages_sent});
    std.log.info("  Total received: {}", .{stats.messages_received});
    std.log.info("  Dropped: {}", .{stats.messages_dropped});

    std.log.info("✅ === Performance Test Complete ===", .{});
}
