const std = @import("std");
const Thread = std.Thread;

// Import the ultra high performance system
const UltraHighPerfSystem = @import("src/ultra_high_perf_system.zig").UltraHighPerfSystem;
const SystemConfig = @import("src/ultra_high_perf_system.zig").SystemConfig;
const BatchMessageData = @import("src/ultra_high_perf_system.zig").BatchMessageData;
const FastMessage = @import("src/message_pool.zig").FastMessage;

// Import example actors
const HighPerfCounterActor = @import("src/example_actors.zig").HighPerfCounterActor;
const HighPerfAggregatorActor = @import("src/example_actors.zig").HighPerfAggregatorActor;
const HighPerfBatchProcessorActor = @import("src/example_actors.zig").HighPerfBatchProcessorActor;

// 终极性能测试 - 目标: 100M+ msg/s
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === 终极性能测试 - 目标: 100M+ MSG/S ===", .{});

    // 测试配置
    const test_configs = [_]struct {
        name: []const u8,
        actors: u32,
        worker_threads: u32,
        test_duration_s: u32,
        batch_size: u32,
        target_throughput: u64, // msg/s
    }{
        .{ .name = "热身测试", .actors = 4, .worker_threads = 4, .test_duration_s = 5, .batch_size = 100, .target_throughput = 1000000 },
        .{ .name = "中等负载", .actors = 16, .worker_threads = 8, .test_duration_s = 10, .batch_size = 500, .target_throughput = 10000000 },
        .{ .name = "高负载", .actors = 64, .worker_threads = 16, .test_duration_s = 15, .batch_size = 1000, .target_throughput = 50000000 },
        .{ .name = "极限负载", .actors = 256, .worker_threads = 32, .test_duration_s = 20, .batch_size = 1000, .target_throughput = 100000000 },
    };

    for (test_configs) |config| {
        std.log.info("\n🧪 === {s} ===", .{config.name});
        std.log.info("配置: {} actors, {} workers, {}s, batch={}, 目标={}M msg/s", .{ config.actors, config.worker_threads, config.test_duration_s, config.batch_size, config.target_throughput / 1000000 });

        try runPerformanceTest(allocator, config);

        // 测试间隔
        std.time.sleep(2000 * std.time.ns_per_ms);
    }

    std.log.info("\n🏆 === 终极性能测试完成 ===", .{});
}

fn runPerformanceTest(
    allocator: std.mem.Allocator,
    config: anytype,
) !void {
    // 创建超高性能系统
    const system_config = SystemConfig{
        .worker_threads = config.worker_threads,
        .enable_work_stealing = true,
        .high_priority_ratio = 0.1,
    };

    var system = try UltraHighPerfSystem.init(allocator, system_config);
    defer system.deinit();

    // 启动系统
    try system.start();
    defer system.stop();

    // 创建不同类型的Actor
    var actors = std.ArrayList(@import("src/ultra_high_perf_system.zig").ActorRef).init(allocator);
    defer actors.deinit();

    // 创建计数器Actor (50%)
    const counter_count = config.actors / 2;
    for (0..counter_count) |i| {
        const name = try std.fmt.allocPrint(allocator, "Counter-{}", .{i});
        defer allocator.free(name);

        const counter = HighPerfCounterActor.init(name);
        const actor_ref = try system.spawn(HighPerfCounterActor, counter, name);
        try actors.append(actor_ref);
    }

    // 创建聚合器Actor (25%)
    const aggregator_count = config.actors / 4;
    for (0..aggregator_count) |i| {
        const name = try std.fmt.allocPrint(allocator, "Aggregator-{}", .{i});
        defer allocator.free(name);

        const aggregator = HighPerfAggregatorActor.init(name);
        const actor_ref = try system.spawn(HighPerfAggregatorActor, aggregator, name);
        try actors.append(actor_ref);
    }

    // 创建批处理Actor (25%)
    const batch_count = config.actors - counter_count - aggregator_count;
    for (0..batch_count) |i| {
        const name = try std.fmt.allocPrint(allocator, "BatchProcessor-{}", .{i});
        defer allocator.free(name);

        const batch_processor = HighPerfBatchProcessorActor.init(name);
        const actor_ref = try system.spawn(HighPerfBatchProcessorActor, batch_processor, name);
        try actors.append(actor_ref);
    }

    std.log.info("✅ 创建了 {} 个Actor", .{actors.items.len});

    // 等待Actor启动
    std.time.sleep(100 * std.time.ns_per_ms);

    // 启动多个生产者线程
    const producer_count = @min(config.worker_threads, 16);
    var producer_threads: [16]Thread = undefined;
    var producer_stats: [16]ProducerStats = undefined;

    var running = std.atomic.Value(bool).init(true);

    std.log.info("🚀 启动 {} 个生产者线程", .{producer_count});

    // 启动生产者线程
    for (0..producer_count) |i| {
        producer_stats[i] = ProducerStats.init();
        producer_threads[i] = try Thread.spawn(.{}, producerWorker, .{ i, actors.items, &running, &producer_stats[i], config.batch_size });
    }

    const test_start = std.time.nanoTimestamp();
    std.log.info("📊 开始 {} 秒性能测试...", .{config.test_duration_s});

    // 运行指定时间
    std.time.sleep(@as(u64, config.test_duration_s) * std.time.ns_per_s);

    // 停止生产者
    running.store(false, .release);
    std.log.info("🛑 停止生产者线程...", .{});

    // 等待生产者线程结束
    for (producer_threads[0..producer_count]) |thread| {
        thread.join();
    }

    // 等待消息处理完成
    std.time.sleep(1000 * std.time.ns_per_ms);

    const test_end = std.time.nanoTimestamp();
    const total_time_ms = @divTrunc(test_end - test_start, 1000000);

    // 收集统计
    var total_sent: u64 = 0;
    for (producer_stats[0..producer_count]) |stats| {
        total_sent += stats.messages_sent.load(.monotonic);
    }

    // 发送ping获取最终统计
    for (actors.items) |actor| {
        _ = try actor.sendPing();
    }
    std.time.sleep(100 * std.time.ns_per_ms);

    // 获取系统统计
    const system_stats = system.getStats();

    // 计算性能指标
    const send_throughput = @divTrunc(total_sent * 1000, @as(u64, @intCast(total_time_ms)));
    const process_throughput = @divTrunc(system_stats.messages_processed * 1000, @as(u64, @intCast(total_time_ms)));

    std.log.info("\n📊 === {s} 性能结果 ===", .{config.name});
    std.log.info("测试时间: {}ms", .{total_time_ms});
    std.log.info("总发送: {} 消息", .{total_sent});
    std.log.info("总处理: {} 消息", .{system_stats.messages_processed});
    std.log.info("发送吞吐量: {d:.1}M msg/s", .{@as(f64, @floatFromInt(send_throughput)) / 1000000.0});
    std.log.info("处理吞吐量: {d:.1}M msg/s", .{@as(f64, @floatFromInt(process_throughput)) / 1000000.0});
    std.log.info("消息完整性: {d:.2}%", .{@as(f64, @floatFromInt(system_stats.messages_processed)) * 100.0 / @as(f64, @floatFromInt(total_sent))});
    std.log.info("健康Actor: {}/{}", .{ system_stats.healthy_actors, system_stats.total_actors });

    // 目标达成检查
    if (process_throughput >= config.target_throughput) {
        std.log.info("🎯 目标达成! 处理吞吐量 {d:.1}M 超过目标 {d:.1}M msg/s", .{ @as(f64, @floatFromInt(process_throughput)) / 1000000.0, @as(f64, @floatFromInt(config.target_throughput)) / 1000000.0 });
    } else {
        const percentage = @divTrunc(process_throughput * 100, config.target_throughput);
        std.log.info("📈 目标进度: {}% ({d:.1}M / {d:.1}M msg/s)", .{ percentage, @as(f64, @floatFromInt(process_throughput)) / 1000000.0, @as(f64, @floatFromInt(config.target_throughput)) / 1000000.0 });
    }

    // 详细统计
    std.log.info("\n📈 详细统计:", .{});
    std.log.info("  Actor创建: {}", .{system_stats.actors_created.load(.monotonic)});
    std.log.info("  消息发送: {}", .{system_stats.messages_sent.load(.monotonic)});
    std.log.info("  消息丢弃: {}", .{system_stats.messages_dropped});
    std.log.info("  调度次数: {}", .{system_stats.total_scheduled});
}

// 生产者统计
const ProducerStats = struct {
    messages_sent: std.atomic.Value(u64),

    pub fn init() ProducerStats {
        return ProducerStats{
            .messages_sent = std.atomic.Value(u64).init(0),
        };
    }
};

// 生产者工作线程
fn producerWorker(
    thread_id: usize,
    actors: []@import("src/ultra_high_perf_system.zig").ActorRef,
    running: *std.atomic.Value(bool),
    stats: *ProducerStats,
    batch_size: u32,
) void {
    std.log.info("生产者线程 {} 启动", .{thread_id});

    var local_sent: u64 = 0;
    var message_counter: u64 = 0;

    while (running.load(.acquire)) {
        // 选择随机Actor
        const actor_idx = std.crypto.random.int(usize) % actors.len;
        const actor = actors[actor_idx];

        // 创建批量消息
        var batch_messages = std.ArrayList(BatchMessageData).init(std.heap.page_allocator);
        defer batch_messages.deinit();

        for (0..batch_size) |_| {
            message_counter += 1;

            const msg_data = switch (message_counter % 4) {
                0 => BatchMessageData{
                    .msg_type = .user_string,
                    .data = .{ .string = "high_perf_test" },
                },
                1 => BatchMessageData{
                    .msg_type = .user_int,
                    .data = .{ .int_val = @intCast(message_counter) },
                },
                2 => BatchMessageData{
                    .msg_type = .user_float,
                    .data = .{ .float_val = @as(f64, @floatFromInt(message_counter)) * 0.1 },
                },
                3 => BatchMessageData{
                    .msg_type = .system_ping,
                    .data = .{ .int_val = 0 },
                },
                else => unreachable,
            };

            batch_messages.append(msg_data) catch break;
        }

        // 发送批量消息
        const sent = actor.sendBatch(batch_messages.items) catch 0;
        local_sent += sent;

        // 偶尔让出CPU
        if (local_sent % 10000 == 0) {
            std.time.sleep(10); // 10纳秒
        }
    }

    // 更新统计
    _ = stats.messages_sent.fetchAdd(local_sent, .monotonic);

    std.log.info("生产者线程 {} 结束: 发送 {} 消息", .{ thread_id, local_sent });
}
