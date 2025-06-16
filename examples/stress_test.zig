//! ZActor高性能压力测试
//! 基于WorkStealingScheduler的高负载性能测试

const std = @import("std");
const zactor = @import("zactor");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZActor高性能压力测试 ===", .{});

    // 创建高性能系统配置
    const system_config = zactor.Config{
        .scheduler_config = zactor.SchedulerConfig.forHighThroughput(),
        .default_mailbox_capacity = 2000,
        .enable_monitoring = true,
    };

    // 创建Actor系统
    const system = try zactor.ActorSystem.init("StressTestSystem", system_config, allocator);
    defer system.deinit();

    try system.start();
    defer system.shutdown() catch {};

    // 高强度压力测试配置
    const num_actors: u32 = 1000;
    const messages_per_actor: u32 = 3000;
    const total_messages = num_actors * messages_per_actor;

    std.log.info("配置: {} actors, {} messages/actor, 总计: {} 消息", .{ num_actors, messages_per_actor, total_messages });

    // 创建Actors
    var actors = std.ArrayList(*zactor.ActorRef).init(allocator);
    defer actors.deinit();

    std.log.info("创建 {} 个Actors...", .{num_actors});
    const start_time = std.time.milliTimestamp();

    for (0..num_actors) |_| {
        const actor_ref = try system.spawn(void, {});
        try actors.append(actor_ref);
    }

    const creation_time = std.time.milliTimestamp() - start_time;
    std.log.info("Actor创建完成，耗时: {}ms", .{creation_time});

    // 发送消息
    std.log.info("开始发送消息...", .{});
    const send_start = std.time.milliTimestamp();
    var sent_count: u64 = 0;

    for (0..total_messages) |i| {
        const actor_idx = i % actors.items.len;
        const actor = actors.items[actor_idx];

        actor.send([]const u8, "stress_test_message", allocator) catch {
            continue;
        };
        sent_count += 1;

        // 每1000条消息休息一下
        if (i % 1000 == 0) {
            std.time.sleep(1000); // 1μs
        }
    }

    const send_time = std.time.milliTimestamp() - send_start;

    // 等待处理完成
    std.log.info("等待消息处理完成...", .{});
    std.time.sleep(3 * std.time.ns_per_s); // 等待3秒

    const total_time = std.time.milliTimestamp() - start_time;
    const throughput = @as(f64, @floatFromInt(sent_count)) / (@as(f64, @floatFromInt(total_time)) / 1000.0);

    std.log.info("=== 压力测试结果 ===", .{});
    std.log.info("消息发送: {}", .{sent_count});
    std.log.info("发送耗时: {}ms", .{send_time});
    std.log.info("总耗时: {}ms", .{total_time});
    std.log.info("吞吐量: {d:.2} msg/s", .{throughput});
    std.log.info("Actor创建速度: {d:.2} actors/s", .{@as(f64, @floatFromInt(num_actors)) / (@as(f64, @floatFromInt(creation_time)) / 1000.0)});
}
