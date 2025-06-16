const std = @import("std");
const FastMailbox = @import("src/fast_mailbox.zig").FastMailbox;
const FastMessage = @import("src/message_pool.zig").FastMessage;
const MessagePool = @import("src/message_pool.zig").MessagePool;
const MessageBatch = @import("src/message_pool.zig").MessageBatch;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("⚡ === 高性能Mailbox验证 ===", .{});

    // 创建消息池和mailbox
    var pool = try MessagePool.init(allocator);
    defer pool.deinit();

    var mailbox = FastMailbox.init();
    defer mailbox.deinit();

    // 测试1: 基础功能验证
    std.log.info("\n📋 测试1: 基础功能验证", .{});

    // 发送不同类型的消息
    const test_messages = [_]struct { msg_type: []const u8, expected_type: @import("src/message_pool.zig").FastMessage.Type }{
        .{ .msg_type = "string", .expected_type = .user_string },
        .{ .msg_type = "int", .expected_type = .user_int },
        .{ .msg_type = "float", .expected_type = .user_float },
        .{ .msg_type = "ping", .expected_type = .system_ping },
    };

    for (test_messages, 0..) |test_case, i| {
        if (pool.acquire()) |msg| {
            switch (i) {
                0 => msg.* = FastMessage.createUserString(@intCast(i), 0, i, "test_string"),
                1 => msg.* = FastMessage.createUserInt(@intCast(i), 0, i, @intCast(i * 100)),
                2 => msg.* = FastMessage.createUserFloat(@intCast(i), 0, i, @as(f64, @floatFromInt(i)) * 1.5),
                3 => msg.* = FastMessage.createSystemPing(@intCast(i), 0, i),
                else => unreachable,
            }

            const sent = mailbox.send(msg);
            std.log.info("发送{s}消息: {}, type={}", .{ test_case.msg_type, sent, msg.msg_type });
        }
    }

    std.log.info("Mailbox大小: {}", .{mailbox.size()});

    // 接收并验证消息
    var received_count: u32 = 0;
    while (mailbox.receive()) |msg| {
        received_count += 1;

        std.log.info("接收消息{}: type={}, valid={}", .{ received_count, msg.msg_type, msg.validate() });

        if (msg.isString()) {
            std.log.info("  字符串内容: '{s}'", .{msg.getString()});
        } else if (msg.isInt()) {
            std.log.info("  整数内容: {}", .{msg.getInt()});
        } else if (msg.isFloat()) {
            std.log.info("  浮点数内容: {d:.2}", .{msg.getFloat()});
        } else if (msg.isSystem()) {
            std.log.info("  系统消息类型: {}", .{msg.msg_type});
        }

        pool.release(msg);
    }

    std.log.info("基础功能测试完成: 接收{}条消息", .{received_count});

    // 测试2: 批量操作性能
    std.log.info("\n🚀 测试2: 批量操作性能", .{});

    const batch_sizes = [_]u32{ 100, 500, 1000 };

    for (batch_sizes) |batch_size| {
        std.log.info("\n批量大小: {}", .{batch_size});

        // 创建批量消息
        var send_batch = MessageBatch.init();
        for (0..batch_size) |i| {
            if (pool.acquire()) |msg| {
                switch (i % 3) {
                    0 => msg.* = FastMessage.createUserString(@intCast(i), 0, i, "batch_test"),
                    1 => msg.* = FastMessage.createUserInt(@intCast(i), 0, i, @intCast(i)),
                    2 => msg.* = FastMessage.createUserFloat(@intCast(i), 0, i, @as(f64, @floatFromInt(i)) * 0.1),
                    else => unreachable,
                }

                if (!send_batch.add(msg)) {
                    pool.release(msg);
                    break;
                }
            }
        }

        // 批量发送
        const send_start = std.time.nanoTimestamp();
        const sent = mailbox.sendBatch(&send_batch);
        const send_end = std.time.nanoTimestamp();

        const send_time_us = @divTrunc(send_end - send_start, 1000);
        const send_rate = if (send_time_us > 0) @divTrunc(sent * 1000000, @as(u32, @intCast(send_time_us))) else 0;

        std.log.info("批量发送: {}条消息, {}μs, {}msg/s", .{ sent, send_time_us, send_rate });

        // 批量接收
        var total_received: u32 = 0;
        const recv_start = std.time.nanoTimestamp();

        while (total_received < sent) {
            var recv_batch = MessageBatch.init();
            const received = mailbox.receiveBatch(&recv_batch);

            if (received == 0) break;

            total_received += received;

            // 验证并释放消息
            for (recv_batch.getMessages()) |msg| {
                if (!msg.validate()) {
                    std.log.warn("接收到无效消息: type={}", .{msg.msg_type});
                }
                pool.release(msg);
            }
        }

        const recv_end = std.time.nanoTimestamp();
        const recv_time_us = @divTrunc(recv_end - recv_start, 1000);
        const recv_rate = if (recv_time_us > 0) @divTrunc(total_received * 1000000, @as(u32, @intCast(recv_time_us))) else 0;

        std.log.info("批量接收: {}条消息, {}μs, {}msg/s", .{ total_received, recv_time_us, recv_rate });

        // 释放未发送的消息
        if (sent < send_batch.count) {
            for (send_batch.getMessages()[sent..]) |msg| {
                pool.release(msg);
            }
        }
    }

    // 测试3: 持续吞吐量测试
    std.log.info("\n🔥 测试3: 持续吞吐量测试 (5秒)", .{});

    const test_duration_ms = 5000;
    const start_time = std.time.nanoTimestamp();
    var total_sent: u64 = 0;
    var total_received: u64 = 0;

    while (true) {
        const current_time = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(current_time - start_time, 1000000);

        if (elapsed_ms >= test_duration_ms) break;

        // 发送一批消息
        var batch = MessageBatch.init();
        for (0..100) |i| {
            if (pool.acquire()) |msg| {
                msg.* = FastMessage.createUserInt(@intCast(i), 0, total_sent + i, @intCast(total_sent + i));
                if (!batch.add(msg)) {
                    pool.release(msg);
                    break;
                }
            }
        }

        const sent = mailbox.sendBatch(&batch);
        total_sent += sent;

        // 释放未发送的消息
        if (sent < batch.count) {
            for (batch.getMessages()[sent..]) |msg| {
                pool.release(msg);
            }
        }

        // 接收消息
        var recv_batch = MessageBatch.init();
        const received = mailbox.receiveBatch(&recv_batch);
        total_received += received;

        // 释放接收的消息
        for (recv_batch.getMessages()) |msg| {
            pool.release(msg);
        }

        // 每秒报告一次
        if (@rem(elapsed_ms, 1000) == 0 and elapsed_ms > 0) {
            const current_send_rate = @divTrunc(total_sent * 1000, @as(u64, @intCast(elapsed_ms)));
            const current_recv_rate = @divTrunc(total_received * 1000, @as(u64, @intCast(elapsed_ms)));
            std.log.info("{}s: 发送{}msg ({}msg/s), 接收{}msg ({}msg/s), 队列:{}", .{ @divTrunc(elapsed_ms, 1000), total_sent, current_send_rate, total_received, current_recv_rate, mailbox.size() });
        }
    }

    // 处理剩余消息
    while (mailbox.receive()) |msg| {
        total_received += 1;
        pool.release(msg);
    }

    const final_time = std.time.nanoTimestamp();
    const total_time_ms = @divTrunc(final_time - start_time, 1000000);

    const final_send_rate = @divTrunc(total_sent * 1000, @as(u64, @intCast(total_time_ms)));
    const final_recv_rate = @divTrunc(total_received * 1000, @as(u64, @intCast(total_time_ms)));

    std.log.info("\n📊 持续吞吐量测试结果:", .{});
    std.log.info("总时间: {}ms", .{total_time_ms});
    std.log.info("总发送: {} 消息", .{total_sent});
    std.log.info("总接收: {} 消息", .{total_received});
    std.log.info("发送吞吐量: {} msg/s", .{final_send_rate});
    std.log.info("接收吞吐量: {} msg/s", .{final_recv_rate});
    std.log.info("消息完整性: {d:.2}%", .{@as(f64, @floatFromInt(total_received)) * 100.0 / @as(f64, @floatFromInt(total_sent))});

    // 最终统计
    const final_stats = mailbox.getStats();
    std.log.info("\n📈 Mailbox最终统计:", .{});
    std.log.info("累计发送: {}", .{final_stats.messages_sent});
    std.log.info("累计接收: {}", .{final_stats.messages_received});
    std.log.info("累计丢弃: {}", .{final_stats.messages_dropped});
    std.log.info("当前队列大小: {}", .{final_stats.current_size});
    std.log.info("队列容量: {}", .{final_stats.capacity});

    if (final_send_rate >= 1000000) {
        std.log.info("🎯 目标达成! 发送吞吐量超过1M msg/s", .{});
    } else {
        const percentage = @divTrunc(final_send_rate * 100, 1000000);
        std.log.info("📈 目标进度: {}% (目标: 1M msg/s)", .{percentage});
    }

    std.log.info("\n✅ === 高性能Mailbox验证完成 ===", .{});
}
