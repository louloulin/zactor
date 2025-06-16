//! 简单的ZActor性能基准测试
//! 专注于验证真实的Actor系统性能

const std = @import("std");
const zactor = @import("zactor");
const print = std.debug.print;

/// 简单的计数器Actor
const CounterActor = struct {
    const Self = @This();
    
    name: []const u8,
    count: u32,
    
    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .count = 0,
        };
    }
    
    pub fn createBehavior(context: *zactor.ActorContext) !*zactor.ActorBehavior {
        const behavior = try context.allocator.create(CounterActorBehavior);
        behavior.* = CounterActorBehavior{
            .behavior = zactor.ActorBehavior{
                .vtable = &CounterActorBehavior.vtable,
            },
        };
        return &behavior.behavior;
    }
};

const CounterActorBehavior = struct {
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
            // 处理用户消息 - 简单计数
            print(".", .{});
        } else if (message.isSystem()) {
            // 处理系统消息
            print("S", .{});
        }
    }
    
    fn preStart(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext) !void {
        _ = behavior;
        _ = context;
        print("Actor started\n", .{});
    }
    
    fn postStop(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext) !void {
        _ = behavior;
        _ = context;
        print("Actor stopped\n", .{});
    }
    
    fn preRestart(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        print("Actor restarting due to: {}\n", .{reason});
    }
    
    fn postRestart(behavior: *zactor.ActorBehavior, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        print("Actor restarted after: {}\n", .{reason});
    }
    
    fn supervisorStrategy(behavior: *zactor.ActorBehavior) zactor.ActorBehavior.SupervisionStrategy {
        _ = behavior;
        return .resume_actor;
    }
};

/// 简单的Actor性能测试
fn simpleActorPerformanceTest(allocator: std.mem.Allocator) !void {
    print("=== Simple ZActor Performance Test ===\n", .{});
    
    // 创建Actor系统
    var system = try zactor.ActorSystem.init("perf-test", zactor.Config.default(), allocator);
    defer system.deinit();
    
    print("Starting actor system...\n", .{});
    try system.start();
    
    // 等待系统启动
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // 创建一个简单的Actor
    print("Creating counter actor...\n", .{});
    const props = zactor.ActorProps.create(CounterActor.createBehavior);
    const counter = try system.actorOf(props, "counter");
    
    // 等待Actor启动
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // 发送少量测试消息
    const num_messages = 10;
    print("Sending {} test messages...\n", .{num_messages});
    
    const start_time = std.time.nanoTimestamp();
    
    for (0..num_messages) |i| {
        const message = try std.fmt.allocPrint(allocator, "test-{}", .{i});
        defer allocator.free(message);
        
        counter.send([]const u8, message, allocator) catch |err| {
            print("Failed to send message {}: {}\n", .{ i, err });
            continue;
        };
        
        // 小延迟避免邮箱满
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    
    // 等待消息处理
    print("\nWaiting for message processing...\n", .{});
    std.time.sleep(1000 * std.time.ns_per_ms);
    
    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    
    print("\n=== Results ===\n", .{});
    print("Messages sent: {}\n", .{num_messages});
    print("Duration: {d:.2} ms\n", .{duration_ms});
    
    if (duration_ms > 0) {
        const throughput = @as(f64, @floatFromInt(num_messages)) / (duration_ms / 1000.0);
        print("Throughput: {d:.0} msg/s\n", .{throughput});
    }
    
    // 获取系统统计
    const stats = system.getStats();
    print("System stats:\n", .{});
    print("  Messages sent: {}\n", .{stats.messages_sent.load(.acquire)});
    print("  Messages processed: {}\n", .{stats.messages_processed.load(.acquire)});
    print("  Active actors: {}\n", .{stats.active_actors.load(.acquire)});
    
    print("Test completed!\n", .{});
}

/// 基础消息传递测试
fn basicMessageTest(allocator: std.mem.Allocator) !void {
    print("\n=== Basic Message Test ===\n", .{});
    
    // 创建Actor系统
    var system = try zactor.ActorSystem.init("basic-test", zactor.Config.default(), allocator);
    defer system.deinit();
    
    try system.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    
    // 创建Actor
    const props = zactor.ActorProps.create(CounterActor.createBehavior);
    const actor = try system.actorOf(props, "basic-counter");
    std.time.sleep(50 * std.time.ns_per_ms);
    
    // 发送单个消息
    print("Sending single message...\n", .{});
    try actor.send([]const u8, "hello", allocator);
    
    // 等待处理
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // 发送系统消息
    print("Sending system ping...\n", .{});
    try actor.sendSystem(.ping);
    
    // 等待处理
    std.time.sleep(100 * std.time.ns_per_ms);
    
    print("Basic test completed!\n", .{});
}

/// 压力测试 - 逐步增加消息数量
fn stressTest(allocator: std.mem.Allocator) !void {
    print("\n=== Stress Test ===\n", .{});
    
    const test_sizes = [_]u32{ 1, 5, 10, 20, 50 };
    
    for (test_sizes) |size| {
        print("\nTesting with {} messages...\n", .{size});
        
        var system = try zactor.ActorSystem.init("stress-test", zactor.Config.default(), allocator);
        defer system.deinit();
        
        try system.start();
        std.time.sleep(50 * std.time.ns_per_ms);
        
        const props = zactor.ActorProps.create(CounterActor.createBehavior);
        const actor = try system.actorOf(props, "stress-counter");
        std.time.sleep(50 * std.time.ns_per_ms);
        
        const start_time = std.time.nanoTimestamp();
        var sent_count: u32 = 0;
        
        for (0..size) |i| {
            const message = try std.fmt.allocPrint(allocator, "stress-{}", .{i});
            defer allocator.free(message);
            
            actor.send([]const u8, message, allocator) catch |err| {
                print("Send failed at {}: {}\n", .{ i, err });
                break;
            };
            sent_count += 1;
            
            // 适应性延迟
            if (size > 10) {
                std.time.sleep(5 * std.time.ns_per_ms);
            } else {
                std.time.sleep(20 * std.time.ns_per_ms);
            }
        }
        
        // 等待处理完成
        std.time.sleep(500 * std.time.ns_per_ms);
        
        const end_time = std.time.nanoTimestamp();
        const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
        
        print("  Sent: {}/{}, Duration: {d:.2} ms", .{ sent_count, size, duration_ms });
        
        if (duration_ms > 0 and sent_count > 0) {
            const throughput = @as(f64, @floatFromInt(sent_count)) / (duration_ms / 1000.0);
            print(", Throughput: {d:.0} msg/s", .{throughput});
        }
        print("\n", .{});
        
        const stats = system.getStats();
        print("  System: sent={}, processed={}\n", .{
            stats.messages_sent.load(.acquire),
            stats.messages_processed.load(.acquire),
        });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("ZActor Simple Performance Benchmark\n", .{});
    print("====================================\n", .{});
    
    // 基础消息测试
    try basicMessageTest(allocator);
    
    // 简单性能测试
    try simpleActorPerformanceTest(allocator);
    
    // 压力测试
    try stressTest(allocator);
    
    print("\n=== Benchmark Summary ===\n", .{});
    print("All tests completed successfully!\n", .{});
    print("Note: This is a basic functionality test.\n", .{});
    print("For high-performance testing, the Actor system\n", .{});
    print("needs proper message processing loops and scheduling.\n", .{});
}
