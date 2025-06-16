const std = @import("std");
const Thread = std.Thread;

// Import the ultra high performance system
const UltraHighPerfSystem = @import("src/ultra_high_perf_system.zig").UltraHighPerfSystem;
const SystemConfig = @import("src/ultra_high_perf_system.zig").SystemConfig;
const HighPerfCounterActor = @import("src/example_actors.zig").HighPerfCounterActor;

// 渐进式性能测试 - 逐步增加负载验证稳定性
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🧪 === 渐进式性能验证测试 ===", .{});

    // 测试配置 - 从小负载开始逐步增加
    const test_configs = [_]struct {
        name: []const u8,
        actors: u32,
        worker_threads: u32,
        test_duration_s: u32,
        producer_threads: u32,
        target_throughput: u64, // msg/s
    }{
        .{ .name = "基础稳定性", .actors = 2, .worker_threads = 2, .test_duration_s = 3, .producer_threads = 1, .target_throughput = 10000 },
        .{ .name = "轻度负载", .actors = 4, .worker_threads = 2, .test_duration_s = 5, .producer_threads = 2, .target_throughput = 100000 },
        .{ .name = "中度负载", .actors = 8, .worker_threads = 4, .test_duration_s = 8, .producer_threads = 4, .target_throughput = 500000 },
        .{ .name = "高度负载", .actors = 16, .worker_threads = 8, .test_duration_s = 10, .producer_threads = 6, .target_throughput = 1000000 },
    };

    var all_passed = true;

    for (test_configs, 0..) |config, i| {
        std.log.info("\n🧪 === 测试 {}: {s} ===", .{ i + 1, config.name });
        std.log.info("配置: {} actors, {} workers, {}s, producers={}, 目标={}K msg/s", .{ config.actors, config.worker_threads, config.test_duration_s, config.producer_threads, config.target_throughput / 1000 });

        const test_passed = runProgressiveTest(allocator, config) catch |err| blk: {
            std.log.err("❌ 测试失败: {}", .{err});
            break :blk false;
        };

        if (test_passed) {
            std.log.info("✅ 测试通过: {s}", .{config.name});
        } else {
            std.log.warn("❌ 测试失败: {s}", .{config.name});
            all_passed = false;

            // 如果测试失败，停止后续测试
            std.log.warn("⚠️ 由于测试失败，停止后续测试", .{});
            break;
        }

        // 测试间隔，让系统恢复
        std.time.sleep(1000 * std.time.ns_per_ms);
    }

    if (all_passed) {
        std.log.info("\n🏆 === 所有渐进式测试通过！系统稳定性验证成功！ ===", .{});
    } else {
        std.log.warn("\n⚠️ === 部分测试失败，需要进一步优化 ===", .{});
    }
}

fn runProgressiveTest(
    allocator: std.mem.Allocator,
    config: anytype,
) !bool {
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

    // 创建计数器Actor
    var actors = std.ArrayList(@import("src/ultra_high_perf_system.zig").ActorRef).init(allocator);
    defer actors.deinit();

    for (0..config.actors) |i| {
        const name = try std.fmt.allocPrint(allocator, "Counter-{}", .{i});
        defer allocator.free(name);

        const counter = HighPerfCounterActor.init(name);
        const actor_ref = try system.spawn(HighPerfCounterActor, counter, name);
        try actors.append(actor_ref);
    }

    std.log.info("✅ 创建了 {} 个Actor", .{actors.items.len});

    // 等待Actor启动
    std.time.sleep(100 * std.time.ns_per_ms);

    // 启动生产者线程
    var producer_threads: [16]Thread = undefined;
    var producer_stats: [16]ProducerStats = undefined;

    var running = std.atomic.Value(bool).init(true);

    std.log.info("🚀 启动 {} 个生产者线程", .{config.producer_threads});

    // 启动生产者线程
    for (0..config.producer_threads) |i| {
        producer_stats[i] = ProducerStats.init();
        producer_threads[i] = try Thread.spawn(.{}, producerWorker, .{ i, actors.items, &running, &producer_stats[i] });
    }

    const test_start = std.time.nanoTimestamp();
    std.log.info("📊 开始 {} 秒性能测试...", .{config.test_duration_s});

    // 运行指定时间
    std.time.sleep(@as(u64, config.test_duration_s) * std.time.ns_per_s);

    // 停止生产者
    running.store(false, .release);
    std.log.info("🛑 停止生产者线程...", .{});

    // 等待生产者线程结束
    for (producer_threads[0..config.producer_threads]) |thread| {
        thread.join();
    }

    // 等待消息处理完成
    std.time.sleep(500 * std.time.ns_per_ms);

    const test_end = std.time.nanoTimestamp();
    const total_time_ms = @divTrunc(test_end - test_start, 1000000);

    // 收集统计
    var total_sent: u64 = 0;
    for (producer_stats[0..config.producer_threads]) |stats| {
        total_sent += stats.messages_sent.load(.monotonic);
    }

    // 获取系统统计
    const system_stats = system.getStats();
    _ = system.message_pool.getStats(); // 暂时不使用

    // 计算性能指标
    const send_throughput = @divTrunc(total_sent * 1000, @as(u64, @intCast(total_time_ms)));
    const process_throughput = @divTrunc(system_stats.messages_processed * 1000, @as(u64, @intCast(total_time_ms)));

    std.log.info("\n📊 === {s} 性能结果 ===", .{config.name});
    std.log.info("测试时间: {}ms", .{total_time_ms});
    std.log.info("总发送: {} 消息", .{total_sent});
    std.log.info("总处理: {} 消息", .{system_stats.messages_processed});
    std.log.info("发送吞吐量: {d:.1}K msg/s", .{@as(f64, @floatFromInt(send_throughput)) / 1000.0});
    std.log.info("处理吞吐量: {d:.1}K msg/s", .{@as(f64, @floatFromInt(process_throughput)) / 1000.0});
    std.log.info("消息完整性: {d:.2}%", .{@as(f64, @floatFromInt(system_stats.messages_processed)) * 100.0 / @as(f64, @floatFromInt(total_sent))});
    std.log.info("健康Actor: {}/{}", .{ system_stats.healthy_actors, system_stats.total_actors });

    // 验证测试是否通过
    const integrity = @as(f64, @floatFromInt(system_stats.messages_processed)) / @as(f64, @floatFromInt(total_sent));
    const throughput_ok = process_throughput >= config.target_throughput;
    const integrity_ok = integrity >= 0.95; // 95%以上的消息完整性
    const health_ok = system_stats.healthy_actors == system_stats.total_actors;

    const test_passed = throughput_ok and integrity_ok and health_ok;

    if (test_passed) {
        std.log.info("🎯 目标达成! 处理吞吐量 {d:.1}K 超过目标 {d:.1}K msg/s", .{ @as(f64, @floatFromInt(process_throughput)) / 1000.0, @as(f64, @floatFromInt(config.target_throughput)) / 1000.0 });
    } else {
        std.log.warn("❌ 测试失败原因:", .{});
        if (!throughput_ok) {
            std.log.warn("  - 吞吐量不足: {d:.1}K < {d:.1}K msg/s", .{ @as(f64, @floatFromInt(process_throughput)) / 1000.0, @as(f64, @floatFromInt(config.target_throughput)) / 1000.0 });
        }
        if (!integrity_ok) {
            std.log.warn("  - 消息完整性不足: {d:.2}% < 95%", .{integrity * 100.0});
        }
        if (!health_ok) {
            std.log.warn("  - Actor健康状态异常: {}/{}", .{ system_stats.healthy_actors, system_stats.total_actors });
        }
    }

    return test_passed;
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
) void {
    std.log.info("生产者线程 {} 启动", .{thread_id});

    var local_sent: u64 = 0;
    var message_counter: u64 = 0;

    while (running.load(.acquire)) {
        // 选择随机Actor
        const actor_idx = std.crypto.random.int(usize) % actors.len;
        const actor = actors[actor_idx];

        // 发送单个消息
        message_counter += 1;

        const sent = switch (message_counter % 3) {
            0 => actor.sendString("test_message") catch false,
            1 => actor.sendInt(@intCast(message_counter)) catch false,
            2 => actor.sendPing() catch false,
            else => unreachable,
        };

        if (sent) {
            local_sent += 1;
        }

        // 控制发送速率，避免过载
        if (local_sent % 1000 == 0) {
            std.time.sleep(1000); // 1微秒
        }
    }

    // 更新统计
    _ = stats.messages_sent.fetchAdd(local_sent, .monotonic);

    std.log.info("生产者线程 {} 结束: 发送 {} 消息", .{ thread_id, local_sent });
}
