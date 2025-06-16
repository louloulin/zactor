//! ZActor系统诊断工具
//! 专门用于诊断Actor系统的性能瓶颈

const std = @import("std");
const zactor = @import("zactor");
const print = std.debug.print;

/// 诊断结果
const DiagnosisResult = struct {
    component: []const u8,
    status: Status,
    performance: f64,
    issue: []const u8,

    const Status = enum {
        excellent,
        good,
        poor,
        critical,
    };

    pub fn print(self: *const DiagnosisResult) void {
        const status_icon = switch (self.status) {
            .excellent => "🟢",
            .good => "🟡",
            .poor => "🟠",
            .critical => "🔴",
        };

        std.debug.print("{s} {s}: {d:.1} - {s}\n", .{ status_icon, self.component, self.performance, self.issue });
    }
};

/// 诊断Actor系统启动时间
fn diagnoseActorSystemStartup(allocator: std.mem.Allocator) !DiagnosisResult {
    print("Diagnosing Actor System startup...\n", .{});

    const start_time = std.time.nanoTimestamp();

    var system = try zactor.ActorSystem.init("diagnosis", zactor.Config.default(), allocator);
    defer system.deinit();

    try system.start();

    const end_time = std.time.nanoTimestamp();
    const startup_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    const status: DiagnosisResult.Status = if (startup_time_ms < 10) .excellent else if (startup_time_ms < 50) .good else if (startup_time_ms < 200) .poor else .critical;

    const issue = switch (status) {
        .excellent => "Fast startup",
        .good => "Acceptable startup time",
        .poor => "Slow startup - check initialization",
        .critical => "Very slow startup - major issue",
    };

    return DiagnosisResult{
        .component = "System Startup",
        .status = status,
        .performance = startup_time_ms,
        .issue = issue,
    };
}

/// 诊断Actor创建时间
fn diagnoseActorCreation(allocator: std.mem.Allocator) !DiagnosisResult {
    print("Diagnosing Actor creation...\n", .{});

    var system = try zactor.ActorSystem.init("creation-test", zactor.Config.default(), allocator);
    defer system.deinit();
    try system.start();
    std.time.sleep(50 * std.time.ns_per_ms);

    const start_time = std.time.nanoTimestamp();

    // 创建简单Actor
    const props = zactor.ActorProps.create(struct {
        pub fn createBehavior(context: *zactor.ActorContext) !*zactor.ActorBehavior {
            const behavior = try context.allocator.create(SimpleActorBehavior);
            behavior.* = SimpleActorBehavior{
                .behavior = zactor.ActorBehavior{
                    .vtable = &SimpleActorBehavior.vtable,
                },
            };
            return &behavior.behavior;
        }
    }.createBehavior);

    _ = try system.actorOf(props, "test-actor");

    const end_time = std.time.nanoTimestamp();
    const creation_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    const status: DiagnosisResult.Status = if (creation_time_ms < 1) .excellent else if (creation_time_ms < 5) .good else if (creation_time_ms < 20) .poor else .critical;

    const issue = switch (status) {
        .excellent => "Fast actor creation",
        .good => "Acceptable creation time",
        .poor => "Slow creation - check actor initialization",
        .critical => "Very slow creation - major bottleneck",
    };

    return DiagnosisResult{
        .component = "Actor Creation",
        .status = status,
        .performance = creation_time_ms,
        .issue = issue,
    };
}

/// 简单Actor行为用于测试
const SimpleActorBehavior = struct {
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
        _ = message;
        // 什么都不做，只是接收消息
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

/// 诊断消息发送延迟
fn diagnoseMessageSending(allocator: std.mem.Allocator) !DiagnosisResult {
    print("Diagnosing message sending...\n", .{});

    var system = try zactor.ActorSystem.init("send-test", zactor.Config.default(), allocator);
    defer system.deinit();
    try system.start();
    std.time.sleep(50 * std.time.ns_per_ms);

    const props = zactor.ActorProps.create(struct {
        pub fn createBehavior(context: *zactor.ActorContext) !*zactor.ActorBehavior {
            const behavior = try context.allocator.create(SimpleActorBehavior);
            behavior.* = SimpleActorBehavior{
                .behavior = zactor.ActorBehavior{
                    .vtable = &SimpleActorBehavior.vtable,
                },
            };
            return &behavior.behavior;
        }
    }.createBehavior);
    const actor = try system.actorOf(props, "send-test-actor");
    std.time.sleep(50 * std.time.ns_per_ms);

    const num_sends = 10;
    const start_time = std.time.nanoTimestamp();

    for (0..num_sends) |i| {
        const message = try std.fmt.allocPrint(allocator, "test-{}", .{i});
        defer allocator.free(message);

        try actor.send([]const u8, message, allocator);
    }

    const end_time = std.time.nanoTimestamp();
    const total_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    const avg_send_time_ms = total_time_ms / @as(f64, @floatFromInt(num_sends));

    const status: DiagnosisResult.Status = if (avg_send_time_ms < 0.1) .excellent else if (avg_send_time_ms < 1) .good else if (avg_send_time_ms < 10) .poor else .critical;

    const issue = switch (status) {
        .excellent => "Fast message sending",
        .good => "Acceptable send latency",
        .poor => "Slow sending - check mailbox",
        .critical => "Very slow sending - major bottleneck",
    };

    return DiagnosisResult{
        .component = "Message Sending",
        .status = status,
        .performance = avg_send_time_ms,
        .issue = issue,
    };
}

/// 诊断调度器性能
fn diagnoseScheduler(allocator: std.mem.Allocator) !DiagnosisResult {
    print("Diagnosing scheduler...\n", .{});

    var system = try zactor.ActorSystem.init("scheduler-test", zactor.Config.default(), allocator);
    defer system.deinit();

    const start_time = std.time.nanoTimestamp();
    try system.start();

    // 等待调度器启动
    std.time.sleep(100 * std.time.ns_per_ms);

    const end_time = std.time.nanoTimestamp();
    const scheduler_startup_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    const status: DiagnosisResult.Status = if (scheduler_startup_ms < 20) .excellent else if (scheduler_startup_ms < 100) .good else if (scheduler_startup_ms < 500) .poor else .critical;

    const issue = switch (status) {
        .excellent => "Fast scheduler startup",
        .good => "Acceptable scheduler performance",
        .poor => "Slow scheduler - check implementation",
        .critical => "Scheduler not working properly",
    };

    return DiagnosisResult{
        .component = "Scheduler",
        .status = status,
        .performance = scheduler_startup_ms,
        .issue = issue,
    };
}

/// 运行完整的系统诊断
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== ZActor System Diagnosis ===\n", .{});
    print("Identifying performance bottlenecks...\n\n", .{});

    var results = std.ArrayList(DiagnosisResult).init(allocator);
    defer results.deinit();

    // 运行各项诊断
    try results.append(try diagnoseActorSystemStartup(allocator));
    try results.append(try diagnoseActorCreation(allocator));
    try results.append(try diagnoseMessageSending(allocator));
    try results.append(try diagnoseScheduler(allocator));

    // 输出诊断结果
    print("\n=== Diagnosis Results ===\n", .{});
    for (results.items) |result| {
        result.print();
    }

    // 总体评估
    var critical_count: u32 = 0;
    var poor_count: u32 = 0;

    for (results.items) |result| {
        switch (result.status) {
            .critical => critical_count += 1,
            .poor => poor_count += 1,
            else => {},
        }
    }

    print("\n=== Overall Assessment ===\n", .{});
    if (critical_count > 0) {
        print("🔴 CRITICAL: {} components have critical issues\n", .{critical_count});
        print("Immediate action required!\n", .{});
    } else if (poor_count > 0) {
        print("🟠 POOR: {} components have performance issues\n", .{poor_count});
        print("Optimization needed.\n", .{});
    } else {
        print("🟢 GOOD: All components are performing acceptably\n", .{});
    }

    print("\n=== Recommendations ===\n", .{});
    print("1. Focus on components with critical/poor status\n", .{});
    print("2. Check Actor message processing loops\n", .{});
    print("3. Verify scheduler is running properly\n", .{});
    print("4. Optimize mailbox implementation\n", .{});
    print("5. Profile memory allocation patterns\n", .{});
}
