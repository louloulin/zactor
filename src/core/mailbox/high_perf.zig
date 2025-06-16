//! High Performance Mailbox Implementation - 高性能邮箱实现
//! 基于内存池和SIMD优化的超高性能邮箱

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Message = @import("../message/mod.zig").Message;
const MailboxConfig = @import("mod.zig").MailboxConfig;
const MailboxStats = @import("mod.zig").MailboxStats;
const MailboxInterface = @import("mod.zig").MailboxInterface;
const ObjectPool = @import("../../utils/memory.zig").ObjectPool;

// 高性能邮箱实现 - 使用内存池和SIMD优化
pub const HighPerfMailbox = struct {
    const Self = @This();
    
    // 环形缓冲区 - 针对缓存友好性优化
    buffer: []Message,
    head: std.atomic.Atomic(u32),
    tail: std.atomic.Atomic(u32),
    capacity: u32,
    mask: u32, // 用于快速模运算
    
    // 内存池用于消息分配
    message_pool: ?*ObjectPool(Message),
    
    // 统计信息
    stats: ?MailboxStats,
    config: MailboxConfig,
    allocator: Allocator,
    
    // 缓存行填充，避免伪共享
    _padding1: [64]u8 = [_]u8{0} ** 64,
    
    // 虚函数表
    pub const vtable = MailboxInterface.VTable{
        .send = send,
        .receive = receive,
        .isEmpty = isEmpty,
        .size = size,
        .capacity = getCapacity,
        .deinit = deinit,
        .getStats = getStats,
    };
    
    pub fn init(allocator: Allocator, config: MailboxConfig) !Self {
        // 确保容量是2的幂，用于快速模运算
        const actual_capacity = std.math.ceilPowerOfTwo(u32, config.capacity) catch config.capacity;
        const buffer = try allocator.alloc(Message, actual_capacity);
        
        // 初始化内存池（如果启用）
        var message_pool: ?*ObjectPool(Message) = null;
        if (config.use_memory_pool) {
            message_pool = try allocator.create(ObjectPool(Message));
            message_pool.?.* = try ObjectPool(Message).init(allocator, config.pool_size orelse 1000);
        }
        
        return Self{
            .buffer = buffer,
            .head = std.atomic.Atomic(u32).init(0),
            .tail = std.atomic.Atomic(u32).init(0),
            .capacity = actual_capacity,
            .mask = actual_capacity - 1,
            .message_pool = message_pool,
            .stats = if (config.enable_statistics) MailboxStats.init() else null,
            .config = config,
            .allocator = allocator,
        };
    }
    
    // 虚函数实现
    fn send(ptr: *anyopaque, message: Message) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.sendMessage(message);
    }
    
    fn receive(ptr: *anyopaque) ?Message {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receiveMessage();
    }
    
    fn isEmpty(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.isEmptyImpl();
    }
    
    fn size(ptr: *anyopaque) u32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.sizeImpl();
    }
    
    fn getCapacity(ptr: *anyopaque) u32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.capacity;
    }
    
    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinitImpl();
    }
    
    fn getStats(ptr: *anyopaque) ?*MailboxStats {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return if (self.stats) |*stats| stats else null;
    }
    
    // 实际实现方法
    pub fn sendMessage(self: *Self, message: Message) !void {
        const current_tail = self.tail.load(.acquire);
        const next_tail = (current_tail + 1) & self.mask;
        const current_head = self.head.load(.acquire);
        
        // 检查队列是否已满
        if (next_tail == current_head) {
            if (self.stats) |*stats| {
                stats.incrementDropped();
            }
            return error.MailboxFull;
        }
        
        // 使用内存屏障确保写入顺序
        self.buffer[current_tail] = message;
        std.atomic.fence(.release);
        
        // 更新tail指针
        self.tail.store(next_tail, .release);
        
        if (self.stats) |*stats| {
            stats.incrementSent();
            const current_size = self.sizeImpl();
            stats.updatePeakQueueSize(current_size);
        }
    }
    
    pub fn receiveMessage(self: *Self) ?Message {
        const current_head = self.head.load(.acquire);
        const current_tail = self.tail.load(.acquire);
        
        // 检查队列是否为空
        if (current_head == current_tail) {
            return null;
        }
        
        // 读取消息
        const message = self.buffer[current_head];
        std.atomic.fence(.release);
        
        // 更新head指针
        const next_head = (current_head + 1) & self.mask;
        self.head.store(next_head, .release);
        
        if (self.stats) |*stats| {
            stats.incrementReceived();
        }
        
        return message;
    }
    
    pub fn isEmptyImpl(self: *const Self) bool {
        const current_head = self.head.load(.acquire);
        const current_tail = self.tail.load(.acquire);
        return current_head == current_tail;
    }
    
    pub fn sizeImpl(self: *const Self) u32 {
        const current_head = self.head.load(.acquire);
        const current_tail = self.tail.load(.acquire);
        return (current_tail - current_head) & self.mask;
    }
    
    pub fn deinitImpl(self: *Self) void {
        // 清理剩余消息
        while (self.receiveMessage()) |message| {
            message.deinit(self.allocator);
        }
        
        // 释放内存池
        if (self.message_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
        
        // 释放缓冲区
        self.allocator.free(self.buffer);
    }
    
    // SIMD优化的批量操作
    pub fn sendBatch(self: *Self, messages: []const Message) !u32 {
        if (!self.config.enable_batching) {
            // 逐个发送
            var sent_count: u32 = 0;
            for (messages) |message| {
                self.sendMessage(message) catch break;
                sent_count += 1;
            }
            return sent_count;
        }
        
        const current_tail = self.tail.load(.acquire);
        const current_head = self.head.load(.acquire);
        
        // 计算可用空间
        const available_space = if (current_head > current_tail) 
            current_head - current_tail - 1
        else 
            self.capacity - (current_tail - current_head) - 1;
        
        const batch_size = @min(messages.len, available_space);
        if (batch_size == 0) {
            return 0;
        }
        
        // 批量复制消息
        var copied: u32 = 0;
        var tail_pos = current_tail;
        
        while (copied < batch_size) {
            const chunk_size = @min(batch_size - copied, self.capacity - tail_pos);
            
            // 使用SIMD优化的内存复制（如果可能）
            if (chunk_size >= 4 and @sizeOf(Message) % 16 == 0) {
                // 向量化复制
                const src_ptr = @as([*]const u8, @ptrCast(&messages[copied]));
                const dst_ptr = @as([*]u8, @ptrCast(&self.buffer[tail_pos]));
                const bytes_to_copy = chunk_size * @sizeOf(Message);
                
                @memcpy(dst_ptr[0..bytes_to_copy], src_ptr[0..bytes_to_copy]);
            } else {
                // 标准复制
                for (0..chunk_size) |i| {
                    self.buffer[tail_pos + i] = messages[copied + i];
                }
            }
            
            copied += @intCast(chunk_size);
            tail_pos = (tail_pos + chunk_size) & self.mask;
        }
        
        // 内存屏障确保写入完成
        std.atomic.fence(.release);
        
        // 更新tail指针
        self.tail.store(tail_pos, .release);
        
        if (self.stats) |*stats| {
            var i: u32 = 0;
            while (i < copied) : (i += 1) {
                stats.incrementSent();
            }
            const current_size = self.sizeImpl();
            stats.updatePeakQueueSize(current_size);
        }
        
        return copied;
    }
    
    pub fn receiveBatch(self: *Self, buffer: []Message) u32 {
        if (!self.config.enable_batching) {
            // 逐个接收
            var received_count: u32 = 0;
            for (buffer) |*slot| {
                if (self.receiveMessage()) |message| {
                    slot.* = message;
                    received_count += 1;
                } else {
                    break;
                }
            }
            return received_count;
        }
        
        const current_head = self.head.load(.acquire);
        const current_tail = self.tail.load(.acquire);
        
        // 计算可用消息数量
        const available_messages = (current_tail - current_head) & self.mask;
        const batch_size = @min(buffer.len, available_messages);
        
        if (batch_size == 0) {
            return 0;
        }
        
        // 批量复制消息
        var copied: u32 = 0;
        var head_pos = current_head;
        
        while (copied < batch_size) {
            const chunk_size = @min(batch_size - copied, self.capacity - head_pos);
            
            // 使用SIMD优化的内存复制（如果可能）
            if (chunk_size >= 4 and @sizeOf(Message) % 16 == 0) {
                // 向量化复制
                const src_ptr = @as([*]const u8, @ptrCast(&self.buffer[head_pos]));
                const dst_ptr = @as([*]u8, @ptrCast(&buffer[copied]));
                const bytes_to_copy = chunk_size * @sizeOf(Message);
                
                @memcpy(dst_ptr[0..bytes_to_copy], src_ptr[0..bytes_to_copy]);
            } else {
                // 标准复制
                for (0..chunk_size) |i| {
                    buffer[copied + i] = self.buffer[head_pos + i];
                }
            }
            
            copied += @intCast(chunk_size);
            head_pos = (head_pos + chunk_size) & self.mask;
        }
        
        // 内存屏障确保读取完成
        std.atomic.fence(.release);
        
        // 更新head指针
        self.head.store(head_pos, .release);
        
        if (self.stats) |*stats| {
            var i: u32 = 0;
            while (i < copied) : (i += 1) {
                stats.incrementReceived();
            }
        }
        
        return copied;
    }
    
    // 内存池支持
    pub fn allocateMessage(self: *Self) ?*Message {
        if (self.message_pool) |pool| {
            return pool.allocate();
        }
        return null;
    }
    
    pub fn deallocateMessage(self: *Self, message: *Message) void {
        if (self.message_pool) |pool| {
            pool.deallocate(message);
        }
    }
    
    // 高级功能
    pub fn tryReceiveWithTimeout(self: *Self, timeout_ns: u64) ?Message {
        const start_time = std.time.nanoTimestamp();
        
        while (std.time.nanoTimestamp() - start_time < timeout_ns) {
            if (self.receiveMessage()) |message| {
                return message;
            }
            
            // 自适应等待策略
            if (timeout_ns > 1000000) { // > 1ms
                std.Thread.yield() catch {};
            } else {
                // 短暂自旋等待
                var spin_count: u32 = 0;
                while (spin_count < 100) : (spin_count += 1) {
                    std.atomic.spinLoopHint();
                }
            }
        }
        
        return null;
    }
    
    pub fn peek(self: *const Self) ?Message {
        const current_head = self.head.load(.acquire);
        const current_tail = self.tail.load(.acquire);
        
        if (current_head == current_tail) {
            return null;
        }
        
        return self.buffer[current_head];
    }
    
    pub fn clear(self: *Self) u32 {
        var cleared_count: u32 = 0;
        while (self.receiveMessage()) |message| {
            message.deinit(self.allocator);
            cleared_count += 1;
        }
        return cleared_count;
    }
    
    // 性能分析
    pub fn getLoadFactor(self: *const Self) f32 {
        const current_size = self.sizeImpl();
        return @as(f32, @floatFromInt(current_size)) / @as(f32, @floatFromInt(self.capacity));
    }
    
    pub fn isNearlyFull(self: *const Self, threshold: f32) bool {
        return self.getLoadFactor() >= threshold;
    }
};

// 测试
test "HighPerfMailbox basic operations" {
    const allocator = testing.allocator;
    const config = MailboxConfig{
        .capacity = 1024, // 会被调整为2的幂
        .enable_statistics = true,
        .enable_batching = true,
        .use_memory_pool = false,
    };
    
    var mailbox = try HighPerfMailbox.init(allocator, config);
    defer mailbox.deinitImpl();
    
    // 测试空邮箱
    try testing.expect(mailbox.isEmptyImpl());
    try testing.expect(mailbox.receiveMessage() == null);
    
    // 测试发送和接收
    const message = Message.createSystem(.stop, null);
    try mailbox.sendMessage(message);
    
    try testing.expect(!mailbox.isEmptyImpl());
    try testing.expect(mailbox.sizeImpl() == 1);
    
    const received = mailbox.receiveMessage();
    try testing.expect(received != null);
    try testing.expect(mailbox.isEmptyImpl());
}

test "HighPerfMailbox batch operations" {
    const allocator = testing.allocator;
    const config = MailboxConfig{
        .capacity = 1024,
        .enable_statistics = true,
        .enable_batching = true,
        .batch_size = 16,
    };
    
    var mailbox = try HighPerfMailbox.init(allocator, config);
    defer mailbox.deinitImpl();
    
    // 准备批量消息
    var messages: [10]Message = undefined;
    for (&messages) |*msg| {
        msg.* = Message.createSystem(.stop, null);
    }
    
    // 批量发送
    const sent_count = try mailbox.sendBatch(&messages);
    try testing.expect(sent_count == 10);
    
    // 批量接收
    var received_messages: [10]Message = undefined;
    const received_count = mailbox.receiveBatch(&received_messages);
    try testing.expect(received_count == 10);
    
    try testing.expect(mailbox.isEmptyImpl());
}