//! Ring Buffer性能基准测试
//! 验证Phase 1无锁消息队列的性能提升

const std = @import("std");
const zactor = @import("zactor");

const RingBuffer = zactor.core.messaging.RingBuffer;
const RingBufferFactory = zactor.core.messaging.RingBufferFactory;
const BatchProcessor = zactor.core.messaging.BatchProcessor;
const BatchConfig = zactor.core.messaging.BatchConfig;
const Message = zactor.Message;

// 基准测试配置
const BenchmarkConfig = struct {
    ring_buffer_size: u32 = 1024 * 64, // 64K entries
    num_messages: u64 = 10_000_000, // 10M messages
    batch_size: u32 = 1024,
    num_producer_threads: u32 = 4,
    num_consumer_threads: u32 = 1,
    warmup_messages: u64 = 100_000,
};

// 性能统计
const BenchmarkStats = struct {
    messages_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    start_time: i64 = 0,
    end_time: i64 = 0,
    producer_times: []i64,
    consumer_times: []i64,

    pub fn init(allocator: std.mem.Allocator, num_producers: u32, num_consumers: u32) !*BenchmarkStats {
        const self = try allocator.create(BenchmarkStats);
        self.* = BenchmarkStats{
            .producer_times = try allocator.alloc(i64, num_producers),
            .consumer_times = try allocator.alloc(i64, num_consumers),
        };
        return self;
    }

    pub fn deinit(self: *BenchmarkStats, allocator: std.mem.Allocator) void {
        allocator.free(self.producer_times);
        allocator.free(self.consumer_times);
        allocator.destroy(self);
    }

    pub fn getThroughput(self: *const BenchmarkStats) f64 {
        const duration_ms = self.end_time - self.start_time;
        if (duration_ms <= 0) return 0.0;
        const messages = @as(f64, @floatFromInt(self.messages_received.load(.monotonic)));
        const duration_s = @as(f64, @floatFromInt(duration_ms)) / 1000.0;
        return messages / duration_s;
    }

    pub fn print(self: *const BenchmarkStats) void {
        const sent = self.messages_sent.load(.monotonic);
        const received = self.messages_received.load(.monotonic);
        const throughput = self.getThroughput();
        const duration_ms = self.end_time - self.start_time;

        std.log.info("=== Ring Buffer基准测试结果 ===", .{});
        std.log.info("消息发送: {}", .{sent});
        std.log.info("消息接收: {}", .{received});
        std.log.info("测试时长: {}ms", .{duration_ms});
        std.log.info("吞吐量: {d:.2} msg/s", .{throughput});
        std.log.info("吞吐量: {d:.2} M msg/s", .{throughput / 1_000_000.0});

        if (received > 0) {
            const success_rate = @as(f64, @floatFromInt(received)) / @as(f64, @floatFromInt(sent)) * 100.0;
            std.log.info("成功率: {d:.2}%", .{success_rate});
        }
    }
};

// 生产者线程函数
fn producerThread(ring_buffer: *RingBuffer, stats: *BenchmarkStats, config: BenchmarkConfig, thread_id: u32, messages_per_thread: u64) void {
    const start_time = std.time.milliTimestamp();

    var sent_count: u64 = 0;
    var batch_buffer: [1024]Message = undefined;

    // 准备消息批次
    for (&batch_buffer) |*msg| {
        msg.* = Message.createUser(.custom, "benchmark_message");
    }

    while (sent_count < messages_per_thread) {
        const remaining = messages_per_thread - sent_count;
        const batch_size = @min(config.batch_size, remaining);

        // 批量发布消息
        const published = ring_buffer.tryPublishBatch(batch_buffer[0..batch_size]);
        if (published > 0) {
            sent_count += published;
            _ = stats.messages_sent.fetchAdd(published, .monotonic);
        } else {
            // Ring Buffer满，短暂休眠
            std.time.sleep(1000); // 1μs
        }
    }

    const end_time = std.time.milliTimestamp();
    stats.producer_times[thread_id] = end_time - start_time;

    std.log.info("生产者线程 {} 完成: 发送 {} 消息，耗时 {}ms", .{ thread_id, sent_count, end_time - start_time });
}

// 消费者线程函数
fn consumerThread(ring_buffer: *RingBuffer, stats: *BenchmarkStats, _: BenchmarkConfig, thread_id: u32, target_messages: u64) void {
    const start_time = std.time.milliTimestamp();

    var received_count: u64 = 0;
    var batch_buffer: [1024]Message = undefined;

    while (received_count < target_messages) {
        // 批量消费消息
        const consumed = ring_buffer.tryConsumeBatch(&batch_buffer);
        if (consumed > 0) {
            received_count += consumed;
            _ = stats.messages_received.fetchAdd(consumed, .monotonic);

            // 模拟消息处理
            for (batch_buffer[0..consumed]) |msg| {
                // 简单的处理逻辑
                std.mem.doNotOptimizeAway(msg);
            }
        } else {
            // 没有消息时短暂休眠
            std.time.sleep(100); // 100ns
        }
    }

    const end_time = std.time.milliTimestamp();
    stats.consumer_times[thread_id] = end_time - start_time;

    std.log.info("消费者线程 {} 完成: 接收 {} 消息，耗时 {}ms", .{ thread_id, received_count, end_time - start_time });
}

// SPSC (单生产者单消费者) 基准测试
fn benchmarkSPSC(allocator: std.mem.Allocator, config: BenchmarkConfig) !void {
    std.log.info("=== SPSC Ring Buffer基准测试 ===", .{});

    const ring_buffer = try RingBufferFactory.createSPSC(allocator, config.ring_buffer_size);
    defer ring_buffer.deinit();

    const stats = try BenchmarkStats.init(allocator, 1, 1);
    defer stats.deinit(allocator);

    // 预热
    std.log.info("预热中...", .{});
    for (0..config.warmup_messages) |_| {
        const msg = Message.createUser(.custom, "warmup");
        _ = ring_buffer.tryPublish(msg);
        _ = ring_buffer.tryConsume();
    }

    std.log.info("开始SPSC基准测试: {} 消息", .{config.num_messages});
    stats.start_time = std.time.milliTimestamp();

    // 启动生产者和消费者线程
    const producer = try std.Thread.spawn(.{}, producerThread, .{ ring_buffer, stats, config, 0, config.num_messages });
    const consumer = try std.Thread.spawn(.{}, consumerThread, .{ ring_buffer, stats, config, 0, config.num_messages });

    // 等待完成
    producer.join();
    consumer.join();

    stats.end_time = std.time.milliTimestamp();
    stats.print();
}

// MPSC (多生产者单消费者) 基准测试
fn benchmarkMPSC(allocator: std.mem.Allocator, config: BenchmarkConfig) !void {
    std.log.info("=== MPSC Ring Buffer基准测试 ===", .{});

    const ring_buffer = try RingBufferFactory.createMPSC(allocator, config.ring_buffer_size);
    defer ring_buffer.deinit();

    const stats = try BenchmarkStats.init(allocator, config.num_producer_threads, 1);
    defer stats.deinit(allocator);

    const messages_per_producer = config.num_messages / config.num_producer_threads;

    std.log.info("开始MPSC基准测试: {} 生产者, {} 消息", .{ config.num_producer_threads, config.num_messages });
    stats.start_time = std.time.milliTimestamp();

    // 启动多个生产者线程
    const producers = try allocator.alloc(std.Thread, config.num_producer_threads);
    defer allocator.free(producers);

    for (producers, 0..) |*producer, i| {
        producer.* = try std.Thread.spawn(.{}, producerThread, .{ ring_buffer, stats, config, @as(u32, @intCast(i)), messages_per_producer });
    }

    // 启动消费者线程
    const consumer = try std.Thread.spawn(.{}, consumerThread, .{ ring_buffer, stats, config, 0, config.num_messages });

    // 等待所有线程完成
    for (producers) |producer| {
        producer.join();
    }
    consumer.join();

    stats.end_time = std.time.milliTimestamp();
    stats.print();
}

// 批处理器基准测试
fn benchmarkBatchProcessor(allocator: std.mem.Allocator, config: BenchmarkConfig) !void {
    std.log.info("=== 批处理器基准测试 ===", .{});

    const ring_buffer = try RingBufferFactory.createSPSC(allocator, config.ring_buffer_size);
    defer ring_buffer.deinit();

    var processed_count: u64 = 0;

    // 消息处理函数
    const MessageHandler = struct {
        fn handle(messages: []Message, context: *anyopaque) void {
            const counter = @as(*u64, @ptrCast(@alignCast(context)));
            counter.* += messages.len;

            // 模拟处理
            for (messages) |msg| {
                std.mem.doNotOptimizeAway(msg);
            }
        }
    };

    const batch_config = BatchConfig{
        .max_batch_size = config.batch_size,
        .adaptive_sizing = true,
    };

    const processor = try BatchProcessor.init(allocator, batch_config, MessageHandler.handle, &processed_count);
    defer processor.deinit();

    std.log.info("开始批处理器测试: {} 消息", .{config.num_messages});
    const start_time = std.time.milliTimestamp();

    // 生产者：填充Ring Buffer
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(rb: *RingBuffer, num_msgs: u64) void {
            var sent: u64 = 0;
            while (sent < num_msgs) {
                const msg = Message.createUser(.custom, "batch_test");
                if (rb.tryPublish(msg)) {
                    sent += 1;
                } else {
                    std.time.sleep(100);
                }
            }
        }
    }.run, .{ ring_buffer, config.num_messages });

    // 消费者：使用批处理器处理
    processor.start();

    while (processed_count < config.num_messages) {
        _ = processor.processBatch(ring_buffer);
        std.time.sleep(100);
    }

    processor.stop();
    producer.join();

    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;
    const throughput = @as(f64, @floatFromInt(processed_count)) / (@as(f64, @floatFromInt(duration_ms)) / 1000.0);

    std.log.info("批处理器结果:", .{});
    std.log.info("处理消息: {}", .{processed_count});
    std.log.info("耗时: {}ms", .{duration_ms});
    std.log.info("吞吐量: {d:.2} msg/s", .{throughput});
    std.log.info("吞吐量: {d:.2} M msg/s", .{throughput / 1_000_000.0});

    const stats = processor.getStats();
    std.log.info("平均批次大小: {d:.2}", .{stats.avg_batch_size});
    std.log.info("当前批次大小: {}", .{processor.getCurrentBatchSize()});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BenchmarkConfig{
        .ring_buffer_size = 1024 * 32, // 32K entries
        .num_messages = 5_000_000, // 5M messages
        .batch_size = 512,
        .num_producer_threads = 4,
        .warmup_messages = 50_000,
    };

    std.log.info("=== Ring Buffer高性能基准测试 ===", .{});
    std.log.info("配置: Ring Buffer大小={}, 消息数={}, 批次大小={}", .{ config.ring_buffer_size, config.num_messages, config.batch_size });

    // 运行各种基准测试
    try benchmarkSPSC(allocator, config);
    std.time.sleep(1 * std.time.ns_per_s);

    try benchmarkMPSC(allocator, config);
    std.time.sleep(1 * std.time.ns_per_s);

    try benchmarkBatchProcessor(allocator, config);
}
