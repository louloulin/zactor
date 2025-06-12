const std = @import("std");
const Thread = std.Thread;
const FastMailbox = @import("src/fast_mailbox.zig").FastMailbox;
const FastMessage = @import("src/message_pool.zig").FastMessage;
const MessagePool = @import("src/message_pool.zig").MessagePool;
const MessageBatch = @import("src/message_pool.zig").MessageBatch;

// 30秒压力测试
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === 30秒压力测试 ===", .{});
    std.log.info("目标: 持续30秒高强度消息处理", .{});

    // 创建消息池和邮箱
    var pool = try MessagePool.init(allocator);
    defer pool.deinit();

    var mailbox = FastMailbox.init();
    defer mailbox.deinit();

    // 测试配置
    const test_duration_ms = 30 * 1000; // 30秒
    const num_producer_threads = 4;
    const num_consumer_threads = 2;
    const batch_size = 1000;

    std.log.info("配置: {} 生产者线程, {} 消费者线程", .{ num_producer_threads, num_consumer_threads });

    // 共享状态
    var running = std.atomic.Value(bool).init(true);
    var total_sent = std.atomic.Value(u64).init(0);
    var total_received = std.atomic.Value(u64).init(0);
    var total_dropped = std.atomic.Value(u64).init(0);

    // 启动生产者线程
    var producer_threads: [num_producer_threads]Thread = undefined;
    for (0..num_producer_threads) |i| {
        producer_threads[i] = try Thread.spawn(.{}, producerWorker, .{ i, &pool, &mailbox, &running, &total_sent, &total_dropped, batch_size });
    }

    // 启动消费者线程
    var consumer_threads: [num_consumer_threads]Thread = undefined;
    for (0..num_consumer_threads) |i| {
        consumer_threads[i] = try Thread.spawn(.{}, consumerWorker, .{ i, &pool, &mailbox, &running, &total_received, batch_size });
    }

    // 启动统计线程
    const stats_thread = try Thread.spawn(.{}, statsWorker, .{ &mailbox, &running, &total_sent, &total_received, &total_dropped });

    const start_time = std.time.nanoTimestamp();
    std.log.info("🏁 压力测试开始!", .{});

    // 运行30秒
    std.time.sleep(test_duration_ms * std.time.ns_per_ms);

    // 停止所有线程
    running.store(false, .release);
    std.log.info("🛑 停止信号发送", .{});

    // 等待所有线程结束
    for (producer_threads) |thread| {
        thread.join();
    }
    for (consumer_threads) |thread| {
        thread.join();
    }
    stats_thread.join();

    const end_time = std.time.nanoTimestamp();
    const actual_duration_ms = @divTrunc(end_time - start_time, 1000000);

    // 最终统计
    const final_sent = total_sent.load(.monotonic);
    const final_received = total_received.load(.monotonic);
    const final_dropped = total_dropped.load(.monotonic);
    const mailbox_stats = mailbox.getStats();

    std.log.info("\n🏆 === 30秒压力测试结果 ===", .{});
    std.log.info("实际运行时间: {}ms", .{actual_duration_ms});
    std.log.info("总发送消息: {}", .{final_sent});
    std.log.info("总接收消息: {}", .{final_received});
    std.log.info("总丢弃消息: {}", .{final_dropped});
    std.log.info("剩余队列: {}", .{mailbox_stats.current_size});

    // 计算吞吐量
    const send_throughput = @divTrunc(final_sent * 1000, @as(u64, @intCast(actual_duration_ms)));
    const recv_throughput = @divTrunc(final_received * 1000, @as(u64, @intCast(actual_duration_ms)));

    std.log.info("\n📊 性能指标:", .{});
    std.log.info("发送吞吐量: {} msg/s", .{send_throughput});
    std.log.info("接收吞吐量: {} msg/s", .{recv_throughput});
    std.log.info("消息成功率: {d:.2}%", .{@as(f64, @floatFromInt(final_received)) * 100.0 / @as(f64, @floatFromInt(final_sent))});
    std.log.info("消息丢失率: {d:.2}%", .{@as(f64, @floatFromInt(final_dropped)) * 100.0 / @as(f64, @floatFromInt(final_sent + final_dropped))});

    // 与目标对比
    const target_throughput = 1000000; // 1M msg/s
    if (send_throughput >= target_throughput) {
        std.log.info("🎯 目标达成! 发送吞吐量 {} 超过目标 {}", .{ send_throughput, target_throughput });
    } else {
        const percentage = @divTrunc(send_throughput * 100, target_throughput);
        std.log.info("📈 目标进度: {}% ({}M msg/s)", .{ percentage, @divTrunc(send_throughput, 1000000) });
    }

    std.log.info("✅ === 30秒压力测试完成 ===", .{});
}

// 生产者工作线程
fn producerWorker(
    thread_id: usize,
    pool: *MessagePool,
    mailbox: *FastMailbox,
    running: *std.atomic.Value(bool),
    total_sent: *std.atomic.Value(u64),
    total_dropped: *std.atomic.Value(u64),
    batch_size: u32,
) void {
    std.log.info("生产者线程 {} 启动", .{thread_id});

    var local_sent: u64 = 0;
    var local_dropped: u64 = 0;
    var message_counter: u64 = 0;

    while (running.load(.acquire)) {
        // 创建批量消息
        var batch = MessageBatch.init();

        for (0..batch_size) |_| {
            if (pool.acquire()) |msg| {
                message_counter += 1;

                // 创建不同类型的消息以测试类型安全性
                switch (message_counter % 4) {
                    0 => {
                        msg.* = FastMessage.createUserString(@intCast(thread_id), 0, message_counter, "stress_test");
                    },
                    1 => {
                        msg.* = FastMessage.createUserInt(@intCast(thread_id), 0, message_counter, @intCast(message_counter));
                    },
                    2 => {
                        msg.* = FastMessage.createUserFloat(@intCast(thread_id), 0, message_counter, @as(f64, @floatFromInt(message_counter)) * 0.1);
                    },
                    3 => {
                        msg.* = FastMessage.createSystemPing(@intCast(thread_id), 0, message_counter);
                    },
                    else => unreachable,
                }

                if (!batch.add(msg)) {
                    pool.release(msg);
                    break;
                }
            } else {
                // 消息池耗尽，稍等片刻
                std.time.sleep(1000); // 1微秒
                break;
            }
        }

        // 发送批量消息
        if (batch.count > 0) {
            const sent = mailbox.sendBatch(&batch);
            local_sent += sent;

            // 释放未发送的消息
            if (sent < batch.count) {
                local_dropped += (batch.count - sent);
                for (batch.getMessages()[sent..]) |msg| {
                    pool.release(msg);
                }
            }
        }

        // 偶尔让出CPU
        if (local_sent % 10000 == 0) {
            std.time.sleep(100); // 100纳秒
        }
    }

    // 更新全局统计
    _ = total_sent.fetchAdd(local_sent, .monotonic);
    _ = total_dropped.fetchAdd(local_dropped, .monotonic);

    std.log.info("生产者线程 {} 结束: 发送 {}, 丢弃 {}", .{ thread_id, local_sent, local_dropped });
}

// 消费者工作线程
fn consumerWorker(
    thread_id: usize,
    pool: *MessagePool,
    mailbox: *FastMailbox,
    running: *std.atomic.Value(bool),
    total_received: *std.atomic.Value(u64),
    batch_size: u32,
) void {
    _ = batch_size;
    std.log.info("消费者线程 {} 启动", .{thread_id});

    var local_received: u64 = 0;

    while (running.load(.acquire) or !mailbox.isEmpty()) {
        // 批量接收消息
        var batch = MessageBatch.init();
        const received = mailbox.receiveBatch(&batch);

        if (received > 0) {
            local_received += received;

            // 类型安全的消息处理
            for (batch.getMessages()) |msg| {
                // 使用类型安全的方法处理消息
                if (msg.isString()) {
                    _ = msg.getString(); // 安全访问字符串
                } else if (msg.isInt()) {
                    _ = msg.getInt(); // 安全访问整数
                } else if (msg.isFloat()) {
                    _ = msg.getFloat(); // 安全访问浮点数
                } else if (msg.isSystem()) {
                    // 处理系统消息 - 不访问payload
                } else {
                    // 处理其他类型
                }

                pool.release(msg);
            }
        } else {
            // 没有消息时短暂休眠
            std.time.sleep(1000); // 1微秒
        }
    }

    // 更新全局统计
    _ = total_received.fetchAdd(local_received, .monotonic);

    std.log.info("消费者线程 {} 结束: 接收 {}", .{ thread_id, local_received });
}

// 统计工作线程
fn statsWorker(
    mailbox: *FastMailbox,
    running: *std.atomic.Value(bool),
    total_sent: *std.atomic.Value(u64),
    total_received: *std.atomic.Value(u64),
    total_dropped: *std.atomic.Value(u64),
) void {
    std.log.info("统计线程启动", .{});

    var last_sent: u64 = 0;
    var last_received: u64 = 0;
    var last_time = std.time.nanoTimestamp();

    while (running.load(.acquire)) {
        std.time.sleep(5000 * std.time.ns_per_ms); // 每5秒报告一次

        const current_sent = total_sent.load(.monotonic);
        const current_received = total_received.load(.monotonic);
        const current_dropped = total_dropped.load(.monotonic);
        const current_time = std.time.nanoTimestamp();

        const elapsed_ms = @divTrunc(current_time - last_time, 1000000);
        const sent_rate = @divTrunc((current_sent - last_sent) * 1000, @as(u64, @intCast(elapsed_ms)));
        const recv_rate = @divTrunc((current_received - last_received) * 1000, @as(u64, @intCast(elapsed_ms)));

        const mailbox_stats = mailbox.getStats();

        std.log.info("📊 [{}s] 发送: {} ({} msg/s), 接收: {} ({} msg/s), 队列: {}, 丢弃: {}", .{
            @divTrunc(current_time - last_time, 1000000000), // 转换为秒
            current_sent,
            sent_rate,
            current_received,
            recv_rate,
            mailbox_stats.current_size,
            current_dropped,
        });

        last_sent = current_sent;
        last_received = current_received;
        last_time = current_time;
    }

    std.log.info("统计线程结束", .{});
}
