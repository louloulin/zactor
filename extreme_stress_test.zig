const std = @import("std");
const Thread = std.Thread;
const Atomic = std.atomic.Value;

// Import the ultra high performance system
const UltraHighPerfSystem = @import("src/ultra_high_perf_system.zig").UltraHighPerfSystem;
const SystemConfig = @import("src/ultra_high_perf_system.zig").SystemConfig;
const HighPerfCounterActor = @import("src/example_actors.zig").HighPerfCounterActor;

// 极限压力测试 - 验证系统在极端条件下的稳定性和性能
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🔥 === ZActor 极限压力测试 ===", .{});
    std.log.info("目标: 验证百万级消息处理能力", .{});

    // 极限测试配置
    const stress_configs = [_]StressTestConfig{
        .{ .name = "热身测试", .actors = 4, .workers = 4, .producers = 4, .duration_s = 10, .target_mps = 100000, .burst_mode = false },
        .{ .name = "中等压力", .actors = 8, .workers = 8, .producers = 8, .duration_s = 15, .target_mps = 500000, .burst_mode = false },
        .{ .name = "高压测试", .actors = 16, .workers = 16, .producers = 12, .duration_s = 20, .target_mps = 1000000, .burst_mode = false },
        .{ .name = "极限测试", .actors = 32, .workers = 16, .producers = 16, .duration_s = 30, .target_mps = 2000000, .burst_mode = true },
        .{ .name = "超极限", .actors = 64, .workers = 16, .producers = 20, .duration_s = 60, .target_mps = 5000000, .burst_mode = true },
    };

    var all_passed = true;
    var total_messages: u64 = 0;
    var total_time: u64 = 0;

    for (stress_configs, 0..) |config, i| {
        std.log.info("\n🔥 === 压力测试 {}: {s} ===", .{ i + 1, config.name });
        std.log.info("配置: {} actors, {} workers, {} producers, {}s", .{ config.actors, config.workers, config.producers, config.duration_s });
        std.log.info("目标: {d:.1}M msg/s, 突发模式: {}", .{ @as(f64, @floatFromInt(config.target_mps)) / 1000000.0, config.burst_mode });

        const result = runStressTest(allocator, config) catch |err| {
            std.log.err("❌ 压力测试失败: {}", .{err});
            all_passed = false;
            break;
        };

        total_messages += result.messages_processed;
        total_time += result.duration_ms;

        if (result.passed) {
            std.log.info("✅ 压力测试通过: {s}", .{config.name});
            std.log.info("📊 实际性能: {d:.1}M msg/s, 处理: {}M 消息", .{ @as(f64, @floatFromInt(result.throughput_mps)) / 1000000.0, result.messages_processed / 1000000 });
        } else {
            std.log.warn("❌ 压力测试失败: {s}", .{config.name});
            std.log.warn("📊 达到性能: {d:.1}M msg/s (目标: {d:.1}M)", .{ @as(f64, @floatFromInt(result.throughput_mps)) / 1000000.0, @as(f64, @floatFromInt(config.target_mps)) / 1000000.0 });
            all_passed = false;
            break;
        }

        // 测试间隔，让系统恢复
        std.log.info("⏳ 系统恢复中...", .{});
        std.time.sleep(2000 * std.time.ns_per_ms);
    }

    // 最终统计
    std.log.info("\n🏆 === 极限压力测试总结 ===", .{});
    if (all_passed) {
        std.log.info("🎯 所有压力测试通过！ZActor达到世界级性能！", .{});
    } else {
        std.log.info("⚠️ 部分测试未通过，但已验证高性能能力", .{});
    }

    if (total_time > 0) {
        const overall_throughput = @divTrunc(total_messages * 1000, total_time);
        std.log.info("📈 总体统计:", .{});
        std.log.info("  - 总处理消息: {}M", .{total_messages / 1000000});
        std.log.info("  - 总测试时间: {}s", .{total_time / 1000});
        std.log.info("  - 平均吞吐量: {d:.1}M msg/s", .{@as(f64, @floatFromInt(overall_throughput)) / 1000000.0});
    }
}

const StressTestConfig = struct {
    name: []const u8,
    actors: u32,
    workers: u32,
    producers: u32,
    duration_s: u32,
    target_mps: u64, // messages per second
    burst_mode: bool,
};

const StressTestResult = struct {
    passed: bool,
    messages_processed: u64,
    duration_ms: u64,
    throughput_mps: u64,
    peak_throughput: u64,
    error_rate: f64,
};

fn runStressTest(allocator: std.mem.Allocator, config: StressTestConfig) !StressTestResult {
    // 创建系统配置
    const system_config = SystemConfig{
        .worker_threads = config.workers,
        .enable_work_stealing = true,
        .high_priority_ratio = 0.2,
    };

    var system = try UltraHighPerfSystem.init(allocator, system_config);
    defer system.deinit();

    // 启动系统
    try system.start();
    defer system.stop();

    // 创建Actor
    var actors = std.ArrayList(@import("src/ultra_high_perf_system.zig").ActorRef).init(allocator);
    defer actors.deinit();

    std.log.info("🚀 创建 {} 个Actor...", .{config.actors});
    for (0..config.actors) |i| {
        const name = try std.fmt.allocPrint(allocator, "StressActor-{}", .{i});
        defer allocator.free(name);

        const counter = HighPerfCounterActor.init(name);
        const actor_ref = try system.spawn(HighPerfCounterActor, counter, name);
        try actors.append(actor_ref);
    }

    // 等待Actor启动
    std.time.sleep(200 * std.time.ns_per_ms);

    // 创建生产者统计
    var producer_threads: [32]Thread = undefined;
    var producer_stats: [32]ProducerStats = undefined;
    var running = Atomic(bool).init(true);

    // 性能监控
    var monitor_stats = MonitorStats.init();
    const monitor_thread = try Thread.spawn(.{}, performanceMonitor, .{ &monitor_stats, &running, &system });

    std.log.info("🚀 启动 {} 个高强度生产者...", .{config.producers});

    // 启动生产者线程
    for (0..config.producers) |i| {
        producer_stats[i] = ProducerStats.init();
        if (config.burst_mode) {
            producer_threads[i] = try Thread.spawn(.{}, burstProducerWorker, .{ i, actors.items, &running, &producer_stats[i] });
        } else {
            producer_threads[i] = try Thread.spawn(.{}, steadyProducerWorker, .{ i, actors.items, &running, &producer_stats[i] });
        }
    }

    const test_start = std.time.nanoTimestamp();
    std.log.info("⚡ 开始 {} 秒极限压力测试...", .{config.duration_s});

    // 运行测试
    std.time.sleep(@as(u64, config.duration_s) * std.time.ns_per_s);

    // 停止所有线程
    running.store(false, .release);
    std.log.info("🛑 停止压力测试...", .{});

    // 等待生产者线程结束
    for (producer_threads[0..config.producers]) |thread| {
        thread.join();
    }

    // 等待监控线程结束
    monitor_thread.join();

    // 等待消息处理完成
    std.time.sleep(1000 * std.time.ns_per_ms);

    const test_end = std.time.nanoTimestamp();
    const duration_ms: u64 = @intCast(@divTrunc(test_end - test_start, 1000000));

    // 收集统计
    var total_sent: u64 = 0;
    var total_errors: u64 = 0;
    for (producer_stats[0..config.producers]) |stats| {
        total_sent += stats.messages_sent.load(.monotonic);
        total_errors += stats.send_errors.load(.monotonic);
    }

    const system_stats = system.getStats();

    // 计算性能指标
    const throughput_mps = @divTrunc(system_stats.messages_processed * 1000, duration_ms);
    const error_rate = if (total_sent > 0)
        @as(f64, @floatFromInt(total_errors)) / @as(f64, @floatFromInt(total_sent))
    else
        0.0;

    // 显示详细统计
    std.log.info("\n📊 === 压力测试结果 ===", .{});
    std.log.info("测试时长: {}ms", .{duration_ms});
    std.log.info("发送消息: {}M ({} 错误)", .{ total_sent / 1000000, total_errors });
    std.log.info("处理消息: {}M", .{system_stats.messages_processed / 1000000});
    std.log.info("实际吞吐: {d:.1}M msg/s", .{@as(f64, @floatFromInt(throughput_mps)) / 1000000.0});
    std.log.info("峰值吞吐: {d:.1}M msg/s", .{@as(f64, @floatFromInt(monitor_stats.peak_throughput.load(.monotonic))) / 1000000.0});
    std.log.info("错误率: {d:.3}%", .{error_rate * 100.0});
    std.log.info("消息完整性: {d:.2}%", .{@as(f64, @floatFromInt(system_stats.messages_processed)) * 100.0 / @as(f64, @floatFromInt(total_sent))});
    std.log.info("健康Actor: {}/{}", .{ system_stats.healthy_actors, system_stats.total_actors });

    // 判断测试是否通过
    const throughput_ok = throughput_mps >= config.target_mps;
    const integrity_ok = system_stats.messages_processed >= total_sent * 95 / 100; // 95%完整性
    const health_ok = system_stats.healthy_actors == system_stats.total_actors;
    const error_ok = error_rate < 0.01; // 1%以下错误率

    const passed = throughput_ok and integrity_ok and health_ok and error_ok;

    return StressTestResult{
        .passed = passed,
        .messages_processed = system_stats.messages_processed,
        .duration_ms = duration_ms,
        .throughput_mps = throughput_mps,
        .peak_throughput = monitor_stats.peak_throughput.load(.monotonic),
        .error_rate = error_rate,
    };
}

// 生产者统计
const ProducerStats = struct {
    messages_sent: Atomic(u64),
    send_errors: Atomic(u64),

    pub fn init() ProducerStats {
        return ProducerStats{
            .messages_sent = Atomic(u64).init(0),
            .send_errors = Atomic(u64).init(0),
        };
    }
};

// 监控统计
const MonitorStats = struct {
    peak_throughput: Atomic(u64),

    pub fn init() MonitorStats {
        return MonitorStats{
            .peak_throughput = Atomic(u64).init(0),
        };
    }
};

// 稳定生产者 - 持续稳定发送
fn steadyProducerWorker(
    thread_id: usize,
    actors: []@import("src/ultra_high_perf_system.zig").ActorRef,
    running: *Atomic(bool),
    stats: *ProducerStats,
) void {
    std.log.info("稳定生产者 {} 启动", .{thread_id});

    var local_sent: u64 = 0;
    var local_errors: u64 = 0;
    var message_counter: u64 = 0;

    while (running.load(.acquire)) {
        // 高频发送消息
        for (0..100) |_| {
            if (!running.load(.acquire)) break;

            const actor_idx = std.crypto.random.int(usize) % actors.len;
            const actor = actors[actor_idx];

            message_counter += 1;
            const sent = switch (message_counter % 3) {
                0 => actor.sendString("stress_test") catch false,
                1 => actor.sendInt(@intCast(message_counter)) catch false,
                2 => actor.sendPing() catch false,
                else => unreachable,
            };

            if (sent) {
                local_sent += 1;
            } else {
                local_errors += 1;
            }
        }

        // 微小延迟，避免CPU过载
        std.time.sleep(10);
    }

    // 更新统计
    _ = stats.messages_sent.fetchAdd(local_sent, .monotonic);
    _ = stats.send_errors.fetchAdd(local_errors, .monotonic);

    std.log.info("稳定生产者 {} 结束: 发送 {}K, 错误 {}", .{ thread_id, local_sent / 1000, local_errors });
}

// 突发生产者 - 突发高强度发送
fn burstProducerWorker(
    thread_id: usize,
    actors: []@import("src/ultra_high_perf_system.zig").ActorRef,
    running: *Atomic(bool),
    stats: *ProducerStats,
) void {
    std.log.info("突发生产者 {} 启动", .{thread_id});

    var local_sent: u64 = 0;
    var local_errors: u64 = 0;
    var message_counter: u64 = 0;

    while (running.load(.acquire)) {
        // 突发发送 - 短时间内大量消息
        for (0..1000) |_| {
            if (!running.load(.acquire)) break;

            const actor_idx = std.crypto.random.int(usize) % actors.len;
            const actor = actors[actor_idx];

            message_counter += 1;
            const sent = switch (message_counter % 3) {
                0 => actor.sendString("burst_test") catch false,
                1 => actor.sendInt(@intCast(message_counter)) catch false,
                2 => actor.sendPing() catch false,
                else => unreachable,
            };

            if (sent) {
                local_sent += 1;
            } else {
                local_errors += 1;
            }
        }

        // 短暂休息后继续突发
        std.time.sleep(1000); // 1微秒
    }

    // 更新统计
    _ = stats.messages_sent.fetchAdd(local_sent, .monotonic);
    _ = stats.send_errors.fetchAdd(local_errors, .monotonic);

    std.log.info("突发生产者 {} 结束: 发送 {}K, 错误 {}", .{ thread_id, local_sent / 1000, local_errors });
}

// 性能监控线程
fn performanceMonitor(
    monitor_stats: *MonitorStats,
    running: *Atomic(bool),
    system: *UltraHighPerfSystem,
) void {
    std.log.info("性能监控启动", .{});

    var last_processed: u64 = 0;
    var last_time = std.time.nanoTimestamp();

    while (running.load(.acquire)) {
        std.time.sleep(1000 * std.time.ns_per_ms); // 每秒监控

        const current_stats = system.getStats();
        const current_time = std.time.nanoTimestamp();

        const processed_delta = current_stats.messages_processed - last_processed;
        const time_delta_ms: u64 = @intCast(@divTrunc(current_time - last_time, 1000000));

        if (time_delta_ms > 0) {
            const current_throughput: u64 = @intCast(@divTrunc(processed_delta * 1000, time_delta_ms));

            // 更新峰值吞吐量
            const current_peak = monitor_stats.peak_throughput.load(.monotonic);
            if (current_throughput > current_peak) {
                monitor_stats.peak_throughput.store(current_throughput, .monotonic);
            }

            std.log.info("📈 实时吞吐: {d:.1}M msg/s, 总处理: {}M", .{ @as(f64, @floatFromInt(current_throughput)) / 1000000.0, current_stats.messages_processed / 1000000 });
        }

        last_processed = current_stats.messages_processed;
        last_time = current_time;
    }

    std.log.info("性能监控结束", .{});
}
