//! 高性能基准测试
//! 测试ZActor的极限性能，包括Ring Buffer、零拷贝消息、批处理等优化

const std = @import("std");
const zactor = @import("zactor");
const print = std.debug.print;

// 导入高性能组件
const RingBuffer = zactor.messaging.RingBuffer;
const RingBufferFactory = zactor.messaging.RingBufferFactory;
const BatchProcessor = zactor.messaging.BatchProcessor;
const ZeroCopyMessenger = zactor.messaging.ZeroCopyMessenger;
const TypedMessage = zactor.message.TypedMessage;
const NumaScheduler = zactor.scheduler.NumaScheduler;

/// 基准测试配置
const BenchmarkConfig = struct {
    num_messages: u32 = 1_000_000,
    num_actors: u32 = 100,
    batch_size: u32 = 1000,
    ring_buffer_size: u32 = 65536,
    warmup_iterations: u32 = 10000,
    test_duration_seconds: u32 = 10,
};

/// 基准测试结果
const BenchmarkResult = struct {
    test_name: []const u8,
    messages_sent: u64,
    duration_ns: u64,
    throughput_msg_per_sec: f64,
    latency_avg_ns: f64,
    latency_p99_ns: f64,
    memory_used_mb: f64,

    pub fn print(self: *const BenchmarkResult) void {
        std.debug.print("\n=== {s} ===\n", .{self.test_name});
        std.debug.print("Messages sent: {}\n", .{self.messages_sent});
        std.debug.print("Duration: {d:.2} ms\n", .{@as(f64, @floatFromInt(self.duration_ns)) / 1_000_000.0});
        std.debug.print("Throughput: {d:.0} msg/s\n", .{self.throughput_msg_per_sec});
        std.debug.print("Average latency: {d:.2} μs\n", .{self.latency_avg_ns / 1000.0});
        std.debug.print("P99 latency: {d:.2} μs\n", .{self.latency_p99_ns / 1000.0});
        std.debug.print("Memory used: {d:.2} MB\n", .{self.memory_used_mb});
    }
};

/// 高性能Actor实现
const HighPerfActor = struct {
    const Self = @This();

    message_count: std.atomic.Value(u64),
    start_time: i128,
    latencies: std.ArrayList(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .message_count = std.atomic.Value(u64).init(0),
            .start_time = std.time.nanoTimestamp(),
            .latencies = std.ArrayList(u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.latencies.deinit();
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;

        const now = std.time.nanoTimestamp();
        const latency = @as(u64, @intCast(now - message.metadata.timestamp));

        // 记录延迟（采样以避免内存爆炸）
        const count = self.message_count.fetchAdd(1, .acq_rel);
        if (count % 1000 == 0) {
            try self.latencies.append(latency);
        }
    }

    pub fn getStats(self: *Self) struct { count: u64, avg_latency: f64, p99_latency: f64 } {
        const count = self.message_count.load(.acquire);

        if (self.latencies.items.len == 0) {
            return .{ .count = count, .avg_latency = 0.0, .p99_latency = 0.0 };
        }

        // 计算平均延迟
        var total_latency: u64 = 0;
        for (self.latencies.items) |latency| {
            total_latency += latency;
        }
        const avg_latency = @as(f64, @floatFromInt(total_latency)) / @as(f64, @floatFromInt(self.latencies.items.len));

        // 计算P99延迟
        const sorted_latencies = self.allocator.dupe(u64, self.latencies.items) catch return .{ .count = count, .avg_latency = avg_latency, .p99_latency = 0.0 };
        defer self.allocator.free(sorted_latencies);
        std.mem.sort(u64, sorted_latencies, {}, comptime std.sort.asc(u64));

        const p99_index = (sorted_latencies.len * 99) / 100;
        const p99_latency = if (p99_index < sorted_latencies.len)
            @as(f64, @floatFromInt(sorted_latencies[p99_index]))
        else
            avg_latency;

        return .{ .count = count, .avg_latency = avg_latency, .p99_latency = p99_latency };
    }
};

/// Ring Buffer性能测试
fn benchmarkRingBuffer(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    print("Running Ring Buffer benchmark...\n", .{});

    const ring_buffer = try RingBufferFactory.createSPSC(allocator, config.ring_buffer_size);
    defer ring_buffer.deinit();

    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;

    // 发送消息
    for (0..config.num_messages) |i| {
        const message = zactor.Message.createUser(.custom, "benchmark_message");
        if (ring_buffer.tryPublish(message)) {
            messages_sent += 1;
        }

        // 消费一些消息以避免缓冲区满
        if (i % 100 == 0) {
            var consumed: u32 = 0;
            while (consumed < 50 and ring_buffer.tryConsume() != null) {
                consumed += 1;
            }
        }
    }

    // 消费剩余消息
    while (ring_buffer.tryConsume() != null) {}

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(messages_sent)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    return BenchmarkResult{
        .test_name = "Ring Buffer SPSC",
        .messages_sent = messages_sent,
        .duration_ns = duration_ns,
        .throughput_msg_per_sec = throughput,
        .latency_avg_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(messages_sent)),
        .latency_p99_ns = 0.0, // Ring Buffer测试不测量端到端延迟
        .memory_used_mb = @as(f64, @floatFromInt(config.ring_buffer_size * @sizeOf(zactor.Message))) / (1024.0 * 1024.0),
    };
}

/// 零拷贝消息性能测试
fn benchmarkZeroCopy(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    print("Running Zero-Copy messaging benchmark...\n", .{});

    const messenger = try ZeroCopyMessenger.init(allocator, 4096, 1000);
    defer messenger.deinit();

    const payload = "This is a test message for zero-copy benchmark";
    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;

    for (0..config.num_messages) |_| {
        const message = messenger.createMessage(1, 123, payload) catch continue;
        messages_sent += 1;
        messenger.releaseMessage(&message);
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(messages_sent)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    const stats = messenger.getStats();
    const memory_used = @as(f64, @floatFromInt(stats.total * 4096)) / (1024.0 * 1024.0);

    return BenchmarkResult{
        .test_name = "Zero-Copy Messaging",
        .messages_sent = messages_sent,
        .duration_ns = duration_ns,
        .throughput_msg_per_sec = throughput,
        .latency_avg_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(messages_sent)),
        .latency_p99_ns = 0.0,
        .memory_used_mb = memory_used,
    };
}

/// 类型特化消息性能测试
fn benchmarkTypedMessages(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    print("Running Typed Messages benchmark...\n", .{});

    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;

    // 测试不同大小的消息
    const small_payload = "small";
    const medium_payload = "a" ** 512; // 512字节
    const large_payload = "b" ** 8192; // 8KB

    for (0..config.num_messages) |i| {
        const payload = switch (i % 3) {
            0 => small_payload,
            1 => medium_payload,
            else => large_payload,
        };

        var message = TypedMessage.create(allocator, 1, 123, payload, null) catch continue;
        defer message.deinit();
        messages_sent += 1;
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    const throughput = @as(f64, @floatFromInt(messages_sent)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    return BenchmarkResult{
        .test_name = "Typed Messages",
        .messages_sent = messages_sent,
        .duration_ns = duration_ns,
        .throughput_msg_per_sec = throughput,
        .latency_avg_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(messages_sent)),
        .latency_p99_ns = 0.0,
        .memory_used_mb = 0.0, // 难以精确计算
    };
}

/// 运行所有基准测试
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BenchmarkConfig{
        .num_messages = 1_000_000,
        .ring_buffer_size = 65536,
    };

    print("=== ZActor High Performance Benchmark ===\n", .{});
    print("Configuration:\n", .{});
    print("  Messages: {}\n", .{config.num_messages});
    print("  Ring Buffer Size: {}\n", .{config.ring_buffer_size});
    print("\n", .{});

    // Ring Buffer测试
    const ring_buffer_result = try benchmarkRingBuffer(allocator, config);
    ring_buffer_result.print();

    // 零拷贝消息测试
    const zero_copy_result = try benchmarkZeroCopy(allocator, config);
    zero_copy_result.print();

    // 类型特化消息测试
    const typed_messages_result = try benchmarkTypedMessages(allocator, config);
    typed_messages_result.print();

    // 总结
    print("\n=== Performance Summary ===\n", .{});
    print("Ring Buffer: {d:.0} msg/s\n", .{ring_buffer_result.throughput_msg_per_sec});
    print("Zero-Copy: {d:.0} msg/s\n", .{zero_copy_result.throughput_msg_per_sec});
    print("Typed Messages: {d:.0} msg/s\n", .{typed_messages_result.throughput_msg_per_sec});

    const best_throughput = @max(ring_buffer_result.throughput_msg_per_sec, @max(zero_copy_result.throughput_msg_per_sec, typed_messages_result.throughput_msg_per_sec));
    print("Best Performance: {d:.0} msg/s\n", .{best_throughput});

    // 与目标性能对比
    const target_performance = 50_000_000.0; // 50M msg/s
    const performance_ratio = best_throughput / target_performance;
    print("Target Achievement: {d:.1}% ({d:.0} / {d:.0})\n", .{ performance_ratio * 100.0, best_throughput, target_performance });

    if (best_throughput >= target_performance) {
        print("🎉 TARGET ACHIEVED! ZActor达到了50M msg/s的性能目标！\n", .{});
    } else {
        print("📈 继续优化中... 距离目标还需提升 {d:.1}倍\n", .{target_performance / best_throughput});
    }
}
