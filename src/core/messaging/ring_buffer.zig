//! 高性能无锁Ring Buffer实现
//! 基于LMAX Disruptor设计，支持单生产者单消费者(SPSC)和多生产者单消费者(MPSC)模式

const std = @import("std");
const Allocator = std.mem.Allocator;
const Message = @import("../message/message.zig").Message;

/// Ring Buffer配置
pub const RingBufferConfig = struct {
    /// 缓冲区大小，必须是2的幂
    capacity: u32 = 1024 * 16, // 16K entries
    /// 是否启用多生产者模式
    multi_producer: bool = false,
    /// 缓存行大小，用于避免false sharing
    cache_line_size: u32 = 64,
};

/// 高性能无锁Ring Buffer
pub const RingBuffer = struct {
    const Self = @This();

    /// 消息缓冲区
    buffer: []Message,
    /// 缓冲区容量（2的幂）
    capacity: u32,
    /// 位掩码，用于快速取模
    mask: u32,
    /// 生产者游标
    cursor: std.atomic.Value(u64),
    /// 消费者游标
    gate: std.atomic.Value(u64),
    /// 缓存的消费者位置（减少原子操作）
    cached_gate: u64,
    /// 配置
    config: RingBufferConfig,
    /// 内存分配器
    allocator: Allocator,

    /// 填充字节，避免false sharing
    _padding1: [64]u8 = [_]u8{0} ** 64,

    pub fn init(allocator: Allocator, config: RingBufferConfig) !*Self {
        // 确保容量是2的幂
        if (!std.math.isPowerOfTwo(config.capacity)) {
            return error.InvalidCapacity;
        }

        const self = try allocator.create(Self);
        const buffer = try allocator.alloc(Message, config.capacity);

        self.* = Self{
            .buffer = buffer,
            .capacity = config.capacity,
            .mask = config.capacity - 1,
            .cursor = std.atomic.Value(u64).init(0),
            .gate = std.atomic.Value(u64).init(0),
            .cached_gate = 0,
            .config = config,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    /// 尝试发布单个消息（无锁）
    pub fn tryPublish(self: *Self, message: Message) bool {
        const current_cursor = self.cursor.load(.monotonic);
        const next_cursor = current_cursor + 1;

        // 检查是否有足够空间
        const gate = self.gate.load(.acquire);
        if (next_cursor - gate > self.capacity) {
            return false; // 缓冲区满
        }

        // 写入消息
        const index = current_cursor & self.mask;
        self.buffer[index] = message;

        // 更新游标
        if (self.config.multi_producer) {
            // 多生产者模式：使用CAS确保原子性
            return self.cursor.cmpxchgWeak(current_cursor, next_cursor, .release, .monotonic) == null;
        } else {
            // 单生产者模式：直接存储
            self.cursor.store(next_cursor, .release);
            return true;
        }
    }

    /// 批量发布消息
    pub fn tryPublishBatch(self: *Self, messages: []const Message) u32 {
        if (messages.len == 0) return 0;

        const current_cursor = self.cursor.load(.monotonic);
        const available_space = self.getAvailableSpace(current_cursor);
        const publish_count = @min(messages.len, available_space);

        if (publish_count == 0) return 0;

        // 批量写入消息
        for (messages[0..publish_count], 0..) |message, i| {
            const index = (current_cursor + i) & self.mask;
            self.buffer[index] = message;
        }

        // 更新游标
        const next_cursor = current_cursor + publish_count;
        if (self.config.multi_producer) {
            // 多生产者模式需要CAS
            if (self.cursor.cmpxchgWeak(current_cursor, next_cursor, .release, .monotonic) != null) {
                return 0; // CAS失败
            }
        } else {
            self.cursor.store(next_cursor, .release);
        }

        return @intCast(publish_count);
    }

    /// 尝试消费单个消息
    pub fn tryConsume(self: *Self) ?Message {
        const current_gate = self.gate.load(.monotonic);
        const cursor = self.cursor.load(.acquire);

        if (current_gate >= cursor) {
            return null; // 没有可用消息
        }

        // 读取消息
        const index = current_gate & self.mask;
        const message = self.buffer[index];

        // 更新gate
        self.gate.store(current_gate + 1, .release);

        return message;
    }

    /// 批量消费消息
    pub fn tryConsumeBatch(self: *Self, messages: []Message) u32 {
        if (messages.len == 0) return 0;

        const current_gate = self.gate.load(.monotonic);
        const cursor = self.cursor.load(.acquire);
        const available_messages = cursor - current_gate;

        if (available_messages == 0) return 0;

        const consume_count = @min(messages.len, available_messages);

        // 批量读取消息
        for (0..consume_count) |i| {
            const index = (current_gate + i) & self.mask;
            messages[i] = self.buffer[index];
        }

        // 更新gate
        self.gate.store(current_gate + consume_count, .release);

        return @intCast(consume_count);
    }

    /// 获取可用空间
    fn getAvailableSpace(self: *Self, cursor: u64) u32 {
        const gate = self.gate.load(.acquire); // 直接读取最新的gate位置
        if (cursor >= gate + self.capacity) {
            return 0; // 缓冲区满
        }
        const used_space = cursor - gate;
        return @intCast(self.capacity - used_space);
    }

    /// 获取缓存的gate位置
    fn getCachedGate(self: *Self) u64 {
        return self.cached_gate;
    }

    /// 获取当前使用的空间
    pub fn getUsedSpace(self: *Self) u32 {
        const cursor = self.cursor.load(.monotonic);
        const gate = self.gate.load(.monotonic);
        return @intCast(cursor - gate);
    }

    /// 获取剩余空间
    pub fn getRemainingSpace(self: *Self) u32 {
        return self.capacity - self.getUsedSpace();
    }

    /// 检查是否为空
    pub fn isEmpty(self: *Self) bool {
        const cursor = self.cursor.load(.monotonic);
        const gate = self.gate.load(.monotonic);
        return cursor == gate;
    }

    /// 检查是否已满
    pub fn isFull(self: *Self) bool {
        return self.getRemainingSpace() == 0;
    }

    /// 获取性能统计信息
    pub const Stats = struct {
        cursor_position: u64,
        gate_position: u64,
        used_space: u32,
        remaining_space: u32,
        capacity: u32,
        utilization: f64,
    };

    pub fn getStats(self: *Self) Stats {
        const cursor = self.cursor.load(.monotonic);
        const gate = self.gate.load(.monotonic);
        const used = @as(u32, @intCast(cursor - gate));
        const remaining = self.capacity - used;
        const utilization = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.capacity));

        return Stats{
            .cursor_position = cursor,
            .gate_position = gate,
            .used_space = used,
            .remaining_space = remaining,
            .capacity = self.capacity,
            .utilization = utilization,
        };
    }
};

/// Ring Buffer工厂
pub const RingBufferFactory = struct {
    pub fn createSPSC(allocator: Allocator, capacity: u32) !*RingBuffer {
        const config = RingBufferConfig{
            .capacity = capacity,
            .multi_producer = false,
        };
        return RingBuffer.init(allocator, config);
    }

    pub fn createMPSC(allocator: Allocator, capacity: u32) !*RingBuffer {
        const config = RingBufferConfig{
            .capacity = capacity,
            .multi_producer = true,
        };
        return RingBuffer.init(allocator, config);
    }
};

// 测试
test "RingBuffer basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ring_buffer = try RingBufferFactory.createSPSC(allocator, 16);
    defer ring_buffer.deinit();

    // 测试发布和消费
    const test_message = Message.createUser(.custom, "test");

    // 发布消息
    try testing.expect(ring_buffer.tryPublish(test_message));
    try testing.expect(!ring_buffer.isEmpty());
    try testing.expect(ring_buffer.getUsedSpace() == 1);

    // 消费消息
    const consumed = ring_buffer.tryConsume();
    try testing.expect(consumed != null);
    try testing.expect(ring_buffer.isEmpty());
    try testing.expect(ring_buffer.getUsedSpace() == 0);
}

test "RingBuffer batch operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ring_buffer = try RingBufferFactory.createSPSC(allocator, 16);
    defer ring_buffer.deinit();

    // 准备测试消息
    var messages: [8]Message = undefined;
    for (&messages, 0..) |*msg, i| {
        msg.* = Message.createUser(.custom, "test");
        _ = i;
    }

    // 批量发布
    const published = ring_buffer.tryPublishBatch(&messages);
    try testing.expect(published == 8);
    try testing.expect(ring_buffer.getUsedSpace() == 8);

    // 批量消费
    var consumed_messages: [8]Message = undefined;
    const consumed = ring_buffer.tryConsumeBatch(&consumed_messages);
    try testing.expect(consumed == 8);
    try testing.expect(ring_buffer.isEmpty());
}
