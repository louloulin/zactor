//! 高性能批处理消息处理器
//! 通过批量处理消息来减少系统调用开销和提高缓存效率

const std = @import("std");
const Allocator = std.mem.Allocator;
const Message = @import("../message/message.zig").Message;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

/// 批处理配置
pub const BatchConfig = struct {
    /// 最小批处理大小
    min_batch_size: u32 = 16,
    /// 最大批处理大小
    max_batch_size: u32 = 1024,
    /// 初始批处理大小
    initial_batch_size: u32 = 64,
    /// 批处理超时时间（纳秒）
    batch_timeout_ns: u64 = 1000, // 1μs
    /// 自适应调整启用
    adaptive_sizing: bool = true,
    /// 延迟目标（纳秒）
    target_latency_ns: u64 = 10000, // 10μs
    /// 吞吐量目标（消息/秒）
    target_throughput: u64 = 1000000, // 1M msg/s
};

/// 批处理统计信息
pub const BatchStats = struct {
    total_batches: u64 = 0,
    total_messages: u64 = 0,
    total_latency_ns: u64 = 0,
    min_batch_size: u32 = std.math.maxInt(u32),
    max_batch_size: u32 = 0,
    avg_batch_size: f64 = 0.0,
    avg_latency_ns: f64 = 0.0,
    throughput: f64 = 0.0,

    pub fn update(self: *BatchStats, batch_size: u32, latency_ns: u64) void {
        self.total_batches += 1;
        self.total_messages += batch_size;
        self.total_latency_ns += latency_ns;
        self.min_batch_size = @min(self.min_batch_size, batch_size);
        self.max_batch_size = @max(self.max_batch_size, batch_size);

        self.avg_batch_size = @as(f64, @floatFromInt(self.total_messages)) / @as(f64, @floatFromInt(self.total_batches));
        self.avg_latency_ns = @as(f64, @floatFromInt(self.total_latency_ns)) / @as(f64, @floatFromInt(self.total_batches));

        // 计算吞吐量（消息/秒）
        const total_time_s = @as(f64, @floatFromInt(self.total_latency_ns)) / 1_000_000_000.0;
        if (total_time_s > 0) {
            self.throughput = @as(f64, @floatFromInt(self.total_messages)) / total_time_s;
        }
    }

    pub fn reset(self: *BatchStats) void {
        self.* = BatchStats{};
    }
};

/// 自适应批处理器
pub const AdaptiveBatcher = struct {
    const Self = @This();

    config: BatchConfig,
    current_batch_size: u32,
    stats: BatchStats,
    last_adjustment_time: i128,
    adjustment_interval_ns: i128 = 1_000_000, // 1ms

    pub fn init(config: BatchConfig) Self {
        return Self{
            .config = config,
            .current_batch_size = config.initial_batch_size,
            .stats = BatchStats{},
            .last_adjustment_time = std.time.nanoTimestamp(),
        };
    }

    /// 获取当前批处理大小
    pub fn getBatchSize(self: *const Self) u32 {
        return self.current_batch_size;
    }

    /// 记录批处理性能并自适应调整
    pub fn recordBatch(self: *Self, batch_size: u32, latency_ns: u64) void {
        self.stats.update(batch_size, latency_ns);

        if (self.config.adaptive_sizing) {
            self.adaptBatchSize();
        }
    }

    /// 自适应调整批处理大小
    fn adaptBatchSize(self: *Self) void {
        const now = std.time.nanoTimestamp();
        if (now - self.last_adjustment_time < self.adjustment_interval_ns) {
            return; // 调整间隔未到
        }

        const avg_latency = self.stats.avg_latency_ns;
        const throughput = self.stats.throughput;

        // 基于延迟和吞吐量调整批处理大小
        if (avg_latency > @as(f64, @floatFromInt(self.config.target_latency_ns))) {
            // 延迟过高，减小批处理大小
            self.current_batch_size = @max(self.config.min_batch_size, self.current_batch_size * 3 / 4);
        } else if (throughput < @as(f64, @floatFromInt(self.config.target_throughput))) {
            // 吞吐量不足，增大批处理大小
            self.current_batch_size = @min(self.config.max_batch_size, self.current_batch_size * 5 / 4);
        }

        self.last_adjustment_time = now;
    }

    /// 获取统计信息
    pub fn getStats(self: *const Self) BatchStats {
        return self.stats;
    }

    /// 重置统计信息
    pub fn resetStats(self: *Self) void {
        self.stats.reset();
    }
};

/// 批处理消息处理器
pub const BatchProcessor = struct {
    const Self = @This();

    /// 消息处理函数类型
    pub const MessageHandler = *const fn (messages: []Message, context: *anyopaque) void;

    allocator: Allocator,
    batcher: AdaptiveBatcher,
    message_buffer: []Message,
    handler: MessageHandler,
    context: *anyopaque,
    running: std.atomic.Value(bool),

    pub fn init(allocator: Allocator, config: BatchConfig, handler: MessageHandler, context: *anyopaque) !*Self {
        const self = try allocator.create(Self);
        const buffer = try allocator.alloc(Message, config.max_batch_size);

        self.* = Self{
            .allocator = allocator,
            .batcher = AdaptiveBatcher.init(config),
            .message_buffer = buffer,
            .handler = handler,
            .context = context,
            .running = std.atomic.Value(bool).init(false),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.free(self.message_buffer);
        self.allocator.destroy(self);
    }

    /// 启动批处理器
    pub fn start(self: *Self) void {
        self.running.store(true, .release);
    }

    /// 停止批处理器
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// 处理来自Ring Buffer的消息批次
    pub fn processBatch(self: *Self, ring_buffer: *RingBuffer) u32 {
        if (!self.running.load(.acquire)) {
            return 0;
        }

        const batch_size = self.batcher.getBatchSize();
        const start_time = std.time.nanoTimestamp();

        // 从Ring Buffer批量消费消息
        const consumed = ring_buffer.tryConsumeBatch(self.message_buffer[0..batch_size]);
        if (consumed == 0) {
            return 0;
        }

        // 处理消息批次
        self.handler(self.message_buffer[0..consumed], self.context);

        const end_time = std.time.nanoTimestamp();
        const latency = @as(u64, @intCast(end_time - start_time));

        // 记录性能并自适应调整
        self.batcher.recordBatch(consumed, latency);

        return consumed;
    }

    /// 处理单个消息（用于兼容性）
    pub fn processMessage(self: *Self, message: Message) void {
        if (!self.running.load(.acquire)) {
            return;
        }

        self.message_buffer[0] = message;
        self.handler(self.message_buffer[0..1], self.context);
    }

    /// 获取批处理器统计信息
    pub fn getStats(self: *const Self) BatchStats {
        return self.batcher.getStats();
    }

    /// 重置统计信息
    pub fn resetStats(self: *Self) void {
        self.batcher.resetStats();
    }

    /// 获取当前批处理大小
    pub fn getCurrentBatchSize(self: *const Self) u32 {
        return self.batcher.getBatchSize();
    }
};

/// 高性能消息处理循环
pub const MessageProcessingLoop = struct {
    const Self = @This();

    processor: *BatchProcessor,
    ring_buffer: *RingBuffer,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),

    pub fn init(processor: *BatchProcessor, ring_buffer: *RingBuffer) Self {
        return Self{
            .processor = processor,
            .ring_buffer = ring_buffer,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// 启动处理循环
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.processor.start();

        self.thread = try std.Thread.spawn(.{}, processingLoop, .{self});
    }

    /// 停止处理循环
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        self.processor.stop();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// 处理循环主函数
    fn processingLoop(self: *Self) void {
        while (self.running.load(.acquire)) {
            const processed = self.processor.processBatch(self.ring_buffer);

            if (processed == 0) {
                // 没有消息时短暂休眠，避免CPU空转
                std.time.sleep(100); // 100ns
            }
        }
    }

    /// 获取处理统计信息
    pub fn getStats(self: *const Self) BatchStats {
        return self.processor.getStats();
    }
};

// 测试用消息处理函数
fn testMessageHandler(messages: []Message, context: *anyopaque) void {
    const counter = @as(*u64, @ptrCast(@alignCast(context)));
    counter.* += messages.len;
}

// 测试
test "AdaptiveBatcher basic functionality" {
    const testing = std.testing;

    var batcher = AdaptiveBatcher.init(BatchConfig{});

    // 测试初始状态
    try testing.expect(batcher.getBatchSize() == 64);

    // 记录一些批次
    batcher.recordBatch(64, 5000); // 5μs
    batcher.recordBatch(64, 8000); // 8μs

    const stats = batcher.getStats();
    try testing.expect(stats.total_batches == 2);
    try testing.expect(stats.total_messages == 128);
}

test "BatchProcessor basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var counter: u64 = 0;
    const processor = try BatchProcessor.init(allocator, BatchConfig{ .max_batch_size = 16 }, testMessageHandler, &counter);
    defer processor.deinit();

    processor.start();

    // 测试单个消息处理
    const test_message = Message.createUser(.text, "test");
    processor.processMessage(test_message);

    try testing.expect(counter == 1);

    processor.stop();
}
