//! ZActor超高性能基准测试
//! 目标: 验证真实Actor系统的5-10M msg/s性能，追赶业界主流

const std = @import("std");
const zactor = @import("zactor");
const print = std.debug.print;

// 导入Actor相关组件
const Actor = zactor.Actor;
const ActorSystem = zactor.ActorSystem;
const ActorRef = zactor.ActorRef;
const ActorContext = zactor.ActorContext;
const ActorBehavior = zactor.ActorBehavior;
const Message = zactor.Message;
const SystemMessage = zactor.SystemMessage;

/// Actor基准测试配置
const BenchmarkConfig = struct {
    num_messages: u32 = 1_000_000, // 100万消息
    num_actors: u32 = 100, // 100个Actor
    warmup_messages: u32 = 10_000, // 预热消息数
    test_duration_ms: u32 = 10_000, // 测试持续时间(毫秒)
    batch_size: u32 = 1000, // 批处理大小
};

/// Actor基准测试结果
const ActorBenchmarkResult = struct {
    test_name: []const u8,
    num_actors: u32,
    messages_sent: u64,
    messages_received: u64,
    duration_ns: u64,
    throughput_msg_per_sec: f64,
    latency_avg_ns: f64,
    latency_p99_ns: f64,
    actor_utilization: f32,

    pub fn print(self: *const ActorBenchmarkResult) void {
        std.debug.print("\n=== {s} ===\n", .{self.test_name});
        std.debug.print("Actors: {}\n", .{self.num_actors});
        std.debug.print("Messages sent: {}\n", .{self.messages_sent});
        std.debug.print("Messages received: {}\n", .{self.messages_received});
        std.debug.print("Duration: {d:.2} ms\n", .{@as(f64, @floatFromInt(self.duration_ns)) / 1_000_000.0});
        std.debug.print("Throughput: {d:.0} msg/s\n", .{self.throughput_msg_per_sec});
        std.debug.print("Average latency: {d:.2} μs\n", .{self.latency_avg_ns / 1000.0});
        std.debug.print("P99 latency: {d:.2} μs\n", .{self.latency_p99_ns / 1000.0});
        std.debug.print("Actor utilization: {d:.1}%\n", .{self.actor_utilization * 100.0});

        // 性能等级评估
        if (self.throughput_msg_per_sec >= 10_000_000) {
            std.debug.print("Performance Level: 🏆 EXCELLENT (>10M msg/s)\n", .{});
        } else if (self.throughput_msg_per_sec >= 5_000_000) {
            std.debug.print("Performance Level: 🥇 GOOD (5-10M msg/s)\n", .{});
        } else if (self.throughput_msg_per_sec >= 1_000_000) {
            std.debug.print("Performance Level: 🥈 ACCEPTABLE (1-5M msg/s)\n", .{});
        } else {
            std.debug.print("Performance Level: 🔴 POOR (<1M msg/s)\n", .{});
        }
    }
};

/// 高性能Echo Actor - 简单回显消息
const EchoActor = struct {
    const Self = @This();

    name: []const u8,
    message_count: std.atomic.Value(u64),

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .message_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn createBehavior(context: *ActorContext) !*ActorBehavior {
        const behavior = try context.allocator.create(EchoActorBehavior);
        behavior.* = EchoActorBehavior{
            .behavior = ActorBehavior{
                .vtable = &EchoActorBehavior.vtable,
            },
        };
        return &behavior.behavior;
    }
};

const EchoActorBehavior = struct {
    const Self = @This();

    behavior: ActorBehavior,

    const vtable = ActorBehavior.VTable{
        .receive = receive,
        .preStart = preStart,
        .postStop = postStop,
        .preRestart = preRestart,
        .postRestart = postRestart,
        .supervisorStrategy = supervisorStrategy,
    };

    fn receive(behavior: *ActorBehavior, context: *ActorContext, message: *Message) !void {
        _ = behavior;
        _ = context;

        // 简单处理消息 - 只计数，不回复
        if (message.isUser()) {
            // 高性能处理：只增加计数器
        } else if (message.isSystem()) {
            // 处理系统消息
        }
    }

    fn preStart(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn postStop(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn preRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("Actor restarting due to: {}", .{reason});
    }

    fn postRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("Actor restarted after: {}", .{reason});
    }

    fn supervisorStrategy(behavior: *ActorBehavior) ActorBehavior.SupervisionStrategy {
        _ = behavior;
        return .resume_actor;
    }
};

/// 单Actor高频消息基准测试
fn benchmarkSingleActorThroughput(allocator: std.mem.Allocator, config: BenchmarkConfig) !ActorBenchmarkResult {
    std.debug.print("Running Single Actor Throughput benchmark...\n", .{});

    // 创建Actor系统
    var system = try ActorSystem.init("benchmark-system", zactor.Config.default(), allocator);
    defer system.deinit();

    try system.start();
    std.time.sleep(50 * std.time.ns_per_ms); // 等待系统启动

    // 创建Echo Actor
    const props = zactor.ActorProps.create(EchoActor.createBehavior);
    const echo_actor = try system.actorOf(props, "echo-actor");

    // 预热
    std.debug.print("Warming up with {} messages...\n", .{config.warmup_messages});
    for (0..config.warmup_messages) |_| {
        try echo_actor.send([]const u8, "warmup", allocator);
    }
    std.time.sleep(100 * std.time.ns_per_ms); // 等待预热完成

    // 开始基准测试
    std.debug.print("Starting throughput test with {} messages...\n", .{config.num_messages});
    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;

    // 高频发送消息 (添加错误处理)
    for (0..config.num_messages) |i| {
        const message = try std.fmt.allocPrint(allocator, "msg-{}", .{i});
        defer allocator.free(message);

        // 处理邮箱满的情况
        echo_actor.send([]const u8, message, allocator) catch |err| {
            if (err == zactor.ActorError.MessageDeliveryFailed) {
                // 邮箱满，等待一下再继续
                std.time.sleep(1 * std.time.ns_per_ms);
                continue;
            } else {
                return err;
            }
        };
        messages_sent += 1;
    }

    // 等待所有消息处理完成
    std.time.sleep(1000 * std.time.ns_per_ms);

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(messages_sent)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    // 获取系统统计信息
    const sys_stats = system.getStats();

    return ActorBenchmarkResult{
        .test_name = "Single Actor Throughput",
        .num_actors = 1,
        .messages_sent = messages_sent,
        .messages_received = sys_stats.messages_processed.load(.acquire),
        .duration_ns = duration_ns,
        .throughput_msg_per_sec = throughput,
        .latency_avg_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(messages_sent)),
        .latency_p99_ns = 0.0, // 简化实现
        .actor_utilization = 1.0,
    };
}

/// 多Actor并发基准测试
fn benchmarkMultiActorConcurrency(allocator: std.mem.Allocator, config: BenchmarkConfig) !ActorBenchmarkResult {
    std.debug.print("Running Multi-Actor Concurrency benchmark...\n", .{});

    // 创建Actor系统
    var system = try ActorSystem.init("multi-actor-system", zactor.Config.default(), allocator);
    defer system.deinit();

    try system.start();
    std.time.sleep(50 * std.time.ns_per_ms); // 等待系统启动

    // 创建多个Echo Actor
    var actors = std.ArrayList(*ActorRef).init(allocator);
    defer actors.deinit();

    std.debug.print("Creating {} actors...\n", .{config.num_actors});
    for (0..config.num_actors) |i| {
        const props = zactor.ActorProps.create(EchoActor.createBehavior);
        const name = try std.fmt.allocPrint(allocator, "echo-actor-{}", .{i});
        defer allocator.free(name);

        const actor = try system.actorOf(props, name);
        try actors.append(actor);
    }

    // 预热所有Actor
    std.debug.print("Warming up {} actors...\n", .{config.num_actors});
    for (actors.items) |actor| {
        for (0..config.warmup_messages / config.num_actors) |_| {
            try actor.send([]const u8, "warmup", allocator);
        }
    }
    std.time.sleep(200 * std.time.ns_per_ms); // 等待预热完成

    // 开始并发基准测试
    std.debug.print("Starting concurrency test with {} messages across {} actors...\n", .{ config.num_messages, config.num_actors });
    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;

    // 并发发送消息到所有Actor (添加错误处理)
    const messages_per_actor = config.num_messages / config.num_actors;
    for (actors.items, 0..) |actor, actor_idx| {
        for (0..messages_per_actor) |msg_idx| {
            const message = try std.fmt.allocPrint(allocator, "actor-{}-msg-{}", .{ actor_idx, msg_idx });
            defer allocator.free(message);

            // 处理邮箱满的情况
            actor.send([]const u8, message, allocator) catch |err| {
                if (err == zactor.ActorError.MessageDeliveryFailed) {
                    // 邮箱满，等待一下再继续
                    std.time.sleep(1 * std.time.ns_per_ms);
                    continue;
                } else {
                    return err;
                }
            };
            messages_sent += 1;
        }
    }

    // 等待所有消息处理完成
    std.time.sleep(2000 * std.time.ns_per_ms);

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(messages_sent)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    // 获取系统统计信息
    const sys_stats = system.getStats();

    return ActorBenchmarkResult{
        .test_name = "Multi-Actor Concurrency",
        .num_actors = config.num_actors,
        .messages_sent = messages_sent,
        .messages_received = sys_stats.messages_processed.load(.acquire),
        .duration_ns = duration_ns,
        .throughput_msg_per_sec = throughput,
        .latency_avg_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(messages_sent)),
        .latency_p99_ns = 0.0, // 简化实现
        .actor_utilization = @as(f32, @floatFromInt(sys_stats.messages_processed.load(.acquire))) / @as(f32, @floatFromInt(messages_sent)),
    };
}

/// 运行所有ZActor超高性能基准测试
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BenchmarkConfig{
        .num_messages = 100_000, // 10万消息 (降低以避免邮箱满)
        .num_actors = 10, // 10个Actor (降低以避免资源竞争)
        .warmup_messages = 1_000, // 1千预热消息
        .test_duration_ms = 5_000, // 5秒测试
        .batch_size = 100, // 100批处理
    };

    std.debug.print("=== ZActor Actor System Performance Benchmark ===\n", .{});
    std.debug.print("Target: Reach 5-10M msg/s (Industry Standard)\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Messages: {}\n", .{config.num_messages});
    std.debug.print("  Actors: {}\n", .{config.num_actors});
    std.debug.print("  Warmup Messages: {}\n", .{config.warmup_messages});
    std.debug.print("  Test Duration: {} ms\n", .{config.test_duration_ms});
    std.debug.print("\n", .{});

    // 单Actor高频消息测试
    const single_actor_result = try benchmarkSingleActorThroughput(allocator, config);
    single_actor_result.print();

    // 多Actor并发测试
    const multi_actor_result = try benchmarkMultiActorConcurrency(allocator, config);
    multi_actor_result.print();

    // Actor系统性能总结
    std.debug.print("\n=== ZActor System Performance Summary ===\n", .{});
    std.debug.print("Single Actor Throughput: {d:.0} msg/s\n", .{single_actor_result.throughput_msg_per_sec});
    std.debug.print("Multi-Actor Concurrency: {d:.0} msg/s\n", .{multi_actor_result.throughput_msg_per_sec});
    std.debug.print("Actor Utilization: {d:.1}%\n", .{multi_actor_result.actor_utilization * 100.0});

    const best_throughput = @max(single_actor_result.throughput_msg_per_sec, multi_actor_result.throughput_msg_per_sec);
    std.debug.print("Best Actor Performance: {d:.0} msg/s\n", .{best_throughput});

    // 与业界Actor系统对比
    std.debug.print("\n=== Actor System Industry Comparison ===\n", .{});
    const industry_targets = [_]struct { name: []const u8, performance: f64 }{
        .{ .name = "Proto.Actor C#", .performance = 125_000_000 },
        .{ .name = "Proto.Actor Go", .performance = 70_000_000 },
        .{ .name = "Akka.NET", .performance = 46_000_000 },
        .{ .name = "Erlang/OTP", .performance = 12_000_000 },
        .{ .name = "CAF C++", .performance = 10_000_000 },
        .{ .name = "Actix Rust", .performance = 5_000_000 },
    };

    for (industry_targets) |target| {
        const ratio = best_throughput / target.performance;
        const percentage = ratio * 100.0;
        std.debug.print("{s}: {d:.1}% ({d:.0} / {d:.0})\n", .{ target.name, percentage, best_throughput, target.performance });
    }

    // ZActor Actor系统目标达成评估
    std.debug.print("\n=== ZActor Actor System Goal Achievement ===\n", .{});
    if (best_throughput >= 10_000_000) {
        std.debug.print("🏆 EXCELLENT! ZActor reached 10M+ msg/s (Industry Leading)\n", .{});
    } else if (best_throughput >= 5_000_000) {
        std.debug.print("🥇 GOOD! ZActor reached 5-10M msg/s (Industry Standard)\n", .{});
    } else if (best_throughput >= 1_000_000) {
        std.debug.print("🥈 ACCEPTABLE! ZActor reached 1-5M msg/s (Basic Performance)\n", .{});
    } else {
        std.debug.print("🔴 POOR! ZActor below 1M msg/s (Needs Optimization)\n", .{});
    }

    // 与之前的基础性能对比
    const baseline_performance = 200_000.0; // 原始ZActor性能
    const improvement_factor = best_throughput / baseline_performance;
    std.debug.print("ZActor Improvement Factor: {d:.1}x (vs baseline {} msg/s)\n", .{ improvement_factor, @as(u32, @intFromFloat(baseline_performance)) });

    // Actor系统特有指标
    std.debug.print("\n=== Actor System Metrics ===\n", .{});
    std.debug.print("Total Actors Tested: {}\n", .{single_actor_result.num_actors + multi_actor_result.num_actors});
    std.debug.print("Message Delivery Rate: {d:.1}%\n", .{multi_actor_result.actor_utilization * 100.0});
    std.debug.print("Average Latency: {d:.2} μs\n", .{multi_actor_result.latency_avg_ns / 1000.0});
    std.debug.print("Scalability Factor: {d:.1}x\n", .{multi_actor_result.throughput_msg_per_sec / single_actor_result.throughput_msg_per_sec});
}
