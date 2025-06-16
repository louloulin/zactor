//! High-Performance Actor System Test
//! 测试新的高性能Actor系统实现

const std = @import("std");
const zactor = @import("zactor");
const high_perf = zactor.HighPerf;

// 导入高性能Actor组件
const PerformanceConfig = high_perf.PerformanceConfig;
const ActorId = high_perf.ActorId;
const FastMessage = high_perf.FastMessage;
const CounterBehavior = high_perf.CounterBehavior;
const CounterActor = high_perf.CounterActor;
const Scheduler = high_perf.Scheduler;
const ActorTask = high_perf.ActorTask;

/// 高性能Actor系统管理器
const HighPerfActorSystem = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    actors: std.ArrayList(*CounterActor),
    config: PerformanceConfig,

    // 统计信息
    start_time: i64,
    total_messages_sent: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: PerformanceConfig) !*Self {
        const system = try allocator.create(Self);
        const scheduler = try Scheduler.init(allocator, config);

        system.* = Self{
            .allocator = allocator,
            .scheduler = scheduler,
            .actors = std.ArrayList(*CounterActor).init(allocator),
            .config = config,
            .start_time = 0,
            .total_messages_sent = std.atomic.Value(u64).init(0),
        };

        return system;
    }

    pub fn deinit(self: *Self) void {
        // 清理所有Actor
        for (self.actors.items) |actor| {
            actor.deinit();
        }
        self.actors.deinit();

        // 清理调度器
        self.scheduler.deinit();

        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        try self.scheduler.start();
        self.start_time = std.time.milliTimestamp();
        std.log.info("High-performance actor system started", .{});
    }

    pub fn stop(self: *Self) !void {
        try self.scheduler.stop();
        std.log.info("High-performance actor system stopped", .{});
    }

    pub fn createActor(self: *Self, name: []const u8) !*CounterActor {
        const behavior = CounterBehavior.init(name);
        const id = ActorId.init(0, 0, @intCast(self.actors.items.len + 1));

        const actor = try CounterActor.init(self.allocator, id, behavior);
        try actor.start();

        try self.actors.append(actor);

        // 创建Actor处理任务并提交给调度器
        const task = ActorTask.init(actor, actorProcessWrapper);
        _ = self.scheduler.submit(task);

        return actor;
    }

    pub fn sendMessage(self: *Self, actor: *CounterActor, data: []const u8) bool {
        const sender_id = ActorId.init(0, 0, 0); // 系统发送者
        var message = FastMessage.init(sender_id, actor.id, .user);
        message.setData(data);

        if (actor.send(message)) {
            _ = self.total_messages_sent.fetchAdd(1, .monotonic);
            return true;
        }
        return false;
    }

    pub fn getStats(self: *const Self) SystemStats {
        const uptime = if (self.start_time > 0)
            std.time.milliTimestamp() - self.start_time
        else
            0;

        var total_messages_processed: u64 = 0;
        var total_mailbox_size: u32 = 0;

        for (self.actors.items) |actor| {
            total_messages_processed += actor.getMessageCount();
            total_mailbox_size += actor.getMailboxSize();
        }

        return SystemStats{
            .actor_count = @intCast(self.actors.items.len),
            .messages_sent = self.total_messages_sent.load(.monotonic),
            .messages_processed = total_messages_processed,
            .total_mailbox_size = total_mailbox_size,
            .uptime_ms = uptime,
            .scheduler_stats = self.scheduler.getStats(),
        };
    }

    pub fn printStats(self: *const Self) void {
        const stats = self.getStats();
        stats.print();

        std.log.info("\n=== Actor Details ===", .{});
        for (self.actors.items, 0..) |actor, i| {
            const debug_info = actor.getDebugInfo();
            std.log.info("Actor {}: {any}", .{ i, debug_info });
        }

        std.log.info("\n=== Scheduler Details ===", .{});
        self.scheduler.printStats();
    }
};

// Actor处理包装函数
fn actorProcessWrapper(actor_ptr: *anyopaque) u32 {
    const actor = @as(*CounterActor, @ptrCast(@alignCast(actor_ptr)));
    return actor.processMessages() catch 0;
}

const SystemStats = struct {
    actor_count: u32,
    messages_sent: u64,
    messages_processed: u64,
    total_mailbox_size: u32,
    uptime_ms: i64,
    scheduler_stats: high_perf.SchedulerStats,

    pub fn getThroughput(self: *const SystemStats) f64 {
        if (self.uptime_ms == 0) return 0.0;
        const uptime_s = @as(f64, @floatFromInt(self.uptime_ms)) / 1000.0;
        return @as(f64, @floatFromInt(self.messages_processed)) / uptime_s;
    }

    pub fn print(self: *const SystemStats) void {
        std.log.info("=== High-Performance Actor System Stats ===", .{});
        std.log.info("Actors: {}", .{self.actor_count});
        std.log.info("Messages sent: {}", .{self.messages_sent});
        std.log.info("Messages processed: {}", .{self.messages_processed});
        std.log.info("Total mailbox size: {}", .{self.total_mailbox_size});
        std.log.info("Uptime: {} ms", .{self.uptime_ms});
        std.log.info("System throughput: {d:.2} msg/s", .{self.getThroughput()});

        if (self.messages_sent > 0) {
            const success_rate = @as(f64, @floatFromInt(self.messages_processed)) / @as(f64, @floatFromInt(self.messages_sent)) * 100.0;
            std.log.info("Message success rate: {d:.2}%", .{success_rate});
        }
    }
};

/// 性能基准测试
fn runPerformanceBenchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== High-Performance Actor Benchmark ===", .{});

    // 使用超高性能配置
    const config = PerformanceConfig.ultraFast();

    var system = try HighPerfActorSystem.init(allocator, config);
    defer system.deinit();

    try system.start();

    // 创建多个Actor
    const actor_count = 10;
    var actors = std.ArrayList(*CounterActor).init(allocator);
    defer actors.deinit();

    for (0..actor_count) |i| {
        const name = try std.fmt.allocPrint(allocator, "counter-{}", .{i});
        defer allocator.free(name);

        const actor = try system.createActor(name);
        try actors.append(actor);
    }

    std.log.info("Created {} actors", .{actor_count});

    // 发送大量消息
    const message_count = 10000;
    const start_time = std.time.nanoTimestamp();

    for (0..message_count) |i| {
        const actor_index = i % actor_count;
        const actor = actors.items[actor_index];

        if (!system.sendMessage(actor, "increment")) {
            std.log.warn("Failed to send message {}", .{i});
        }

        // 每1000条消息打印一次进度
        if (i % 1000 == 0 and i > 0) {
            std.log.info("Sent {} messages", .{i});
        }
    }

    const send_time = std.time.nanoTimestamp();
    const send_duration_ms = @as(f64, @floatFromInt(send_time - start_time)) / 1_000_000.0;

    std.log.info("Sent {} messages in {d:.2} ms", .{ message_count, send_duration_ms });

    // 等待消息处理完成
    std.log.info("Waiting for message processing...", .{});
    std.time.sleep(1000 * std.time.ns_per_ms); // 等待1秒

    const end_time = std.time.nanoTimestamp();
    const total_duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // 打印最终统计
    system.printStats();

    const stats = system.getStats();
    std.log.info("\n=== Benchmark Results ===", .{});
    std.log.info("Total duration: {d:.2} ms", .{total_duration_ms});
    std.log.info("Send throughput: {d:.2} msg/s", .{@as(f64, @floatFromInt(message_count)) / (send_duration_ms / 1000.0)});
    std.log.info("Overall throughput: {d:.2} msg/s", .{stats.getThroughput()});

    try system.stop();
}

/// 简单功能测试
fn runSimpleTest(allocator: std.mem.Allocator) !void {
    std.log.info("=== Simple High-Performance Actor Test ===", .{});

    const config = PerformanceConfig.autoDetect();

    var system = try HighPerfActorSystem.init(allocator, config);
    defer system.deinit();

    try system.start();

    // 创建一个Actor
    const actor = try system.createActor("test-counter");

    // 发送一些消息
    _ = system.sendMessage(actor, "increment");
    _ = system.sendMessage(actor, "increment");
    _ = system.sendMessage(actor, "get");

    // 等待处理
    std.time.sleep(100 * std.time.ns_per_ms);

    // 打印统计
    system.printStats();

    try system.stop();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 运行简单测试
    try runSimpleTest(allocator);

    std.log.info("\n" ++ "=" ** 50 ++ "\n", .{});

    // 运行性能基准测试
    try runPerformanceBenchmark(allocator);
}
