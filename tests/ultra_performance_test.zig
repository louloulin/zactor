//! 超高性能功能测试
//! 验证新的超高性能组件功能正确性

const std = @import("std");
const testing = std.testing;
const zactor = @import("zactor");

// 导入超高性能组件
const UltraFastMessageCore = zactor.messaging.UltraFastMessageCore;
const LockFreeRingBuffer = zactor.messaging.LockFreeRingBuffer;
const PreAllocatedArena = zactor.messaging.PreAllocatedArena;
const ActorMemoryAllocator = zactor.memory.ActorMemoryAllocator;

test "PreAllocatedArena basic operations" {
    const allocator = testing.allocator;

    const arena = try PreAllocatedArena.init(allocator, 4096);
    defer arena.deinit();

    // 测试分配
    const block1 = arena.allocFast(64);
    try testing.expect(block1 != null);
    try testing.expect(block1.?.len == 64);

    const block2 = arena.allocFast(128);
    try testing.expect(block2 != null);
    try testing.expect(block2.?.len == 128);

    // 测试使用情况
    const usage = arena.getUsage();
    try testing.expect(usage.used > 0);
    try testing.expect(usage.utilization > 0.0);

    // 测试重置
    arena.reset();
    const usage_after_reset = arena.getUsage();
    try testing.expect(usage_after_reset.used == 0);
    try testing.expect(usage_after_reset.utilization == 0.0);
}

test "LockFreeRingBuffer zero-copy operations" {
    const allocator = testing.allocator;

    const arena = try PreAllocatedArena.init(allocator, 64 * 1024);
    defer arena.deinit();

    const ring_buffer = try LockFreeRingBuffer.init(allocator, 1024, arena);
    defer ring_buffer.deinit();

    // 测试零拷贝发布
    const message1 = "Hello, Zero-Copy World!";
    try testing.expect(ring_buffer.tryPushZeroCopy(message1));

    const message2 = "Another test message";
    try testing.expect(ring_buffer.tryPushZeroCopy(message2));

    // 测试零拷贝消费
    const received1 = ring_buffer.tryPopZeroCopy();
    try testing.expect(received1 != null);
    try testing.expect(std.mem.eql(u8, received1.?, message1));

    const received2 = ring_buffer.tryPopZeroCopy();
    try testing.expect(received2 != null);
    try testing.expect(std.mem.eql(u8, received2.?, message2));

    // 测试空缓冲区
    const received3 = ring_buffer.tryPopZeroCopy();
    try testing.expect(received3 == null);

    // 测试统计信息
    const stats = ring_buffer.getStats();
    try testing.expect(stats.capacity == 1024);
}

test "LockFreeRingBuffer batch operations" {
    const allocator = testing.allocator;

    const arena = try PreAllocatedArena.init(allocator, 64 * 1024);
    defer arena.deinit();

    const ring_buffer = try LockFreeRingBuffer.init(allocator, 1024, arena);
    defer ring_buffer.deinit();

    // 准备批量消息
    const messages = [_][]const u8{
        "Message 1",
        "Message 2", 
        "Message 3",
        "Message 4",
        "Message 5",
    };

    // 测试批量发布
    const published = ring_buffer.tryPushBatch(@constCast(&messages));
    try testing.expect(published == messages.len);

    // 测试批量消费
    var output: [10]?[]u8 = undefined;
    const consumed = ring_buffer.tryPopBatch(&output);
    try testing.expect(consumed == messages.len);

    // 验证消息内容
    for (messages, 0..) |expected, i| {
        try testing.expect(output[i] != null);
        try testing.expect(std.mem.eql(u8, output[i].?, expected));
    }
}

test "UltraFastMessageCore basic operations" {
    const allocator = testing.allocator;

    const core = try UltraFastMessageCore.init(allocator, 1024, 64 * 1024);
    defer core.deinit();

    // 测试消息发送和接收
    const message = "Ultra fast message test";
    try testing.expect(core.sendMessage(message));

    const received = core.receiveMessage();
    try testing.expect(received != null);
    try testing.expect(std.mem.eql(u8, received.?, message));

    // 测试性能统计
    const stats = core.getPerformanceStats();
    try testing.expect(stats.ring_buffer.capacity == 1024);
    try testing.expect(stats.memory_arena.capacity == 64 * 1024);
}

test "UltraFastMessageCore batch operations" {
    const allocator = testing.allocator;

    const core = try UltraFastMessageCore.init(allocator, 1024, 64 * 1024);
    defer core.deinit();

    // 准备批量消息
    const messages = [_][]const u8{
        "Batch message 1",
        "Batch message 2",
        "Batch message 3",
    };

    // 测试批量发送
    const sent = core.sendMessageBatch(@constCast(&messages));
    try testing.expect(sent == messages.len);

    // 测试批量接收
    var output: [5]?[]u8 = undefined;
    const received = core.receiveMessageBatch(&output);
    try testing.expect(received == messages.len);

    // 验证消息内容
    for (messages, 0..) |expected, i| {
        try testing.expect(output[i] != null);
        try testing.expect(std.mem.eql(u8, output[i].?, expected));
    }
}

test "ActorMemoryAllocator fast path" {
    const allocator = testing.allocator;

    const actor_allocator = try ActorMemoryAllocator.init(allocator);
    defer actor_allocator.deinit();

    // 测试不同大小的快速分配
    const sizes = [_]usize{ 32, 64, 128, 256, 512, 1024 };
    var allocated_blocks = std.ArrayList([]u8).init(allocator);
    defer allocated_blocks.deinit();

    for (sizes) |size| {
        const memory = try actor_allocator.allocFast(size);
        try testing.expect(memory.len >= size);
        try allocated_blocks.append(memory);
    }

    // 测试快速释放
    for (allocated_blocks.items) |block| {
        actor_allocator.freeFast(block);
    }

    // 检查性能统计
    const stats = actor_allocator.getPerformanceStats();
    try testing.expect(stats.total_allocations == sizes.len);
    try testing.expect(stats.fast_path_hits > 0);
}

test "ActorMemoryAllocator standard interface" {
    const allocator = testing.allocator;

    const actor_allocator = try ActorMemoryAllocator.init(allocator);
    defer actor_allocator.deinit();

    const std_allocator = actor_allocator.allocator();

    // 测试标准分配器接口
    const memory = try std_allocator.alloc(u8, 256);
    defer std_allocator.free(memory);

    try testing.expect(memory.len == 256);

    // 写入测试数据
    for (memory, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }

    // 验证数据
    for (memory, 0..) |byte, i| {
        try testing.expect(byte == @as(u8, @intCast(i % 256)));
    }
}

test "Performance baseline test" {
    const allocator = testing.allocator;

    // 简单的性能基线测试
    const num_messages = 100_000;
    const start_time = std.time.nanoTimestamp();

    const core = try UltraFastMessageCore.init(allocator, 4096, 16 * 1024 * 1024);
    defer core.deinit();

    const message = "Performance test message for ultra fast core";
    var sent_count: u32 = 0;
    var received_count: u32 = 0;

    // 发送消息
    for (0..num_messages) |_| {
        if (core.sendMessage(message)) {
            sent_count += 1;
        }
    }

    // 接收消息
    while (received_count < sent_count) {
        if (core.receiveMessage()) |_| {
            received_count += 1;
        }
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(sent_count)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    std.debug.print("\nUltra Performance baseline:\n", .{});
    std.debug.print("  Messages: {}\n", .{sent_count});
    std.debug.print("  Duration: {d:.2} ms\n", .{@as(f64, @floatFromInt(duration_ns)) / 1_000_000.0});
    std.debug.print("  Throughput: {d:.0} msg/s\n", .{throughput});

    // 期望性能提升：至少达到1M msg/s
    try testing.expect(throughput > 1_000_000.0);

    // 检查性能统计
    const stats = core.getPerformanceStats();
    try testing.expect(stats.memory_arena.utilization > 0.0);
}

test "Memory efficiency test" {
    const allocator = testing.allocator;

    const actor_allocator = try ActorMemoryAllocator.init(allocator);
    defer actor_allocator.deinit();

    // 测试内存使用效率
    const num_allocations = 10000;
    var allocated_blocks = std.ArrayList([]u8).init(allocator);
    defer allocated_blocks.deinit();

    // 大量分配
    for (0..num_allocations) |i| {
        const size = (i % 4 + 1) * 64; // 64, 128, 192, 256字节
        const memory = actor_allocator.allocFast(size) catch continue;
        try allocated_blocks.append(memory);
    }

    // 检查快速路径命中率
    const stats = actor_allocator.getPerformanceStats();
    try testing.expect(stats.fast_path_ratio > 0.5); // 至少50%快速路径命中

    // 释放所有内存
    for (allocated_blocks.items) |block| {
        actor_allocator.freeFast(block);
    }

    // 验证统计信息
    const final_stats = actor_allocator.getPerformanceStats();
    try testing.expect(final_stats.total_allocations >= allocated_blocks.items.len);
}
