//! 零拷贝消息传递实现
//! 基于内存映射和指针传递的高性能消息系统

const std = @import("std");
const Allocator = std.mem.Allocator;
const Message = @import("../message/message.zig").Message;

/// 零拷贝消息头
pub const ZeroCopyMessageHeader = struct {
    /// 消息类型标识
    type_id: u32,
    /// 消息大小
    size: u32,
    /// 发送者ID
    sender_id: u64,
    /// 时间戳
    timestamp: u64,
    /// 校验和
    checksum: u32,
    /// 保留字段
    reserved: u32 = 0,

    pub fn init(type_id: u32, size: u32, sender_id: u64) ZeroCopyMessageHeader {
        return ZeroCopyMessageHeader{
            .type_id = type_id,
            .size = size,
            .sender_id = sender_id,
            .timestamp = @intCast(std.time.milliTimestamp()),
            .checksum = calculateChecksum(type_id, size, sender_id),
        };
    }

    fn calculateChecksum(type_id: u32, size: u32, sender_id: u64) u32 {
        // 简单的校验和算法
        return type_id ^ size ^ @as(u32, @truncate(sender_id)) ^ @as(u32, @truncate(sender_id >> 32));
    }

    pub fn validate(self: *const ZeroCopyMessageHeader) bool {
        const expected = calculateChecksum(self.type_id, self.size, self.sender_id);
        return self.checksum == expected;
    }
};

/// 零拷贝消息
pub const ZeroCopyMessage = struct {
    /// 消息头
    header: ZeroCopyMessageHeader,
    /// 数据指针（不拥有内存）
    payload_ptr: ?*anyopaque,
    /// 数据长度
    payload_len: u32,

    pub fn fromBytes(bytes: []u8) !ZeroCopyMessage {
        if (bytes.len < @sizeOf(ZeroCopyMessageHeader)) {
            return error.InvalidMessageSize;
        }

        const header = @as(*ZeroCopyMessageHeader, @ptrCast(@alignCast(bytes.ptr))).*;
        if (!header.validate()) {
            return error.InvalidChecksum;
        }

        const payload_offset = @sizeOf(ZeroCopyMessageHeader);
        const payload_ptr = if (header.size > 0) bytes.ptr + payload_offset else null;
        const payload_len = header.size;

        if (bytes.len < payload_offset + payload_len) {
            return error.InvalidPayloadSize;
        }

        return ZeroCopyMessage{
            .header = header,
            .payload_ptr = payload_ptr,
            .payload_len = payload_len,
        };
    }

    pub fn toBytes(self: *const ZeroCopyMessage, buffer: []u8) ![]u8 {
        const total_size = @sizeOf(ZeroCopyMessageHeader) + self.payload_len;
        if (buffer.len < total_size) {
            return error.BufferTooSmall;
        }

        // 写入消息头
        @memcpy(buffer[0..@sizeOf(ZeroCopyMessageHeader)], std.mem.asBytes(&self.header));

        // 写入载荷（如果有）
        if (self.payload_ptr) |ptr| {
            const payload_bytes = @as([*]u8, @ptrCast(ptr))[0..self.payload_len];
            @memcpy(buffer[@sizeOf(ZeroCopyMessageHeader)..total_size], payload_bytes);
        }

        return buffer[0..total_size];
    }

    pub fn getPayload(self: *const ZeroCopyMessage, comptime T: type) ?*T {
        if (self.payload_ptr == null or self.payload_len < @sizeOf(T)) {
            return null;
        }
        return @as(*T, @ptrCast(@alignCast(self.payload_ptr.?)));
    }

    pub fn getPayloadSlice(self: *const ZeroCopyMessage, comptime T: type) ?[]T {
        if (self.payload_ptr == null or self.payload_len == 0) {
            return null;
        }
        const element_size = @sizeOf(T);
        if (self.payload_len % element_size != 0) {
            return null;
        }
        const count = self.payload_len / element_size;
        return @as([*]T, @ptrCast(@alignCast(self.payload_ptr.?)))[0..count];
    }
};

/// 零拷贝内存池
pub const ZeroCopyMemoryPool = struct {
    const Self = @This();

    /// 内存块
    const MemoryBlock = struct {
        data: []u8,
        in_use: std.atomic.Value(bool),
        next: ?*MemoryBlock,
    };

    allocator: Allocator,
    block_size: usize,
    blocks: []MemoryBlock,
    free_list: std.atomic.Value(?*MemoryBlock),
    total_blocks: usize,
    allocated_blocks: std.atomic.Value(usize),

    pub fn init(allocator: Allocator, block_size: usize, num_blocks: usize) !*Self {
        const self = try allocator.create(Self);
        const blocks = try allocator.alloc(MemoryBlock, num_blocks);

        // 初始化内存块
        for (blocks, 0..) |*block, i| {
            block.data = try allocator.alloc(u8, block_size);
            block.in_use = std.atomic.Value(bool).init(false);
            block.next = if (i + 1 < num_blocks) &blocks[i + 1] else null;
        }

        self.* = Self{
            .allocator = allocator,
            .block_size = block_size,
            .blocks = blocks,
            .free_list = std.atomic.Value(?*MemoryBlock).init(if (num_blocks > 0) &blocks[0] else null),
            .total_blocks = num_blocks,
            .allocated_blocks = std.atomic.Value(usize).init(0),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.blocks) |*block| {
            self.allocator.free(block.data);
        }
        self.allocator.free(self.blocks);
        self.allocator.destroy(self);
    }

    pub fn acquire(self: *Self) ?[]u8 {
        while (true) {
            const current_head = self.free_list.load(.acquire);
            if (current_head == null) {
                return null; // 没有可用块
            }

            const next = current_head.?.next;
            if (self.free_list.cmpxchgWeak(current_head, next, .release, .acquire) == null) {
                // 成功获取块
                current_head.?.in_use.store(true, .release);
                _ = self.allocated_blocks.fetchAdd(1, .acq_rel);
                return current_head.?.data;
            }
        }
    }

    pub fn release(self: *Self, data: []u8) void {
        // 找到对应的内存块
        for (self.blocks) |*block| {
            if (block.data.ptr == data.ptr and block.data.len == data.len) {
                if (block.in_use.load(.acquire)) {
                    block.in_use.store(false, .release);
                    _ = self.allocated_blocks.fetchSub(1, .acq_rel);

                    // 将块添加回空闲列表
                    while (true) {
                        const current_head = self.free_list.load(.acquire);
                        block.next = current_head;
                        if (self.free_list.cmpxchgWeak(current_head, block, .release, .acquire) == null) {
                            break;
                        }
                    }
                }
                return;
            }
        }
    }

    pub fn getStats(self: *const Self) struct { total: usize, allocated: usize, free: usize } {
        const allocated = self.allocated_blocks.load(.acquire);
        return .{
            .total = self.total_blocks,
            .allocated = allocated,
            .free = self.total_blocks - allocated,
        };
    }
};

/// 零拷贝消息传递器
pub const ZeroCopyMessenger = struct {
    const Self = @This();

    memory_pool: *ZeroCopyMemoryPool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, block_size: usize, num_blocks: usize) !*Self {
        const self = try allocator.create(Self);
        const memory_pool = try ZeroCopyMemoryPool.init(allocator, block_size, num_blocks);

        self.* = Self{
            .memory_pool = memory_pool,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.memory_pool.deinit();
        self.allocator.destroy(self);
    }

    /// 创建零拷贝消息
    pub fn createMessage(self: *Self, type_id: u32, sender_id: u64, payload: ?[]const u8) !ZeroCopyMessage {
        const payload_size = if (payload) |p| p.len else 0;
        const total_size = @sizeOf(ZeroCopyMessageHeader) + payload_size;

        // 从内存池获取缓冲区
        const buffer = self.memory_pool.acquire() orelse return error.OutOfMemory;
        if (buffer.len < total_size) {
            self.memory_pool.release(buffer);
            return error.MessageTooLarge;
        }

        // 创建消息头
        const header = ZeroCopyMessageHeader.init(type_id, @intCast(payload_size), sender_id);

        // 写入消息头
        @memcpy(buffer[0..@sizeOf(ZeroCopyMessageHeader)], std.mem.asBytes(&header));

        // 写入载荷
        var payload_ptr: ?*anyopaque = null;
        if (payload) |p| {
            @memcpy(buffer[@sizeOf(ZeroCopyMessageHeader)..total_size], p);
            payload_ptr = buffer.ptr + @sizeOf(ZeroCopyMessageHeader);
        }

        return ZeroCopyMessage{
            .header = header,
            .payload_ptr = payload_ptr,
            .payload_len = @intCast(payload_size),
        };
    }

    /// 释放零拷贝消息
    pub fn releaseMessage(self: *Self, message: *const ZeroCopyMessage) void {
        if (message.payload_ptr) |ptr| {
            // 计算原始缓冲区地址
            const buffer_ptr = @as([*]u8, @ptrCast(ptr)) - @sizeOf(ZeroCopyMessageHeader);
            const buffer_len = self.memory_pool.block_size;
            const buffer = buffer_ptr[0..buffer_len];
            self.memory_pool.release(buffer);
        }
    }

    /// 转换标准消息为零拷贝消息
    pub fn fromStandardMessage(self: *Self, message: *const Message, sender_id: u64) !ZeroCopyMessage {
        const type_id = switch (message.message_type) {
            .user => |user_type| @intFromEnum(user_type),
            .system => |system_type| @intFromEnum(system_type) + 1000,
            .control => |control_type| @intFromEnum(control_type) + 2000,
        };

        const payload = switch (message.payload) {
            .none => null,
            .static_string => |s| s,
            .owned_string => |s| s,
            .bytes => |b| b,
            .custom => |c| c,
        };

        return self.createMessage(type_id, sender_id, payload);
    }

    /// 获取内存池统计信息
    pub fn getStats(self: *const Self) struct { total: usize, allocated: usize, free: usize } {
        const pool_stats = self.memory_pool.getStats();
        return .{
            .total = pool_stats.total,
            .allocated = pool_stats.allocated,
            .free = pool_stats.free,
        };
    }
};

// 测试
test "ZeroCopyMessage basic operations" {
    const testing = std.testing;

    const header = ZeroCopyMessageHeader.init(1, 10, 123);
    try testing.expect(header.validate());
    try testing.expect(header.type_id == 1);
    try testing.expect(header.size == 10);
    try testing.expect(header.sender_id == 123);
}

test "ZeroCopyMemoryPool operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const pool = try ZeroCopyMemoryPool.init(allocator, 1024, 10);
    defer pool.deinit();

    // 测试获取和释放内存块
    const block1 = pool.acquire();
    try testing.expect(block1 != null);
    try testing.expect(block1.?.len == 1024);

    const stats1 = pool.getStats();
    try testing.expect(stats1.allocated == 1);
    try testing.expect(stats1.free == 9);

    pool.release(block1.?);

    const stats2 = pool.getStats();
    try testing.expect(stats2.allocated == 0);
    try testing.expect(stats2.free == 10);
}

test "ZeroCopyMessenger operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const messenger = try ZeroCopyMessenger.init(allocator, 1024, 10);
    defer messenger.deinit();

    // 创建消息
    const payload = "Hello, World!";
    const message = try messenger.createMessage(1, 123, payload);

    try testing.expect(message.header.type_id == 1);
    try testing.expect(message.header.sender_id == 123);
    try testing.expect(message.payload_len == payload.len);

    // 验证载荷
    const received_payload = message.getPayloadSlice(u8);
    try testing.expect(received_payload != null);
    try testing.expect(std.mem.eql(u8, received_payload.?, payload));

    // 释放消息
    messenger.releaseMessage(&message);

    const stats = messenger.getStats();
    try testing.expect(stats.allocated == 0);
}
