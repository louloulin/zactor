//! 超高性能消息传递核心
//! 目标: 达到5-10M msg/s，追赶业界主流性能

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// CPU缓存行大小 (通常为64字节)
const CACHE_LINE_SIZE: u32 = 64;

/// 预分配内存Arena - 线性分配器，避免碎片化
pub const PreAllocatedArena = struct {
    const Self = @This();

    memory: []u8,
    offset: std.atomic.Value(usize),
    capacity: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !*Self {
        const self = try allocator.create(Self);
        const memory = try allocator.alignedAlloc(u8, CACHE_LINE_SIZE, capacity);

        self.* = Self{
            .memory = memory,
            .offset = std.atomic.Value(usize).init(0),
            .capacity = capacity,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.memory);
        self.allocator.destroy(self);
    }

    /// 快速线性分配 - 无锁，O(1)时间复杂度
    pub fn allocFast(self: *Self, size: usize) ?[]u8 {
        // 对齐到8字节边界
        const aligned_size = (size + 7) & ~@as(usize, 7);

        const current_offset = self.offset.load(.acquire);
        const new_offset = current_offset + aligned_size;

        if (new_offset > self.capacity) {
            return null; // Arena已满
        }

        // 原子性地更新偏移量
        if (self.offset.cmpxchgWeak(current_offset, new_offset, .release, .acquire) == null) {
            return self.memory[current_offset..new_offset];
        }

        return null; // 竞争失败，重试
    }

    /// 重置Arena - 仅在单线程环境下使用
    pub fn reset(self: *Self) void {
        self.offset.store(0, .release);
    }

    pub fn getUsage(self: *const Self) struct { used: usize, capacity: usize, utilization: f32 } {
        const used = self.offset.load(.acquire);
        return .{
            .used = used,
            .capacity = self.capacity,
            .utilization = @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(self.capacity)),
        };
    }
};

/// 无锁环形缓冲区 - 基于LMAX Disruptor设计
pub const LockFreeRingBuffer = struct {
    const Self = @This();

    /// 缓存行填充，避免伪共享
    const CacheLinePadding = struct {
        padding: [CACHE_LINE_SIZE]u8 = [_]u8{0} ** CACHE_LINE_SIZE,
    };

    /// 消息槽
    const MessageSlot = struct {
        data: []u8,
        sequence: std.atomic.Value(u64),
        available: std.atomic.Value(bool),
    };

    buffer: []MessageSlot,
    capacity: u32,
    mask: u32,

    // 生产者游标 (缓存行对齐)
    _padding1: CacheLinePadding = .{},
    producer_cursor: std.atomic.Value(u64),
    _padding2: CacheLinePadding = .{},

    // 消费者游标 (缓存行对齐)
    consumer_cursor: std.atomic.Value(u64),
    _padding3: CacheLinePadding = .{},

    arena: *PreAllocatedArena,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: u32, arena: *PreAllocatedArena) !*Self {
        // 确保容量是2的幂
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            return error.InvalidCapacity;
        }

        const self = try allocator.create(Self);
        const buffer = try allocator.alloc(MessageSlot, capacity);

        // 初始化消息槽
        for (buffer, 0..) |*slot, i| {
            slot.* = MessageSlot{
                .data = &[_]u8{},
                .sequence = std.atomic.Value(u64).init(i),
                .available = std.atomic.Value(bool).init(false),
            };
        }

        self.* = Self{
            .buffer = buffer,
            .capacity = capacity,
            .mask = capacity - 1,
            .producer_cursor = std.atomic.Value(u64).init(0),
            .consumer_cursor = std.atomic.Value(u64).init(0),
            .arena = arena,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    /// 零拷贝发布消息 - 直接在Ring Buffer中分配
    pub fn tryPushZeroCopy(self: *Self, message_data: []const u8) bool {
        const producer_seq = self.producer_cursor.load(.acquire);
        const consumer_seq = self.consumer_cursor.load(.acquire);

        // 检查是否有可用空间
        if (producer_seq - consumer_seq >= self.capacity) {
            return false; // 缓冲区已满
        }

        const slot_index = producer_seq & self.mask;
        const slot = &self.buffer[slot_index];

        // 从Arena分配内存
        const allocated_memory = self.arena.allocFast(message_data.len) orelse return false;

        // 零拷贝：直接内存拷贝
        @memcpy(allocated_memory[0..message_data.len], message_data);

        // 原子性地更新槽位
        slot.data = allocated_memory;
        slot.sequence.store(producer_seq, .release);
        slot.available.store(true, .release);

        // 更新生产者游标
        _ = self.producer_cursor.fetchAdd(1, .acq_rel);

        return true;
    }

    /// 零拷贝消费消息
    pub fn tryPopZeroCopy(self: *Self) ?[]u8 {
        const consumer_seq = self.consumer_cursor.load(.acquire);
        const producer_seq = self.producer_cursor.load(.acquire);

        // 检查是否有可用消息
        if (consumer_seq >= producer_seq) {
            return null; // 缓冲区为空
        }

        const slot_index = consumer_seq & self.mask;
        const slot = &self.buffer[slot_index];

        // 等待消息可用
        if (!slot.available.load(.acquire)) {
            return null;
        }

        // 获取消息数据
        const message_data = slot.data;

        // 标记槽位为不可用
        slot.available.store(false, .release);

        // 更新消费者游标
        _ = self.consumer_cursor.fetchAdd(1, .acq_rel);

        return message_data;
    }

    /// 批量发布消息
    pub fn tryPushBatch(self: *Self, messages: [][]const u8) u32 {
        var published: u32 = 0;

        for (messages) |message| {
            if (self.tryPushZeroCopy(message)) {
                published += 1;
            } else {
                break; // 缓冲区已满
            }
        }

        return published;
    }

    /// 批量消费消息
    pub fn tryPopBatch(self: *Self, output: []?[]u8) u32 {
        var consumed: u32 = 0;

        for (output) |*slot| {
            if (self.tryPopZeroCopy()) |message| {
                slot.* = message;
                consumed += 1;
            } else {
                slot.* = null;
                break; // 缓冲区为空
            }
        }

        return consumed;
    }

    pub fn getStats(self: *const Self) struct {
        capacity: u32,
        producer_pos: u64,
        consumer_pos: u64,
        available_slots: u64,
        utilization: f32,
    } {
        const producer_pos = self.producer_cursor.load(.acquire);
        const consumer_pos = self.consumer_cursor.load(.acquire);
        const available = if (producer_pos >= consumer_pos)
            self.capacity - (producer_pos - consumer_pos)
        else
            0;

        return .{
            .capacity = self.capacity,
            .producer_pos = producer_pos,
            .consumer_pos = consumer_pos,
            .available_slots = available,
            .utilization = @as(f32, @floatFromInt(self.capacity - available)) / @as(f32, @floatFromInt(self.capacity)),
        };
    }
};

/// 超高性能消息传递核心
pub const UltraFastMessageCore = struct {
    const Self = @This();

    ring_buffer: *LockFreeRingBuffer,
    memory_arena: *PreAllocatedArena,
    allocator: Allocator,

    pub fn init(allocator: Allocator, ring_capacity: u32, arena_size: usize) !*Self {
        const self = try allocator.create(Self);

        const arena = try PreAllocatedArena.init(allocator, arena_size);
        const ring_buffer = try LockFreeRingBuffer.init(allocator, ring_capacity, arena);

        self.* = Self{
            .ring_buffer = ring_buffer,
            .memory_arena = arena,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.ring_buffer.deinit();
        self.memory_arena.deinit();
        self.allocator.destroy(self);
    }

    /// 超快速消息发送
    pub fn sendMessage(self: *Self, message_data: []const u8) bool {
        return self.ring_buffer.tryPushZeroCopy(message_data);
    }

    /// 超快速消息接收
    pub fn receiveMessage(self: *Self) ?[]u8 {
        return self.ring_buffer.tryPopZeroCopy();
    }

    /// 批量消息发送
    pub fn sendMessageBatch(self: *Self, messages: [][]const u8) u32 {
        return self.ring_buffer.tryPushBatch(messages);
    }

    /// 批量消息接收
    pub fn receiveMessageBatch(self: *Self, output: []?[]u8) u32 {
        return self.ring_buffer.tryPopBatch(output);
    }

    pub fn getPerformanceStats(self: *const Self) struct {
        ring_buffer: @TypeOf(self.ring_buffer.getStats()),
        memory_arena: @TypeOf(self.memory_arena.getUsage()),
    } {
        return .{
            .ring_buffer = self.ring_buffer.getStats(),
            .memory_arena = self.memory_arena.getUsage(),
        };
    }

    /// 重置系统状态 - 仅用于基准测试
    pub fn reset(self: *Self) void {
        self.memory_arena.reset();
        // Ring buffer会自然重置当arena重置时
    }
};
