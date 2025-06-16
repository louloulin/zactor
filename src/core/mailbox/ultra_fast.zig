//! Ultra Fast Mailbox Implementation - 超快邮箱实现
//! 基于零拷贝、预分配和硬件优化的极致性能邮箱

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Message = @import("../message/mod.zig").Message;
const MailboxConfig = @import("mod.zig").MailboxConfig;
const MailboxStats = @import("mod.zig").MailboxStats;
const MailboxInterface = @import("mod.zig").MailboxInterface;

// 超快邮箱实现 - 极致性能优化
pub const UltraFastMailbox = struct {
    const Self = @This();
    
    // 多个环形缓冲区用于减少竞争
    const NUM_RINGS = 4;
    
    // 单个环形缓冲区
    const Ring = struct {
        buffer: []Message,
        head: std.atomic.Atomic(u32) align(64), // 缓存行对齐
        tail: std.atomic.Atomic(u32) align(64),
        capacity: u32,
        mask: u32,
        _padding: [64 - @sizeOf(u32) * 2]u8 = [_]u8{0} ** (64 - @sizeOf(u32) * 2),
    };
    
    rings: [NUM_RINGS]Ring,
    ring_selector: std.atomic.Atomic(u32) align(64),
    
    // 预分配的消息池
    message_pool: []Message,
    pool_head: std.atomic.Atomic(u32) align(64),
    pool_capacity: u32,
    
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
        // 确保容量是2的幂
        const ring_capacity = std.math.ceilPowerOfTwo(u32, config.capacity / NUM_RINGS) catch (config.capacity / NUM_RINGS);
        const pool_capacity = config.pool_size orelse (ring_capacity * NUM_RINGS * 2);
        
        var rings: [NUM_RINGS]Ring = undefined;
        
        // 初始化每个环形缓冲区
        for (&rings) |*ring| {
            const buffer = try allocator.alloc(Message, ring_capacity);
            ring.* = Ring{
                .buffer = buffer,
                .head = std.atomic.Atomic(u32).init(0),
                .tail = std.atomic.Atomic(u32).init(0),
                .capacity = ring_capacity,
                .mask = ring_capacity - 1,
            };
        }
        
        // 预分配消息池
        const message_pool = try allocator.alloc(Message, pool_capacity);
        
        return Self{
            .rings = rings,
            .ring_selector = std.atomic.Atomic(u32).init(0),
            .message_pool = message_pool,
            .pool_head = std.atomic.Atomic(u32).init(0),
            .pool_capacity = pool_capacity,
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
        return self.rings[0].capacity * NUM_RINGS;
    }
    
    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinitImpl();
    }
    
    fn getStats(ptr: *anyopaque) ?*MailboxStats {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return if (self.stats) |*stats| stats else null;
    }
    
    // 选择最优环形缓冲区
    inline fn selectRing(self: *Self) *Ring {
        // 使用线程ID和时间戳的组合来减少竞争
        const thread_id = std.Thread.getCurrentId();
        const timestamp = @as(u32, @truncate(@as(u64, @bitCast(std.time.nanoTimestamp()))));
        const ring_index = (thread_id +% timestamp) % NUM_RINGS;
        return &self.rings[ring_index];
    }
    
    // 快速发送实现
    pub fn sendMessage(self: *Self, message: Message) !void {
        // 尝试多个环形缓冲区
        var attempts: u32 = 0;
        while (attempts < NUM_RINGS) : (attempts += 1) {
            const ring = self.selectRing();
            
            const current_tail = ring.tail.load(.acquire);
            const next_tail = (current_tail + 1) & ring.mask;
            const current_head = ring.head.load(.acquire);
            
            // 检查是否有空间
            if (next_tail != current_head) {
                // 零拷贝写入
                ring.buffer[current_tail] = message;
                
                // 使用最强的内存屏障确保顺序
                std.atomic.fence(.SeqCst);
                
                // 原子更新tail
                if (ring.tail.compareAndSwap(current_tail, next_tail, .SeqCst, .SeqCst) == null) {
                    if (self.stats) |*stats| {
                        stats.incrementSent();
                        const current_size = self.sizeImpl();
                        stats.updatePeakQueueSize(current_size);
                    }
                    return;
                }
            }
            
            // 短暂自旋后重试
            var spin_count: u32 = 0;
            while (spin_count < 16) : (spin_count += 1) {
                std.atomic.spinLoopHint();
            }
        }
        
        if (self.stats) |*stats| {
            stats.incrementDropped();
        }
        return error.MailboxFull;
    }
    
    // 快速接收实现
    pub fn receiveMessage(self: *Self) ?Message {
        // 轮询所有环形缓冲区
        for (&self.rings) |*ring| {
            const current_head = ring.head.load(.acquire);
            const current_tail = ring.tail.load(.acquire);
            
            // 检查是否有消息
            if (current_head != current_tail) {
                // 零拷贝读取
                const message = ring.buffer[current_head];
                
                // 使用内存屏障确保读取完成
                std.atomic.fence(.SeqCst);
                
                // 原子更新head
                const next_head = (current_head + 1) & ring.mask;
                if (ring.head.compareAndSwap(current_head, next_head, .SeqCst, .SeqCst) == null) {
                    if (self.stats) |*stats| {
                        stats.incrementReceived();
                    }
                    return message;
                }
            }
        }
        
        return null;
    }
    
    pub fn isEmptyImpl(self: *const Self) bool {
        for (&self.rings) |*ring| {
            const current_head = ring.head.load(.acquire);
            const current_tail = ring.tail.load(.acquire);
            if (current_head != current_tail) {
                return false;
            }
        }
        return true;
    }
    
    pub fn sizeImpl(self: *const Self) u32 {
        var total_size: u32 = 0;
        for (&self.rings) |*ring| {
            const current_head = ring.head.load(.acquire);
            const current_tail = ring.tail.load(.acquire);
            total_size += (current_tail - current_head) & ring.mask;
        }
        return total_size;
    }
    
    pub fn deinitImpl(self: *Self) void {
        // 清理所有环形缓冲区中的剩余消息
        for (&self.rings) |*ring| {
            while (true) {
                const current_head = ring.head.load(.acquire);
                const current_tail = ring.tail.load(.acquire);
                
                if (current_head == current_tail) break;
                
                const message = ring.buffer[current_head];
                message.deinit(self.allocator);
                
                const next_head = (current_head + 1) & ring.mask;
                ring.head.store(next_head, .release);
            }
            
            // 释放环形缓冲区
            self.allocator.free(ring.buffer);
        }
        
        // 释放消息池
        self.allocator.free(self.message_pool);
    }
    
    // 超高性能批量操作
    pub fn sendBatch(self: *Self, messages: []const Message) !u32 {
        if (!self.config.enable_batching) {
            var sent_count: u32 = 0;
            for (messages) |message| {
                self.sendMessage(message) catch break;
                sent_count += 1;
            }
            return sent_count;
        }
        
        var total_sent: u32 = 0;
        var remaining = messages;
        
        // 分批发送到不同的环形缓冲区
        while (remaining.len > 0 and total_sent < messages.len) {
            for (&self.rings) |*ring| {
                if (remaining.len == 0) break;
                
                const current_tail = ring.tail.load(.acquire);
                const current_head = ring.head.load(.acquire);
                
                // 计算可用空间
                const available_space = if (current_head > current_tail) {
                    current_head - current_tail - 1;
                } else {
                    ring.capacity - (current_tail - current_head) - 1;
                };
                
                if (available_space == 0) continue;
                
                const batch_size = @min(remaining.len, available_space);
                const chunk_size = @min(batch_size, ring.capacity - current_tail);
                
                // 使用SIMD优化的批量复制
                if (chunk_size >= 8 and @sizeOf(Message) % 32 == 0) {
                    // AVX2优化复制
                    const src_ptr = @as([*]const u8, @ptrCast(remaining.ptr));
                    const dst_ptr = @as([*]u8, @ptrCast(&ring.buffer[current_tail]));
                    const bytes_to_copy = chunk_size * @sizeOf(Message);
                    
                    @memcpy(dst_ptr[0..bytes_to_copy], src_ptr[0..bytes_to_copy]);
                } else {
                    // 标准复制
                    for (0..chunk_size) |i| {
                        ring.buffer[current_tail + i] = remaining[i];
                    }
                }
                
                // 处理环形缓冲区边界
                if (batch_size > chunk_size) {
                    const wrap_size = batch_size - chunk_size;
                    for (0..wrap_size) |i| {
                        ring.buffer[i] = remaining[chunk_size + i];
                    }
                }
                
                // 内存屏障
                std.atomic.fence(.SeqCst);
                
                // 更新tail指针
                const new_tail = (current_tail + batch_size) & ring.mask;
                ring.tail.store(new_tail, .release);
                
                total_sent += @intCast(batch_size);
                remaining = remaining[batch_size..];
            }
            
            // 如果没有进展，退出循环
            if (total_sent == 0) break;
        }
        
        if (self.stats) |*stats| {
            var i: u32 = 0;
            while (i < total_sent) : (i += 1) {
                stats.incrementSent();
            }
            const current_size = self.sizeImpl();
            stats.updatePeakQueueSize(current_size);
        }
        
        return total_sent;
    }
    
    pub fn receiveBatch(self: *Self, buffer: []Message) u32 {
        if (!self.config.enable_batching) {
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
        
        var total_received: u32 = 0;
        var remaining = buffer;
        
        // 从所有环形缓冲区批量接收
        while (remaining.len > 0 and total_received < buffer.len) {
            var progress_made = false;
            
            for (&self.rings) |*ring| {
                if (remaining.len == 0) break;
                
                const current_head = ring.head.load(.acquire);
                const current_tail = ring.tail.load(.acquire);
                
                // 计算可用消息数量
                const available_messages = (current_tail - current_head) & ring.mask;
                if (available_messages == 0) continue;
                
                const batch_size = @min(remaining.len, available_messages);
                const chunk_size = @min(batch_size, ring.capacity - current_head);
                
                // 使用SIMD优化的批量复制
                if (chunk_size >= 8 and @sizeOf(Message) % 32 == 0) {
                    // AVX2优化复制
                    const src_ptr = @as([*]const u8, @ptrCast(&ring.buffer[current_head]));
                    const dst_ptr = @as([*]u8, @ptrCast(remaining.ptr));
                    const bytes_to_copy = chunk_size * @sizeOf(Message);
                    
                    @memcpy(dst_ptr[0..bytes_to_copy], src_ptr[0..bytes_to_copy]);
                } else {
                    // 标准复制
                    for (0..chunk_size) |i| {
                        remaining[i] = ring.buffer[current_head + i];
                    }
                }
                
                // 处理环形缓冲区边界
                if (batch_size > chunk_size) {
                    const wrap_size = batch_size - chunk_size;
                    for (0..wrap_size) |i| {
                        remaining[chunk_size + i] = ring.buffer[i];
                    }
                }
                
                // 内存屏障
                std.atomic.fence(.SeqCst);
                
                // 更新head指针
                const new_head = (current_head + batch_size) & ring.mask;
                ring.head.store(new_head, .release);
                
                total_received += @intCast(batch_size);
                remaining = remaining[batch_size..];
                progress_made = true;
            }
            
            // 如果没有进展，退出循环
            if (!progress_made) break;
        }
        
        if (self.stats) |*stats| {
            var i: u32 = 0;
            while (i < total_received) : (i += 1) {
                stats.incrementReceived();
            }
        }
        
        return total_received;
    }
    
    // 预分配消息池支持
    pub fn allocateMessage(self: *Self) ?*Message {
        const current_head = self.pool_head.load(.acquire);
        if (current_head >= self.pool_capacity) {
            return null;
        }
        
        const next_head = current_head + 1;
        if (self.pool_head.compareAndSwap(current_head, next_head, .SeqCst, .SeqCst) == null) {
            return &self.message_pool[current_head];
        }
        
        return null;
    }
    
    pub fn deallocateMessage(self: *Self, message: *Message) void {
        // 简单的回收策略 - 在实际应用中可能需要更复杂的实现
        _ = message;
        _ = self;
    }
    
    // 高级性能功能
    pub fn prefetchNextMessage(self: *const Self) void {
        for (&self.rings) |*ring| {
            const current_head = ring.head.load(.acquire);
            const current_tail = ring.tail.load(.acquire);
            
            if (current_head != current_tail) {
                // 预取下一个消息到缓存
                const next_head = (current_head + 1) & ring.mask;
                if (next_head != current_tail) {
                    std.mem.prefetchRead(&ring.buffer[next_head], 0);
                }
                break;
            }
        }
    }
    
    pub fn warmupCache(self: *Self) void {
        // 预热缓存 - 访问所有环形缓冲区
        for (&self.rings) |*ring| {
            for (ring.buffer) |*slot| {
                std.mem.doNotOptimizeAway(slot);
            }
        }
    }
    
    pub fn getOptimalBatchSize(self: *const Self) u32 {
        // 基于当前负载动态调整批量大小
        const current_size = self.sizeImpl();
        const total_capacity = self.rings[0].capacity * NUM_RINGS;
        const load_factor = @as(f32, @floatFromInt(current_size)) / @as(f32, @floatFromInt(total_capacity));
        
        if (load_factor > 0.8) {
            return self.config.batch_size orelse 32; // 高负载时使用大批量
        } else if (load_factor > 0.5) {
            return (self.config.batch_size orelse 16); // 中等负载
        } else {
            return (self.config.batch_size orelse 8); // 低负载时使用小批量
        }
    }
};

// 测试
test "UltraFastMailbox basic operations" {
    const allocator = testing.allocator;
    const config = MailboxConfig{
        .capacity = 1024,
        .enable_statistics = true,
        .enable_batching = true,
        .pool_size = 2048,
    };
    
    var mailbox = try UltraFastMailbox.init(allocator, config);
    defer mailbox.deinitImpl();
    
    // 测试空邮箱
    try testing.expect(mailbox.isEmptyImpl());
    try testing.expect(mailbox.receiveMessage() == null);
    
    // 测试发送和接收
    const message = Message.createSystem(.stop, null);
    try mailbox.sendMessage(message);
    
    try testing.expect(!mailbox.isEmptyImpl());
    
    const received = mailbox.receiveMessage();
    try testing.expect(received != null);
}

test "UltraFastMailbox high throughput" {
    const allocator = testing.allocator;
    const config = MailboxConfig{
        .capacity = 4096,
        .enable_statistics = true,
        .enable_batching = true,
        .batch_size = 64,
        .pool_size = 8192,
    };
    
    var mailbox = try UltraFastMailbox.init(allocator, config);
    defer mailbox.deinitImpl();
    
    // 高吞吐量测试
    const num_messages = 1000;
    var messages: [num_messages]Message = undefined;
    for (&messages) |*msg| {
        msg.* = Message.createSystem(.stop, null);
    }
    
    // 批量发送
    const sent_count = try mailbox.sendBatch(&messages);
    try testing.expect(sent_count > 0);
    
    // 批量接收
    var received_messages: [num_messages]Message = undefined;
    const received_count = mailbox.receiveBatch(&received_messages);
    try testing.expect(received_count == sent_count);
}