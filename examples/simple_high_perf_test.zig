//! 简化的高性能Actor测试
//! 专注于验证资源管理修复

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

/// 简化的高性能Actor系统测试
fn runSimpleResourceTest(allocator: std.mem.Allocator) !void {
    std.log.info("=== Simple Resource Management Test ===", .{});

    // 使用自动检测配置
    const config = PerformanceConfig.autoDetect();

    var scheduler = try Scheduler.init(allocator, config);
    defer scheduler.deinit();

    try scheduler.start();
    std.log.info("Scheduler started successfully", .{});

    // 创建一个Actor
    const behavior = CounterBehavior.init("test-counter");
    const id = ActorId.init(0, 0, 1);

    var actor = try CounterActor.init(allocator, id, behavior);
    defer actor.deinit();

    try actor.start();
    std.log.info("Actor started successfully", .{});

    // 发送一些消息
    const sender_id = ActorId.init(0, 0, 0);

    var message1 = FastMessage.init(sender_id, id, .user);
    message1.setData("increment");
    _ = actor.send(message1);

    var message2 = FastMessage.init(sender_id, id, .user);
    message2.setData("increment");
    _ = actor.send(message2);

    var message3 = FastMessage.init(sender_id, id, .user);
    message3.setData("get");
    _ = actor.send(message3);

    std.log.info("Sent 3 messages", .{});

    // 手动处理消息（不使用循环任务）
    const processed1 = try actor.processMessages();
    std.log.info("First batch processed: {} messages", .{processed1});

    const processed2 = try actor.processMessages();
    std.log.info("Second batch processed: {} messages", .{processed2});

    // 等待一小段时间
    std.time.sleep(50 * std.time.ns_per_ms);

    // 打印Actor统计
    const debug_info = actor.getDebugInfo();
    std.log.info("Actor processed {} messages total", .{debug_info.message_count});
    std.log.info("Mailbox size: {}", .{debug_info.mailbox_size});

    // 停止Actor
    try actor.stop();
    std.log.info("Actor stopped successfully", .{});

    // 停止调度器
    try scheduler.stop();
    std.log.info("Scheduler stopped successfully", .{});

    std.log.info("=== Test completed successfully ===", .{});
}

/// 测试引用计数机制
fn testRefCounting(allocator: std.mem.Allocator) !void {
    std.log.info("=== Reference Counting Test ===", .{});

    // 模拟ActorLoopData的引用计数
    const TestData = struct {
        value: u32,
        ref_count: std.atomic.Value(u32),
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, value: u32) *@This() {
            const self = alloc.create(@This()) catch unreachable;
            self.* = @This(){
                .value = value,
                .ref_count = std.atomic.Value(u32).init(1),
                .allocator = alloc,
            };
            return self;
        }

        pub fn addRef(self: *@This()) void {
            _ = self.ref_count.fetchAdd(1, .acq_rel);
        }

        pub fn release(self: *@This()) void {
            const old_count = self.ref_count.fetchSub(1, .acq_rel);
            if (old_count == 1) {
                std.log.info("Releasing TestData with value: {}", .{self.value});
                self.allocator.destroy(self);
            }
        }

        pub fn getRefCount(self: *const @This()) u32 {
            return self.ref_count.load(.acquire);
        }
    };

    // 创建测试数据
    var data = TestData.init(allocator, 42);
    std.log.info("Created TestData with ref count: {}", .{data.getRefCount()});

    // 增加引用
    data.addRef();
    std.log.info("After addRef, ref count: {}", .{data.getRefCount()});

    data.addRef();
    std.log.info("After second addRef, ref count: {}", .{data.getRefCount()});

    // 释放引用
    data.release();
    std.log.info("After first release, ref count: {}", .{data.getRefCount()});

    data.release();
    std.log.info("After second release, ref count: {}", .{data.getRefCount()});

    // 最后一次释放会自动销毁对象
    data.release();
    std.log.info("Final release completed (object should be destroyed)", .{});

    std.log.info("=== Reference counting test completed ===", .{});
}

/// 测试SPSC队列的安全性
fn testQueueSafety(allocator: std.mem.Allocator) !void {
    std.log.info("=== Queue Safety Test ===", .{});

    const TestQueue = high_perf.SPSCQueue(u32, 16);
    var queue = TestQueue.init();

    // 测试基本操作
    std.log.info("Queue initialized, size: {}", .{queue.size()});

    // 推入一些数据
    for (0..10) |i| {
        const success = queue.push(@intCast(i));
        std.log.info("Push {}: {}", .{ i, success });
    }

    std.log.info("After pushes, queue size: {}", .{queue.size()});

    // 弹出数据
    var pop_count: u32 = 0;
    while (queue.pop()) |value| {
        std.log.info("Popped: {}", .{value});
        pop_count += 1;
        if (pop_count >= 5) break; // 只弹出5个
    }

    std.log.info("After pops, queue size: {}", .{queue.size()});

    // 测试溢出保护
    for (0..20) |i| {
        const success = queue.push(@intCast(i + 100));
        if (!success) {
            std.log.info("Queue full at iteration {}", .{i});
            break;
        }
    }

    std.log.info("Final queue size: {}", .{queue.size()});
    std.log.info("=== Queue safety test completed ===", .{});

    _ = allocator; // 避免未使用警告
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting simplified high-performance Actor tests...", .{});

    // 测试引用计数机制
    try testRefCounting(allocator);

    std.log.info("\n" ++ "=" ** 30 ++ "\n", .{});

    // 测试队列安全性
    try testQueueSafety(allocator);

    std.log.info("\n" ++ "=" ** 30 ++ "\n", .{});

    // 测试简化的资源管理
    try runSimpleResourceTest(allocator);

    std.log.info("\n=== All tests completed successfully! ===", .{});
}
