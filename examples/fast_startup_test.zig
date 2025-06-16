//! 快速启动测试
//! 专门验证调度器启动优化的效果

const std = @import("std");
const zactor = @import("zactor");

/// 启动性能测试结果
const StartupResult = struct {
    config_name: []const u8,
    startup_time_ms: f64,
    actor_creation_time_ms: f64,
    first_message_time_ms: f64,
    total_time_ms: f64,

    pub fn print(self: *const StartupResult) void {
        std.debug.print("\n=== {s} ===\n", .{self.config_name});
        std.debug.print("Startup time: {d:.2} ms\n", .{self.startup_time_ms});
        std.debug.print("Actor creation: {d:.2} ms\n", .{self.actor_creation_time_ms});
        std.debug.print("First message: {d:.2} ms\n", .{self.first_message_time_ms});
        std.debug.print("Total time: {d:.2} ms\n", .{self.total_time_ms});

        if (self.startup_time_ms < 10) {
            std.debug.print("Status: 🟢 EXCELLENT (<10ms)\n", .{});
        } else if (self.startup_time_ms < 50) {
            std.debug.print("Status: 🟡 GOOD (<50ms)\n", .{});
        } else if (self.startup_time_ms < 100) {
            std.debug.print("Status: 🟠 POOR (<100ms)\n", .{});
        } else {
            std.debug.print("Status: 🔴 CRITICAL (>100ms)\n", .{});
        }
    }
};

/// 简单的测试Actor
const TestActor = struct {
    const Self = @This();

    name: []const u8,
    message_received: bool = false,

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
        };
    }

    pub fn createBehavior(context: *zactor.ActorContext) !*zactor.ActorBehavior {
        const behavior = try context.allocator.create(TestActorBehavior);
        behavior.* = TestActorBehavior{
            .behavior = zactor.ActorBehavior{
                .vtable = &TestActorBehavior.vtable,
            },
        };
        return &behavior.behavior;
    }
};

const TestActorBehavior = struct {
    const Self = @This();

    behavior: zactor.ActorBehavior,

    const vtable = zactor.ActorBehavior.VTable{
        .receive = receive,
        .preStart = preStart,
        .postStop = postStop,
        .preRestart = preRestart,
        .postRestart = postRestart,
        .supervisorStrategy = supervisorStrategy,
    };

    fn receive(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext, message: *zactor.Message) !void {
        _ = behavior;
        _ = context;

        if (message.isUser()) {
            // 快速处理消息
        }
    }

    fn preStart(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn postStop(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn preRestart(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("Actor restarting due to: {}", .{reason});
    }

    fn postRestart(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("Actor restarted after: {}", .{reason});
    }

    fn supervisorStrategy(behavior: *zactor.ActorBehavior) zactor.ActorBehavior.SupervisionStrategy {
        _ = behavior;
        return .resume_actor;
    }
};

/// 测试默认配置的启动性能
fn testDefaultStartup(allocator: std.mem.Allocator) !StartupResult {
    const total_start = std.time.nanoTimestamp();

    // 1. 系统启动
    const startup_start = std.time.nanoTimestamp();
    var system = try zactor.ActorSystem.init("default-test", zactor.Config.default(), allocator);
    defer system.deinit();

    try system.start();
    const startup_end = std.time.nanoTimestamp();

    // 2. Actor创建
    const creation_start = std.time.nanoTimestamp();
    const props = zactor.ActorProps.create(TestActor.createBehavior);
    const actor = try system.actorOf(props, "test-actor");
    const creation_end = std.time.nanoTimestamp();

    // 3. 消息发送
    const message_start = std.time.nanoTimestamp();
    try actor.send([]const u8, "test", allocator);
    std.time.sleep(10 * std.time.ns_per_ms); // 等待消息处理
    const message_end = std.time.nanoTimestamp();

    const total_end = std.time.nanoTimestamp();

    return StartupResult{
        .config_name = "Default Configuration",
        .startup_time_ms = @as(f64, @floatFromInt(startup_end - startup_start)) / 1_000_000.0,
        .actor_creation_time_ms = @as(f64, @floatFromInt(creation_end - creation_start)) / 1_000_000.0,
        .first_message_time_ms = @as(f64, @floatFromInt(message_end - message_start)) / 1_000_000.0,
        .total_time_ms = @as(f64, @floatFromInt(total_end - total_start)) / 1_000_000.0,
    };
}

/// 测试快速启动配置的性能
fn testFastStartup(allocator: std.mem.Allocator) !StartupResult {
    const total_start = std.time.nanoTimestamp();

    // 1. 系统启动
    const startup_start = std.time.nanoTimestamp();
    var system = try zactor.ActorSystem.init("fast-test", zactor.Config.fastStartup(), allocator);
    defer system.deinit();

    try system.start();
    const startup_end = std.time.nanoTimestamp();

    // 2. Actor创建
    const creation_start = std.time.nanoTimestamp();
    const props = zactor.ActorProps.create(TestActor.createBehavior);
    const actor = try system.actorOf(props, "test-actor");
    const creation_end = std.time.nanoTimestamp();

    // 3. 消息发送
    const message_start = std.time.nanoTimestamp();
    try actor.send([]const u8, "test", allocator);
    std.time.sleep(10 * std.time.ns_per_ms); // 等待消息处理
    const message_end = std.time.nanoTimestamp();

    const total_end = std.time.nanoTimestamp();

    return StartupResult{
        .config_name = "Fast Startup Configuration",
        .startup_time_ms = @as(f64, @floatFromInt(startup_end - startup_start)) / 1_000_000.0,
        .actor_creation_time_ms = @as(f64, @floatFromInt(creation_end - creation_start)) / 1_000_000.0,
        .first_message_time_ms = @as(f64, @floatFromInt(message_end - message_start)) / 1_000_000.0,
        .total_time_ms = @as(f64, @floatFromInt(total_end - total_start)) / 1_000_000.0,
    };
}

/// 测试高吞吐量配置的启动性能
fn testHighThroughputStartup(allocator: std.mem.Allocator) !StartupResult {
    const total_start = std.time.nanoTimestamp();

    // 1. 系统启动
    const startup_start = std.time.nanoTimestamp();
    var system = try zactor.ActorSystem.init("throughput-test", zactor.Config.production(), allocator);
    defer system.deinit();

    try system.start();
    const startup_end = std.time.nanoTimestamp();

    // 2. Actor创建
    const creation_start = std.time.nanoTimestamp();
    const props = zactor.ActorProps.create(TestActor.createBehavior);
    const actor = try system.actorOf(props, "test-actor");
    const creation_end = std.time.nanoTimestamp();

    // 3. 消息发送
    const message_start = std.time.nanoTimestamp();
    try actor.send([]const u8, "test", allocator);
    std.time.sleep(10 * std.time.ns_per_ms); // 等待消息处理
    const message_end = std.time.nanoTimestamp();

    const total_end = std.time.nanoTimestamp();

    return StartupResult{
        .config_name = "High Throughput Configuration",
        .startup_time_ms = @as(f64, @floatFromInt(startup_end - startup_start)) / 1_000_000.0,
        .actor_creation_time_ms = @as(f64, @floatFromInt(creation_end - creation_start)) / 1_000_000.0,
        .first_message_time_ms = @as(f64, @floatFromInt(message_end - message_start)) / 1_000_000.0,
        .total_time_ms = @as(f64, @floatFromInt(total_end - total_start)) / 1_000_000.0,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ZActor Fast Startup Test ===\n", .{});
    std.debug.print("Testing scheduler startup optimization...\n", .{});

    // 测试默认配置
    std.debug.print("\nTesting default configuration...\n", .{});
    const default_result = try testDefaultStartup(allocator);
    default_result.print();

    // 测试快速启动配置
    std.debug.print("\nTesting fast startup configuration...\n", .{});
    const fast_result = try testFastStartup(allocator);
    fast_result.print();

    // 测试高吞吐量配置
    std.debug.print("\nTesting high throughput configuration...\n", .{});
    const throughput_result = try testHighThroughputStartup(allocator);
    throughput_result.print();

    // 性能对比
    std.debug.print("\n=== Performance Comparison ===\n", .{});
    std.debug.print("Configuration           | Startup | Actor | Message | Total\n", .{});
    std.debug.print("------------------------|---------|-------|---------|-------\n", .{});
    std.debug.print("Default                 | {d:7.2} | {d:5.2} | {d:7.2} | {d:5.2}\n", .{
        default_result.startup_time_ms,
        default_result.actor_creation_time_ms,
        default_result.first_message_time_ms,
        default_result.total_time_ms,
    });
    std.debug.print("Fast Startup            | {d:7.2} | {d:5.2} | {d:7.2} | {d:5.2}\n", .{
        fast_result.startup_time_ms,
        fast_result.actor_creation_time_ms,
        fast_result.first_message_time_ms,
        fast_result.total_time_ms,
    });
    std.debug.print("High Throughput         | {d:7.2} | {d:5.2} | {d:7.2} | {d:5.2}\n", .{
        throughput_result.startup_time_ms,
        throughput_result.actor_creation_time_ms,
        throughput_result.first_message_time_ms,
        throughput_result.total_time_ms,
    });

    // 计算改进倍数
    const startup_improvement = default_result.startup_time_ms / fast_result.startup_time_ms;
    const total_improvement = default_result.total_time_ms / fast_result.total_time_ms;

    std.debug.print("\n=== Optimization Results ===\n", .{});
    std.debug.print("Startup time improvement: {d:.1}x faster\n", .{startup_improvement});
    std.debug.print("Total time improvement: {d:.1}x faster\n", .{total_improvement});

    if (fast_result.startup_time_ms < 20) {
        std.debug.print("🎉 SUCCESS! Fast startup achieved (<20ms)\n", .{});
    } else if (fast_result.startup_time_ms < 50) {
        std.debug.print("✅ GOOD! Significant improvement achieved\n", .{});
    } else {
        std.debug.print("⚠️  PARTIAL: Some improvement, but more optimization needed\n", .{});
    }
}
