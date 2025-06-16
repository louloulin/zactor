//! 超高性能基准测试
//! 目标: 验证5-10M msg/s性能，追赶业界主流

const std = @import("std");
const zactor = @import("zactor");
const print = std.debug.print;

// 导入超高性能组件
const UltraFastMessageCore = @import("../src/core/messaging/ultra_fast_core.zig").UltraFastMessageCore;
const ActorMemoryAllocator = @import("../src/core/memory/actor_allocator.zig").ActorMemoryAllocator;

/// 基准测试配置
const BenchmarkConfig = struct {
    num_messages: u32 = 10_000_000, // 1000万消息
    ring_buffer_size: u32 = 65536, // 64K环形缓冲区
    arena_size: usize = 64 * 1024 * 1024, // 64MB内存池
    warmup_iterations: u32 = 100_000,
    batch_size: u32 = 1000,
};

/// 基准测试结果
const BenchmarkResult = struct {
    test_name: []const u8,
    messages_sent: u64,
    duration_ns: u64,
    throughput_msg_per_sec: f64,
    latency_avg_ns: f64,
    memory_used_mb: f64,
    fast_path_ratio: f32,

    pub fn print(self: *const BenchmarkResult) void {
        std.debug.print("\n=== {s} ===\n", .{self.test_name});
        std.debug.print("Messages sent: {}\n", .{self.messages_sent});
        std.debug.print("Duration: {d:.2} ms\n", .{@as(f64, @floatFromInt(self.duration_ns)) / 1_000_000.0});
        std.debug.print("Throughput: {d:.0} msg/s\n", .{self.throughput_msg_per_sec});
        std.debug.print("Average latency: {d:.2} ns\n", .{self.latency_avg_ns});
        std.debug.print("Memory used: {d:.2} MB\n", .{self.memory_used_mb});
        std.debug.print("Fast path ratio: {d:.1}%\n", .{self.fast_path_ratio * 100.0});

        // 性能等级评估
        if (self.throughput_msg_per_sec >= 10_000_000) {
            std.debug.print("Performance Level: 🏆 EXCELLENT (>10M msg/s)\n", .{});
        } else if (self.throughput_msg_per_sec >= 5_000_000) {
            std.debug.print("Performance Level: 🥇 GOOD (5-10M msg/s)\n", .{});
        } else if (self.throughput_msg_per_sec >= 1_000_000) {
            std.debug.print("Performance Level: 🥈 ACCEPTABLE (1-5M msg/s)\n", .{});
        } else {
            std.debug.print("Performance Level: 🔴 POOR (<1M msg/s)\n", .{});
        }
    }
};

/// 超高性能消息传递基准测试
fn benchmarkUltraFastCore(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    std.debug.print("Running Ultra Fast Message Core benchmark...\n", .{});

    const core = try UltraFastMessageCore.init(allocator, config.ring_buffer_size, config.arena_size);
    defer core.deinit();

    // 预热
    const warmup_message = "warmup";
    for (0..config.warmup_iterations) |_| {
        _ = core.sendMessage(warmup_message);
        _ = core.receiveMessage();
    }
    core.reset();

    // 准备测试消息
    const test_message = "Ultra fast message for performance testing!";

    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;

    // 发送消息
    for (0..config.num_messages) |_| {
        if (core.sendMessage(test_message)) {
            messages_sent += 1;
        }
    }

    // 消费消息
    var messages_received: u64 = 0;
    while (messages_received < messages_sent) {
        if (core.receiveMessage()) |_| {
            messages_received += 1;
        }
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(messages_sent)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    const stats = core.getPerformanceStats();
    const memory_used = @as(f64, @floatFromInt(stats.memory_arena.used)) / (1024.0 * 1024.0);

    return BenchmarkResult{
        .test_name = "Ultra Fast Message Core",
        .messages_sent = messages_sent,
        .duration_ns = duration_ns,
        .throughput_msg_per_sec = throughput,
        .latency_avg_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(messages_sent)),
        .memory_used_mb = memory_used,
        .fast_path_ratio = 1.0, // 全部都是快速路径
    };
}

/// 高性能内存分配器基准测试
fn benchmarkActorAllocator(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    std.debug.print("Running Actor Memory Allocator benchmark...\n", .{});

    const actor_allocator = try ActorMemoryAllocator.init(allocator);
    defer actor_allocator.deinit();

    const start_time = std.time.nanoTimestamp();
    var allocations_made: u64 = 0;

    // 分配和释放测试
    var allocated_blocks = std.ArrayList([]u8).init(allocator);
    defer allocated_blocks.deinit();

    for (0..config.num_messages) |i| {
        // 不同大小的分配测试
        const size: usize = switch (i % 4) {
            0 => 32,
            1 => 128,
            2 => 512,
            else => 1024,
        };

        if (actor_allocator.allocFast(size)) |memory| {
            allocations_made += 1;
            try allocated_blocks.append(memory);

            // 每1000次分配后释放一批
            if (allocated_blocks.items.len >= 1000) {
                for (allocated_blocks.items) |block| {
                    actor_allocator.freeFast(block);
                }
                allocated_blocks.clearRetainingCapacity();
            }
        } else |_| {
            break;
        }
    }

    // 释放剩余的内存块
    for (allocated_blocks.items) |block| {
        actor_allocator.freeFast(block);
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(allocations_made)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    const stats = actor_allocator.getPerformanceStats();

    return BenchmarkResult{
        .test_name = "Actor Memory Allocator",
        .messages_sent = allocations_made,
        .duration_ns = duration_ns,
        .throughput_msg_per_sec = throughput,
        .latency_avg_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(allocations_made)),
        .memory_used_mb = 0.0, // 难以精确计算
        .fast_path_ratio = stats.fast_path_ratio,
    };
}

/// 批量处理基准测试
fn benchmarkBatchProcessing(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    std.debug.print("Running Batch Processing benchmark...\n", .{});

    const core = try UltraFastMessageCore.init(allocator, config.ring_buffer_size, config.arena_size);
    defer core.deinit();

    // 准备批量消息
    var messages = std.ArrayList([]const u8).init(allocator);
    defer messages.deinit();

    for (0..config.batch_size) |i| {
        const message = try std.fmt.allocPrint(allocator, "Batch message {}", .{i});
        try messages.append(message);
    }
    defer {
        for (messages.items) |msg| {
            allocator.free(msg);
        }
    }

    const start_time = std.time.nanoTimestamp();
    var total_messages_sent: u64 = 0;

    // 批量发送测试
    const num_batches = config.num_messages / config.batch_size;
    for (0..num_batches) |_| {
        const sent = core.sendMessageBatch(messages.items);
        total_messages_sent += sent;

        // 批量接收
        var received_messages: [1000]?[]u8 = undefined;
        const received = core.receiveMessageBatch(&received_messages);
        _ = received;
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(total_messages_sent)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    const stats = core.getPerformanceStats();
    const memory_used = @as(f64, @floatFromInt(stats.memory_arena.used)) / (1024.0 * 1024.0);

    return BenchmarkResult{
        .test_name = "Batch Processing",
        .messages_sent = total_messages_sent,
        .duration_ns = duration_ns,
        .throughput_msg_per_sec = throughput,
        .latency_avg_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(total_messages_sent)),
        .memory_used_mb = memory_used,
        .fast_path_ratio = 1.0,
    };
}

/// 运行所有超高性能基准测试
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BenchmarkConfig{
        .num_messages = 5_000_000, // 500万消息
        .ring_buffer_size = 65536,
        .arena_size = 128 * 1024 * 1024, // 128MB
    };

    std.debug.print("=== ZActor Ultra Performance Benchmark ===\n", .{});
    std.debug.print("Target: Reach 5-10M msg/s (Industry Standard)\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Messages: {}\n", .{config.num_messages});
    std.debug.print("  Ring Buffer Size: {}\n", .{config.ring_buffer_size});
    std.debug.print("  Arena Size: {} MB\n", .{config.arena_size / (1024 * 1024)});
    std.debug.print("\n", .{});

    // 超高性能消息传递测试
    const ultra_fast_result = try benchmarkUltraFastCore(allocator, config);
    ultra_fast_result.print();

    // 高性能内存分配器测试
    const allocator_result = try benchmarkActorAllocator(allocator, config);
    allocator_result.print();

    // 批量处理测试
    const batch_result = try benchmarkBatchProcessing(allocator, config);
    batch_result.print();

    // 性能总结
    std.debug.print("\n=== Performance Summary ===\n", .{});
    std.debug.print("Ultra Fast Core: {d:.0} msg/s\n", .{ultra_fast_result.throughput_msg_per_sec});
    std.debug.print("Memory Allocator: {d:.0} alloc/s\n", .{allocator_result.throughput_msg_per_sec});
    std.debug.print("Batch Processing: {d:.0} msg/s\n", .{batch_result.throughput_msg_per_sec});

    const best_throughput = @max(ultra_fast_result.throughput_msg_per_sec, batch_result.throughput_msg_per_sec);
    std.debug.print("Best Performance: {d:.0} msg/s\n", .{best_throughput});

    // 与业界标准对比
    std.debug.print("\n=== Industry Comparison ===\n", .{});
    const industry_targets = [_]struct { name: []const u8, performance: f64 }{
        .{ .name = "Proto.Actor C#", .performance = 125_000_000 },
        .{ .name = "Proto.Actor Go", .performance = 70_000_000 },
        .{ .name = "Akka.NET", .performance = 46_000_000 },
        .{ .name = "Erlang/OTP", .performance = 12_000_000 },
        .{ .name = "CAF C++", .performance = 10_000_000 },
        .{ .name = "Actix Rust", .performance = 5_000_000 },
    };

    for (industry_targets) |target| {
        const ratio = best_throughput / target.performance;
        const percentage = ratio * 100.0;
        std.debug.print("{s}: {d:.1}% ({d:.0} / {d:.0})\n", .{ target.name, percentage, best_throughput, target.performance });
    }

    // 目标达成评估
    std.debug.print("\n=== Goal Achievement ===\n", .{});
    if (best_throughput >= 10_000_000) {
        std.debug.print("🏆 EXCELLENT! Reached 10M+ msg/s (Industry Leading)\n", .{});
    } else if (best_throughput >= 5_000_000) {
        std.debug.print("🥇 GOOD! Reached 5-10M msg/s (Industry Standard)\n", .{});
    } else if (best_throughput >= 1_000_000) {
        std.debug.print("🥈 ACCEPTABLE! Reached 1-5M msg/s (Basic Performance)\n", .{});
    } else {
        std.debug.print("🔴 POOR! Below 1M msg/s (Needs Optimization)\n", .{});
    }

    const improvement_factor = best_throughput / 820_000.0; // 相比之前的0.82M
    std.debug.print("Improvement Factor: {d:.1}x (vs previous 0.82M msg/s)\n", .{improvement_factor});
}
