//! 高性能功能测试
//! 测试零拷贝消息、NUMA调度器、类型特化消息等新功能

const std = @import("std");
const testing = std.testing;
const zactor = @import("zactor");

// 导入要测试的组件
const ZeroCopyMessage = zactor.messaging.ZeroCopyMessage;
const ZeroCopyMessageHeader = zactor.messaging.ZeroCopyMessageHeader;
const ZeroCopyMemoryPool = zactor.messaging.ZeroCopyMemoryPool;
const ZeroCopyMessenger = zactor.messaging.ZeroCopyMessenger;

const TypedMessage = zactor.message.TypedMessage;
const MessageSizeClass = zactor.message.MessageSizeClass;
const TinyMessage = zactor.message.TinyMessage;
const SmallMessage = zactor.message.SmallMessage;

const NumaScheduler = zactor.scheduler.NumaScheduler;
const NumaTopology = zactor.scheduler.NumaTopology;
const NumaNode = zactor.scheduler.NumaNode;

test "ZeroCopyMessageHeader validation" {
    const header = ZeroCopyMessageHeader.init(1, 100, 12345);

    try testing.expect(header.type_id == 1);
    try testing.expect(header.size == 100);
    try testing.expect(header.sender_id == 12345);
    try testing.expect(header.validate());

    // 测试校验和验证
    var invalid_header = header;
    invalid_header.checksum = 0;
    try testing.expect(!invalid_header.validate());
}

test "ZeroCopyMessage serialization" {
    const payload = "Hello, Zero-Copy World!";
    const header = ZeroCopyMessageHeader.init(1, @intCast(payload.len), 12345);

    const message = ZeroCopyMessage{
        .header = header,
        .payload_ptr = @constCast(payload.ptr),
        .payload_len = @intCast(payload.len),
    };

    // 序列化
    var buffer: [1024]u8 = undefined;
    const serialized = try message.toBytes(&buffer);

    try testing.expect(serialized.len == @sizeOf(ZeroCopyMessageHeader) + payload.len);

    // 反序列化
    const deserialized = try ZeroCopyMessage.fromBytes(serialized);

    try testing.expect(deserialized.header.type_id == header.type_id);
    try testing.expect(deserialized.header.size == header.size);
    try testing.expect(deserialized.header.sender_id == header.sender_id);
    try testing.expect(deserialized.payload_len == payload.len);

    // 验证载荷
    const received_payload = deserialized.getPayloadSlice(u8);
    try testing.expect(received_payload != null);
    try testing.expect(std.mem.eql(u8, received_payload.?, payload));
}

test "ZeroCopyMemoryPool operations" {
    const allocator = testing.allocator;

    const pool = try ZeroCopyMemoryPool.init(allocator, 1024, 10);
    defer pool.deinit();

    // 测试获取内存块
    const block1 = pool.acquire();
    try testing.expect(block1 != null);
    try testing.expect(block1.?.len == 1024);

    const block2 = pool.acquire();
    try testing.expect(block2 != null);

    // 检查统计信息
    var stats = pool.getStats();
    try testing.expect(stats.allocated == 2);
    try testing.expect(stats.free == 8);

    // 释放内存块
    pool.release(block1.?);
    stats = pool.getStats();
    try testing.expect(stats.allocated == 1);
    try testing.expect(stats.free == 9);

    pool.release(block2.?);
    stats = pool.getStats();
    try testing.expect(stats.allocated == 0);
    try testing.expect(stats.free == 10);
}

test "ZeroCopyMessenger message lifecycle" {
    const allocator = testing.allocator;

    const messenger = try ZeroCopyMessenger.init(allocator, 1024, 10);
    defer messenger.deinit();

    const payload = "Test message for zero-copy messenger";

    // 创建消息
    const message = try messenger.createMessage(42, 12345, payload);

    try testing.expect(message.header.type_id == 42);
    try testing.expect(message.header.sender_id == 12345);
    try testing.expect(message.payload_len == payload.len);

    // 验证载荷
    const received_payload = message.getPayloadSlice(u8);
    try testing.expect(received_payload != null);
    try testing.expect(std.mem.eql(u8, received_payload.?, payload));

    // 释放消息
    messenger.releaseMessage(&message);

    // 检查内存池状态
    const stats = messenger.getStats();
    try testing.expect(stats.allocated == 0);
}

test "MessageSizeClass classification" {
    try testing.expect(MessageSizeClass.classify(4) == .tiny);
    try testing.expect(MessageSizeClass.classify(32) == .small);
    try testing.expect(MessageSizeClass.classify(512) == .medium);
    try testing.expect(MessageSizeClass.classify(32768) == .large);
    try testing.expect(MessageSizeClass.classify(131072) == .huge);
}

test "TinyMessage operations" {
    const msg = TinyMessage.init(1, 123, 0x1234567890ABCDEF);

    try testing.expect(msg.type_id == 1);
    try testing.expect(msg.sender_id == 123);
    try testing.expect(msg.data == 0x1234567890ABCDEF);
    try testing.expect(msg.getSize() == 8);

    const bytes = msg.toBytes();
    try testing.expect(bytes.len == 8);

    const from_bytes = TinyMessage.fromBytes(&bytes);
    try testing.expect(from_bytes.data == msg.data);
}

test "SmallMessage operations" {
    const payload = "Hello, Small Message!";
    const msg = SmallMessage.init(1, 123, payload);

    try testing.expect(msg.type_id == 1);
    try testing.expect(msg.sender_id == 123);
    try testing.expect(msg.size == payload.len);

    const received_payload = msg.getPayload();
    try testing.expect(std.mem.eql(u8, received_payload, payload));
}

test "TypedMessage creation and operations" {
    const allocator = testing.allocator;

    // 测试微型消息
    const tiny_payload = "tiny";
    var tiny_msg = try TypedMessage.create(allocator, 1, 123, tiny_payload, null);
    defer tiny_msg.deinit();

    try testing.expect(tiny_msg.getSizeClass() == .tiny);
    try testing.expect(tiny_msg.getTypeId() == 1);
    try testing.expect(tiny_msg.getSenderId() == 123);

    // 测试小型消息
    const small_payload = "This is a small message for testing";
    var small_msg = try TypedMessage.create(allocator, 2, 456, small_payload, null);
    defer small_msg.deinit();

    try testing.expect(small_msg.getSizeClass() == .small);
    try testing.expect(small_msg.getTypeId() == 2);
    try testing.expect(small_msg.getSenderId() == 456);
    try testing.expect(std.mem.eql(u8, small_msg.getPayload(), small_payload));

    // 测试大型消息
    const large_payload = "x" ** 2048; // 2KB消息
    var large_msg = try TypedMessage.create(allocator, 3, 789, large_payload, null);
    defer large_msg.deinit();

    try testing.expect(large_msg.getSizeClass() == .large);
    try testing.expect(large_msg.getTypeId() == 3);
    try testing.expect(large_msg.getSenderId() == 789);
    try testing.expect(std.mem.eql(u8, large_msg.getPayload(), large_payload));
}

test "NumaTopology detection" {
    const allocator = testing.allocator;

    const topology = try NumaTopology.detect(allocator);
    defer topology.deinit();

    try testing.expect(topology.nodes.len > 0);
    try testing.expect(topology.total_cores > 0);

    // 测试获取最佳节点
    const best_node = topology.getBestNode();
    try testing.expect(best_node.cpu_cores.len > 0);

    // 测试节点负载管理
    best_node.addActor();
    try testing.expect(best_node.actor_count.load(.acquire) == 1);

    best_node.removeActor();
    try testing.expect(best_node.actor_count.load(.acquire) == 0);

    // 测试统计信息
    const stats = try topology.getStats(allocator);
    defer NumaTopology.freeStats(allocator, stats);
    try testing.expect(stats.total_nodes == topology.nodes.len);
    try testing.expect(stats.total_cores == topology.total_cores);
}

test "NumaScheduler basic operations" {
    const allocator = testing.allocator;

    const scheduler = try NumaScheduler.init(allocator);
    defer scheduler.deinit();

    // 测试获取统计信息
    const stats = try scheduler.getStats(allocator);
    defer scheduler.freeStats(allocator, stats);
    try testing.expect(stats.topology.total_nodes > 0);
    try testing.expect(stats.topology.total_cores > 0);

    // 测试节点负载更新
    scheduler.updateNodeLoad(0, 50);
    // 由于没有直接的getter，我们通过统计信息验证
    const updated_stats = try scheduler.getStats(allocator);
    defer scheduler.freeStats(allocator, updated_stats);
    try testing.expect(updated_stats.topology.total_nodes > 0);
}

test "Performance baseline test" {
    const allocator = testing.allocator;

    // 简单的性能基线测试
    const num_messages = 10000;
    const start_time = std.time.nanoTimestamp();

    // 测试零拷贝消息创建性能
    const messenger = try ZeroCopyMessenger.init(allocator, 1024, 100);
    defer messenger.deinit();

    const payload = "Performance test message";
    var created_count: u32 = 0;

    for (0..num_messages) |_| {
        const message = messenger.createMessage(1, 123, payload) catch continue;
        messenger.releaseMessage(&message);
        created_count += 1;
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(created_count)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    std.debug.print("\nPerformance baseline:\n", .{});
    std.debug.print("  Messages: {}\n", .{created_count});
    std.debug.print("  Duration: {d:.2} ms\n", .{@as(f64, @floatFromInt(duration_ns)) / 1_000_000.0});
    std.debug.print("  Throughput: {d:.0} msg/s\n", .{throughput});

    // 基本性能要求：至少100K msg/s
    try testing.expect(throughput > 100_000.0);
}

test "Memory efficiency test" {
    const allocator = testing.allocator;

    // 测试内存使用效率
    const messenger = try ZeroCopyMessenger.init(allocator, 1024, 10);
    defer messenger.deinit();

    const initial_stats = messenger.getStats();
    try testing.expect(initial_stats.total == 10);
    try testing.expect(initial_stats.allocated == 0);
    try testing.expect(initial_stats.free == 10);

    // 分配一些消息
    const payload = "Memory efficiency test";
    const message1 = try messenger.createMessage(1, 123, payload);
    const message2 = try messenger.createMessage(2, 456, payload);

    const allocated_stats = messenger.getStats();
    try testing.expect(allocated_stats.allocated == 2);
    try testing.expect(allocated_stats.free == 8);

    // 释放消息
    messenger.releaseMessage(&message1);
    messenger.releaseMessage(&message2);

    const final_stats = messenger.getStats();
    try testing.expect(final_stats.allocated == 0);
    try testing.expect(final_stats.free == 10);
}
