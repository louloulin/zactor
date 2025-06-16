//! 简单的Ring Buffer测试
//! 验证Ring Buffer基本功能

const std = @import("std");
const zactor = @import("zactor");

const RingBuffer = zactor.core.messaging.RingBuffer;
const RingBufferFactory = zactor.core.messaging.RingBufferFactory;
const Message = zactor.Message;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== 简单Ring Buffer测试 ===", .{});

    // 创建一个小的Ring Buffer
    const ring_buffer = try RingBufferFactory.createSPSC(allocator, 16);
    defer ring_buffer.deinit();

    std.log.info("Ring Buffer创建成功，容量: {}", .{ring_buffer.capacity});

    // 测试1: 基本发布和消费
    std.log.info("测试1: 基本发布和消费", .{});
    
    const test_message = Message.createUser(.custom, "test_message");
    
    // 发布消息
    const published = ring_buffer.tryPublish(test_message);
    std.log.info("发布消息: {}", .{published});
    std.log.info("使用空间: {}", .{ring_buffer.getUsedSpace()});
    
    // 消费消息
    const consumed = ring_buffer.tryConsume();
    if (consumed) |msg| {
        std.log.info("消费消息成功: ID={}", .{msg.getId()});
    } else {
        std.log.info("消费消息失败", .{});
    }
    std.log.info("使用空间: {}", .{ring_buffer.getUsedSpace()});

    // 测试2: 批量操作
    std.log.info("测试2: 批量操作", .{});
    
    var messages: [5]Message = undefined;
    for (&messages, 0..) |*msg, i| {
        msg.* = Message.createUser(.custom, "batch_message");
        _ = i;
    }
    
    // 批量发布
    const batch_published = ring_buffer.tryPublishBatch(&messages);
    std.log.info("批量发布: {} 消息", .{batch_published});
    std.log.info("使用空间: {}", .{ring_buffer.getUsedSpace()});
    
    // 批量消费
    var consumed_messages: [5]Message = undefined;
    const batch_consumed = ring_buffer.tryConsumeBatch(&consumed_messages);
    std.log.info("批量消费: {} 消息", .{batch_consumed});
    std.log.info("使用空间: {}", .{ring_buffer.getUsedSpace()});

    // 测试3: 性能测试
    std.log.info("测试3: 简单性能测试", .{});
    
    const num_messages = 10000;
    const start_time = std.time.milliTimestamp();
    
    // 发布消息
    var sent_count: u32 = 0;
    for (0..num_messages) |_| {
        const msg = Message.createUser(.custom, "perf_test");
        if (ring_buffer.tryPublish(msg)) {
            sent_count += 1;
        }
    }
    
    // 消费消息
    var received_count: u32 = 0;
    while (received_count < sent_count) {
        if (ring_buffer.tryConsume()) |_| {
            received_count += 1;
        }
    }
    
    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;
    const throughput = @as(f64, @floatFromInt(received_count)) / (@as(f64, @floatFromInt(duration_ms)) / 1000.0);
    
    std.log.info("性能测试结果:", .{});
    std.log.info("发送: {} 消息", .{sent_count});
    std.log.info("接收: {} 消息", .{received_count});
    std.log.info("耗时: {} ms", .{duration_ms});
    std.log.info("吞吐量: {d:.2} msg/s", .{throughput});

    std.log.info("=== 测试完成 ===", .{});
}
