const std = @import("std");
const Thread = std.Thread;

// Import components
const HighPerfScheduler = @import("src/high_perf_scheduler.zig").HighPerfScheduler;
const SchedulerConfig = @import("src/high_perf_scheduler.zig").SchedulerConfig;
const HighPerfActor = @import("src/high_perf_actor.zig").HighPerfActor;
const MessagePool = @import("src/message_pool.zig").MessagePool;

// 简单的测试Actor
const TestActor = struct {
    const Self = @This();

    name: []const u8,
    message_count: std.atomic.Value(u64),

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .message_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn receive(self: *Self, msg: *@import("src/message_pool.zig").FastMessage) bool {
        _ = msg;
        _ = self.message_count.fetchAdd(1, .monotonic);
        return true;
    }

    pub fn preStart(self: *Self) void {
        std.log.info("TestActor '{s}' starting", .{self.name});
    }

    pub fn preStop(self: *Self) void {
        std.log.info("TestActor '{s}' stopping", .{self.name});
    }

    pub fn postStop(self: *Self) void {
        std.log.info("TestActor '{s}' stopped", .{self.name});
    }

    pub fn preRestart(self: *Self, reason: anyerror) void {
        std.log.info("TestActor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self) void {
        std.log.info("TestActor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🔧 === 调度器调试测试 ===", .{});

    // 创建消息池
    var message_pool = try MessagePool.init(allocator);
    defer message_pool.deinit();

    // 创建调度器
    const config = SchedulerConfig{
        .worker_threads = 2,
        .enable_work_stealing = true,
    };

    const scheduler = try HighPerfScheduler.init(allocator, config);
    defer scheduler.deinit();

    std.log.info("✅ 调度器创建成功", .{});

    // 启动调度器
    try scheduler.start();
    std.log.info("✅ 调度器启动成功", .{});

    // 等待一段时间让Worker线程稳定
    std.time.sleep(100 * std.time.ns_per_ms);

    // 创建测试Actor
    const test_behavior = TestActor.init("TestActor-1");
    const behavior_ptr = try allocator.create(TestActor);
    behavior_ptr.* = test_behavior;
    defer allocator.destroy(behavior_ptr);

    const vtable = @import("src/high_perf_actor.zig").HighPerfActorBehavior(TestActor).getVTable();

    var actor = try allocator.create(HighPerfActor);
    defer allocator.destroy(actor);

    actor.* = HighPerfActor.init(
        1,
        "TestActor-1",
        behavior_ptr,
        &vtable,
        &message_pool,
        allocator,
    );

    std.log.info("✅ Actor创建成功", .{});

    // 启动Actor
    actor.start();
    std.log.info("✅ Actor启动成功", .{});

    // 调度Actor
    try scheduler.schedule(actor);
    std.log.info("✅ Actor调度成功", .{});

    // 创建一些测试消息
    for (0..10) |i| {
        if (message_pool.acquire()) |msg| {
            const sequence = message_pool.nextSequence();
            msg.* = @import("src/message_pool.zig").FastMessage.createUserString(1, 0, sequence, "test");

            if (actor.send(msg)) {
                std.log.info("✅ 消息 {} 发送成功", .{i});
                try scheduler.schedule(actor);
            } else {
                std.log.warn("❌ 消息 {} 发送失败", .{i});
                message_pool.release(msg);
            }
        }
    }

    std.log.info("📊 等待消息处理...", .{});
    std.time.sleep(1000 * std.time.ns_per_ms);

    // 获取统计
    const stats = scheduler.getStats();
    const actor_stats = actor.getStats();

    std.log.info("\n📊 === 调试结果 ===", .{});
    std.log.info("调度器统计:", .{});
    std.log.info("  高优先级调度: {}", .{stats.high_priority_scheduled.load(.monotonic)});
    std.log.info("  全局调度: {}", .{stats.global_scheduled.load(.monotonic)});
    std.log.info("  本地调度: {}", .{stats.local_scheduled.load(.monotonic)});
    std.log.info("  总处理: {}", .{stats.total_processed});

    std.log.info("Actor统计:", .{});
    std.log.info("  接收消息: {}", .{actor_stats.messages_received.load(.monotonic)});
    std.log.info("  处理消息: {}", .{actor_stats.messages_processed.load(.monotonic)});
    std.log.info("  丢弃消息: {}", .{actor_stats.messages_dropped.load(.monotonic)});

    // 停止Actor
    actor.stop();
    std.log.info("✅ Actor停止成功", .{});

    // 停止调度器
    scheduler.stop();
    std.log.info("✅ 调度器停止成功", .{});

    std.log.info("\n🏆 === 调试测试完成 ===", .{});
}
