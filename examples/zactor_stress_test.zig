//! ZActor高性能压力测试
//! 专注于性能测试，最小化日志输出

const std = @import("std");
const zactor = @import("zactor");
const high_perf = zactor.HighPerf;

// 导入高性能Actor组件
const PerformanceConfig = high_perf.PerformanceConfig;
const ActorId = high_perf.ActorId;
const FastMessage = high_perf.FastMessage;
const Scheduler = high_perf.Scheduler;
const ActorTask = high_perf.ActorTask;

/// 静默Counter行为 - 减少日志输出
const SilentCounterBehavior = struct {
    name: []const u8,
    count: u32,

    pub fn init(name: []const u8) SilentCounterBehavior {
        return SilentCounterBehavior{
            .name = name,
            .count = 0,
        };
    }

    pub fn receive(self: *SilentCounterBehavior, message: FastMessage) !void {
        const data = message.getData();

        if (std.mem.eql(u8, data, "increment")) {
            self.count += 1;
            // 只在特定条件下输出日志
            if (self.count % 1000 == 0) {
                std.log.info("Counter '{s}' reached {}", .{ self.name, self.count });
            }
        } else if (std.mem.eql(u8, data, "get")) {
            // 静默获取，不输出
        }
    }

    pub fn getCount(self: *const SilentCounterBehavior) u32 {
        return self.count;
    }
};

// 静默Counter Actor类型
const SilentCounterActor = high_perf.Actor(SilentCounterBehavior, 65536);

const StressTestStats = struct {
    actor_count: u32,
    messages_sent: u64,
    messages_processed: u64,
    total_mailbox_size: u32,
    uptime_ms: i64,
    scheduler_stats: high_perf.SchedulerStats,

    pub fn getThroughput(self: *const StressTestStats) f64 {
        if (self.uptime_ms == 0) return 0.0;
        const uptime_s = @as(f64, @floatFromInt(self.uptime_ms)) / 1000.0;
        return @as(f64, @floatFromInt(self.messages_processed)) / uptime_s;
    }

    pub fn getSendThroughput(self: *const StressTestStats) f64 {
        if (self.uptime_ms == 0) return 0.0;
        const uptime_s = @as(f64, @floatFromInt(self.uptime_ms)) / 1000.0;
        return @as(f64, @floatFromInt(self.messages_sent)) / uptime_s;
    }

    pub fn getSuccessRate(self: *const StressTestStats) f64 {
        if (self.messages_sent == 0) return 0.0;
        return @as(f64, @floatFromInt(self.messages_processed)) / @as(f64, @floatFromInt(self.messages_sent)) * 100.0;
    }
};

/// 轻量级压力测试
fn runLightStressTest(allocator: std.mem.Allocator) !void {
    std.log.info("=== Light Stress Test (10K messages, 5 actors) ===", .{});

    const config = PerformanceConfig.ultraFast();
    var scheduler = try Scheduler.init(allocator, config);
    defer scheduler.deinit();

    try scheduler.start();

    // 创建5个Actor
    const actor_count = 5;
    var actors = std.ArrayList(*SilentCounterActor).init(allocator);
    defer {
        for (actors.items) |actor| {
            actor.deinit();
        }
        actors.deinit();
    }

    for (0..actor_count) |i| {
        const name = try std.fmt.allocPrint(allocator, "actor-{}", .{i});
        defer allocator.free(name);

        const behavior = SilentCounterBehavior.init(name);
        const id = ActorId.init(0, 0, @intCast(i + 1));

        const actor = try SilentCounterActor.init(allocator, id, behavior);
        try actor.start();
        try actors.append(actor);
    }

    std.log.info("Created {} actors", .{actor_count});

    // 发送10,000条消息
    const message_count = 10000;
    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;

    for (0..message_count) |i| {
        const actor_index = i % actor_count;
        const actor = actors.items[actor_index];

        const sender_id = ActorId.init(0, 0, 0);
        var message = FastMessage.init(sender_id, actor.id, .user);
        message.setData("increment");

        if (actor.send(message)) {
            messages_sent += 1;
        }
    }

    const send_time = std.time.nanoTimestamp();
    const send_duration_ms = @as(f64, @floatFromInt(send_time - start_time)) / 1_000_000.0;

    std.log.info("Sent {} messages in {d:.2} ms", .{ messages_sent, send_duration_ms });

    // 等待处理完成
    std.time.sleep(1000 * std.time.ns_per_ms);

    // 收集统计信息
    var total_messages_processed: u64 = 0;
    var total_mailbox_size: u32 = 0;

    for (actors.items) |actor| {
        const debug_info = actor.getDebugInfo();
        total_messages_processed += debug_info.message_count;
        total_mailbox_size += debug_info.mailbox_size;
    }

    const end_time = std.time.nanoTimestamp();
    const total_duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // 停止所有Actor
    for (actors.items) |actor| {
        try actor.stop();
    }

    try scheduler.stop();

    // 打印结果
    std.log.info("=== Light Stress Test Results ===", .{});
    std.log.info("Actors: {}", .{actor_count});
    std.log.info("Messages sent: {}", .{messages_sent});
    std.log.info("Messages processed: {}", .{total_messages_processed});
    std.log.info("Send duration: {d:.2} ms", .{send_duration_ms});
    std.log.info("Total duration: {d:.2} ms", .{total_duration_ms});
    std.log.info("Send throughput: {d:.2} msg/s", .{@as(f64, @floatFromInt(messages_sent)) / (send_duration_ms / 1000.0)});
    std.log.info("Process throughput: {d:.2} msg/s", .{@as(f64, @floatFromInt(total_messages_processed)) / (total_duration_ms / 1000.0)});
    std.log.info("Success rate: {d:.2}%", .{@as(f64, @floatFromInt(total_messages_processed)) / @as(f64, @floatFromInt(messages_sent)) * 100.0});
    std.log.info("Mailbox backlog: {}", .{total_mailbox_size});
}

/// 中等压力测试
fn runMediumStressTest(allocator: std.mem.Allocator) !void {
    std.log.info("=== Medium Stress Test (100K messages, 20 actors) ===", .{});

    const config = PerformanceConfig.ultraFast();
    var scheduler = try Scheduler.init(allocator, config);
    defer scheduler.deinit();

    try scheduler.start();

    // 创建20个Actor
    const actor_count = 20;
    var actors = std.ArrayList(*SilentCounterActor).init(allocator);
    defer {
        for (actors.items) |actor| {
            actor.deinit();
        }
        actors.deinit();
    }

    for (0..actor_count) |i| {
        const name = try std.fmt.allocPrint(allocator, "actor-{}", .{i});
        defer allocator.free(name);

        const behavior = SilentCounterBehavior.init(name);
        const id = ActorId.init(0, 0, @intCast(i + 1));

        const actor = try SilentCounterActor.init(allocator, id, behavior);
        try actor.start();
        try actors.append(actor);
    }

    std.log.info("Created {} actors", .{actor_count});

    // 发送100,000条消息
    const message_count = 100000;
    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;

    for (0..message_count) |i| {
        const actor_index = i % actor_count;
        const actor = actors.items[actor_index];

        const sender_id = ActorId.init(0, 0, 0);
        var message = FastMessage.init(sender_id, actor.id, .user);
        message.setData("increment");

        if (actor.send(message)) {
            messages_sent += 1;
        }
    }

    const send_time = std.time.nanoTimestamp();
    const send_duration_ms = @as(f64, @floatFromInt(send_time - start_time)) / 1_000_000.0;

    std.log.info("Sent {} messages in {d:.2} ms", .{ messages_sent, send_duration_ms });

    // 等待处理完成
    std.time.sleep(2000 * std.time.ns_per_ms);

    // 收集统计信息
    var total_messages_processed: u64 = 0;
    var total_mailbox_size: u32 = 0;

    for (actors.items) |actor| {
        const debug_info = actor.getDebugInfo();
        total_messages_processed += debug_info.message_count;
        total_mailbox_size += debug_info.mailbox_size;
    }

    const end_time = std.time.nanoTimestamp();
    const total_duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // 停止所有Actor
    for (actors.items) |actor| {
        try actor.stop();
    }

    try scheduler.stop();

    // 打印结果
    std.log.info("=== Medium Stress Test Results ===", .{});
    std.log.info("Actors: {}", .{actor_count});
    std.log.info("Messages sent: {}", .{messages_sent});
    std.log.info("Messages processed: {}", .{total_messages_processed});
    std.log.info("Send duration: {d:.2} ms", .{send_duration_ms});
    std.log.info("Total duration: {d:.2} ms", .{total_duration_ms});
    std.log.info("Send throughput: {d:.2} msg/s", .{@as(f64, @floatFromInt(messages_sent)) / (send_duration_ms / 1000.0)});
    std.log.info("Process throughput: {d:.2} msg/s", .{@as(f64, @floatFromInt(total_messages_processed)) / (total_duration_ms / 1000.0)});
    std.log.info("Success rate: {d:.2}%", .{@as(f64, @floatFromInt(total_messages_processed)) / @as(f64, @floatFromInt(messages_sent)) * 100.0});
    std.log.info("Mailbox backlog: {}", .{total_mailbox_size});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting ZActor stress tests...", .{});

    // 轻量级压力测试
    try runLightStressTest(allocator);

    std.log.info("\n" ++ "=" ** 50 ++ "\n", .{});

    // 中等压力测试
    try runMediumStressTest(allocator);

    std.log.info("\n=== All stress tests completed! ===", .{});
}
