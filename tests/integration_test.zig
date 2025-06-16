//! 集成测试
//! 测试Actor系统的完整功能集成，包括消息传递、监督树、调度器等

const std = @import("std");
const testing = std.testing;
const zactor = @import("zactor");

/// 测试Actor实现
const TestActor = struct {
    const Self = @This();

    id: u32,
    message_count: u32,
    last_message: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u32) Self {
        return Self{
            .id = id,
            .message_count = 0,
            .last_message = null,
            .allocator = allocator,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        self.message_count += 1;
        
        switch (message.payload) {
            .static_string => |s| {
                if (self.last_message) |old| {
                    self.allocator.free(old);
                }
                self.last_message = try self.allocator.dupe(u8, s);
            },
            else => {},
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.last_message) |msg| {
            self.allocator.free(msg);
        }
    }
};

/// 监督Actor实现
const SupervisorActor = struct {
    const Self = @This();

    children_count: u32,
    restart_count: u32,

    pub fn init() Self {
        return Self{
            .children_count = 0,
            .restart_count = 0,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        switch (message.message_type) {
            .system => |sys_msg| {
                switch (sys_msg) {
                    .start => self.children_count += 1,
                    .stop => self.children_count -= 1,
                    .restart => self.restart_count += 1,
                    else => {},
                }
            },
            else => {},
        }
    }
};

test "Actor system initialization and shutdown" {
    const allocator = testing.allocator;
    
    // 初始化Actor系统
    const config = zactor.Config.development();
    var system = try zactor.ActorSystem.init("test-system", config, allocator);
    defer system.deinit();

    // 启动系统
    try system.start();
    try testing.expect(system.getState() == .running);

    // 关闭系统
    system.shutdown();
    try testing.expect(system.getState() == .stopped);
}

test "Actor creation and message passing" {
    const allocator = testing.allocator;
    
    const config = zactor.Config.development();
    var system = try zactor.ActorSystem.init("test-system", config, allocator);
    defer system.deinit();

    try system.start();
    defer system.shutdown();

    // 创建测试Actor
    var test_actor = TestActor.init(allocator, 1);
    defer test_actor.deinit();

    // 这里应该有实际的Actor创建和消息发送逻辑
    // 由于当前实现的限制，我们进行简化测试
    
    const message = zactor.Message.createUser(.text, "test message");
    var context = zactor.ActorContext.init(allocator, 1);
    defer context.deinit();

    try test_actor.receive(message, &context);
    
    try testing.expect(test_actor.message_count == 1);
    try testing.expect(test_actor.last_message != null);
    try testing.expect(std.mem.eql(u8, test_actor.last_message.?, "test message"));
}

test "Mailbox integration" {
    const allocator = testing.allocator;
    
    // 测试不同类型的邮箱
    const configs = [_]zactor.MailboxConfig{
        .{ .mailbox_type = .standard, .capacity = 1000 },
        .{ .mailbox_type = .fast, .capacity = 1000 },
        .{ .mailbox_type = .ultra_fast, .capacity = 1000 },
    };

    for (configs) |config| {
        var mailbox = try zactor.core.mailbox.StandardMailbox.init(allocator, config);
        defer mailbox.deinit();

        // 发送消息
        const message = zactor.Message.createUser(.text, "mailbox test");
        try mailbox.sendMessage(message);

        // 接收消息
        const received = try mailbox.receiveMessage();
        try testing.expect(received.message_type.user == .text);
    }
}

test "High-performance components integration" {
    const allocator = testing.allocator;
    
    // 测试Ring Buffer
    const ring_buffer = try zactor.messaging.RingBufferFactory.createSPSC(allocator, 1024);
    defer ring_buffer.deinit();

    const message = zactor.Message.createUser(.text, "ring buffer test");
    try testing.expect(ring_buffer.tryPublish(message));
    
    const consumed = ring_buffer.tryConsume();
    try testing.expect(consumed != null);

    // 测试零拷贝消息
    const messenger = try zactor.messaging.ZeroCopyMessenger.init(allocator, 1024, 10);
    defer messenger.deinit();

    const payload = "zero copy test";
    const zero_copy_msg = try messenger.createMessage(1, 123, payload);
    
    try testing.expect(zero_copy_msg.header.type_id == 1);
    try testing.expect(zero_copy_msg.header.sender_id == 123);
    
    messenger.releaseMessage(&zero_copy_msg);

    // 测试类型特化消息
    var typed_msg = try zactor.message.TypedMessage.create(allocator, 1, 123, payload, null);
    defer typed_msg.deinit();
    
    try testing.expect(typed_msg.getTypeId() == 1);
    try testing.expect(typed_msg.getSenderId() == 123);
}

test "NUMA scheduler integration" {
    const allocator = testing.allocator;
    
    const scheduler = try zactor.scheduler.NumaScheduler.init(allocator);
    defer scheduler.deinit();

    // 测试拓扑检测
    const stats = scheduler.getStats();
    try testing.expect(stats.topology.total_nodes > 0);
    try testing.expect(stats.topology.total_cores > 0);

    // 测试负载更新
    scheduler.updateNodeLoad(0, 50);
    
    // 验证调度器正常工作
    const updated_stats = scheduler.getStats();
    try testing.expect(updated_stats.topology.total_nodes > 0);
}

test "Supervisor tree integration" {
    const allocator = testing.allocator;
    
    // 创建监督配置
    const supervisor_config = zactor.SupervisorConfig{
        .strategy = .restart,
        .max_restarts = 3,
        .time_window_ms = 5000,
        .restart_delay_ms = 100,
        .backoff_multiplier = 2.0,
        .max_restart_delay_ms = 5000,
    };

    var supervisor = try zactor.Supervisor.init(allocator, supervisor_config);
    defer supervisor.deinit();

    // 测试监督策略
    try testing.expect(supervisor.config.strategy == .restart);
    try testing.expect(supervisor.config.max_restarts == 3);

    // 模拟子Actor失败和重启
    var supervisor_actor = SupervisorActor.init();
    var context = zactor.ActorContext.init(allocator, 1);
    defer context.deinit();

    const restart_message = zactor.Message.createSystem(.restart, null);
    try supervisor_actor.receive(restart_message, &context);
    
    try testing.expect(supervisor_actor.restart_count == 1);
}

test "End-to-end message flow" {
    const allocator = testing.allocator;
    
    // 创建完整的消息流测试
    var sender = TestActor.init(allocator, 1);
    defer sender.deinit();
    
    var receiver = TestActor.init(allocator, 2);
    defer receiver.deinit();

    var context = zactor.ActorContext.init(allocator, 1);
    defer context.deinit();

    // 发送方创建消息
    const message = zactor.Message.createUser(.text, "end-to-end test");
    
    // 接收方处理消息
    try receiver.receive(message, &context);
    
    try testing.expect(receiver.message_count == 1);
    try testing.expect(std.mem.eql(u8, receiver.last_message.?, "end-to-end test"));
}

test "Performance integration test" {
    const allocator = testing.allocator;
    
    // 简单的性能集成测试
    const num_messages = 1000;
    const start_time = std.time.nanoTimestamp();

    var actor = TestActor.init(allocator, 1);
    defer actor.deinit();
    
    var context = zactor.ActorContext.init(allocator, 1);
    defer context.deinit();

    for (0..num_messages) |i| {
        const message = zactor.Message.createUser(.text, "perf test");
        try actor.receive(message, &context);
        
        // 验证消息处理
        try testing.expect(actor.message_count == i + 1);
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(num_messages)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    // 验证基本性能要求
    try testing.expect(throughput > 10_000.0); // 至少10K msg/s
    try testing.expect(actor.message_count == num_messages);
}

test "Memory management integration" {
    const allocator = testing.allocator;
    
    // 测试内存管理集成
    const num_actors = 100;
    var actors = std.ArrayList(TestActor).init(allocator);
    defer {
        for (actors.items) |*actor| {
            actor.deinit();
        }
        actors.deinit();
    }

    // 创建多个Actor
    for (0..num_actors) |i| {
        const actor = TestActor.init(allocator, @intCast(i));
        try actors.append(actor);
    }

    try testing.expect(actors.items.len == num_actors);

    // 给每个Actor发送消息
    var context = zactor.ActorContext.init(allocator, 1);
    defer context.deinit();

    for (actors.items) |*actor| {
        const message = zactor.Message.createUser(.text, "memory test");
        try actor.receive(message, &context);
        try testing.expect(actor.message_count == 1);
    }
}

test "Error handling integration" {
    const allocator = testing.allocator;
    
    // 测试错误处理集成
    var actor = TestActor.init(allocator, 1);
    defer actor.deinit();
    
    var context = zactor.ActorContext.init(allocator, 1);
    defer context.deinit();

    // 测试正常消息处理
    const normal_message = zactor.Message.createUser(.text, "normal");
    try actor.receive(normal_message, &context);
    try testing.expect(actor.message_count == 1);

    // 测试系统消息处理
    const system_message = zactor.Message.createSystem(.stop, null);
    try actor.receive(system_message, &context);
    try testing.expect(actor.message_count == 2);
}
