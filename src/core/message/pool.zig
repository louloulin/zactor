//! Message Pool Implementation - 消息池实现
//! 提供高性能的消息对象池管理

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;
const ArrayList = std.ArrayList;
const Thread = std.Thread;

// 导入相关模块
const Message = @import("message.zig").Message;
const MessageType = @import("message.zig").MessageType;
const MessagePriority = @import("message.zig").MessagePriority;
const LockFreeQueue = @import("../../utils/lockfree_queue.zig").LockFreeQueue;

// 消息池配置
pub const MessagePoolConfig = struct {
    initial_size: u32 = 100,
    max_size: u32 = 1000,
    growth_factor: f32 = 1.5,
    shrink_threshold: f32 = 0.25,
    enable_statistics: bool = true,
    enable_preallocation: bool = true,
    thread_local_pools: bool = true,
    
    pub fn default() MessagePoolConfig {
        return MessagePoolConfig{};
    }
    
    pub fn highPerformance() MessagePoolConfig {
        return MessagePoolConfig{
            .initial_size = 500,
            .max_size = 5000,
            .growth_factor = 2.0,
            .enable_preallocation = true,
            .thread_local_pools = true,
        };
    }
    
    pub fn lowMemory() MessagePoolConfig {
        return MessagePoolConfig{
            .initial_size = 50,
            .max_size = 200,
            .growth_factor = 1.2,
            .shrink_threshold = 0.5,
            .enable_preallocation = false,
            .thread_local_pools = false,
        };
    }
};

// 消息池统计信息
pub const MessagePoolStats = struct {
    total_allocated: Atomic(u64),
    total_deallocated: Atomic(u64),
    current_pool_size: Atomic(u32),
    current_used: Atomic(u32),
    peak_usage: Atomic(u32),
    cache_hits: Atomic(u64),
    cache_misses: Atomic(u64),
    pool_grows: Atomic(u32),
    pool_shrinks: Atomic(u32),
    
    pub fn init() MessagePoolStats {
        return MessagePoolStats{
            .total_allocated = Atomic(u64).init(0),
            .total_deallocated = Atomic(u64).init(0),
            .current_pool_size = Atomic(u32).init(0),
            .current_used = Atomic(u32).init(0),
            .peak_usage = Atomic(u32).init(0),
            .cache_hits = Atomic(u64).init(0),
            .cache_misses = Atomic(u64).init(0),
            .pool_grows = Atomic(u32).init(0),
            .pool_shrinks = Atomic(u32).init(0),
        };
    }
    
    pub fn getHitRate(self: *const MessagePoolStats) f64 {
        const hits = self.cache_hits.load(.Monotonic);
        const misses = self.cache_misses.load(.Monotonic);
        const total = hits + misses;
        
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
    }
    
    pub fn getCurrentUsage(self: *const MessagePoolStats) f32 {
        const pool_size = self.current_pool_size.load(.Monotonic);
        const used = self.current_used.load(.Monotonic);
        
        if (pool_size == 0) return 0.0;
        return @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(pool_size));
    }
};

// 池化消息包装器
pub const PooledMessage = struct {
    const Self = @This();
    
    message: *Message,
    pool: *MessagePool,
    ref_count: Atomic(u32),
    in_use: Atomic(bool),
    
    pub fn init(message: *Message, pool: *MessagePool) Self {
        return Self{
            .message = message,
            .pool = pool,
            .ref_count = Atomic(u32).init(1),
            .in_use = Atomic(bool).init(true),
        };
    }
    
    pub fn acquire(self: *Self) *Message {
        _ = self.ref_count.fetchAdd(1, .SeqCst);
        return self.message;
    }
    
    pub fn release(self: *Self) void {
        const old_count = self.ref_count.fetchSub(1, .SeqCst);
        if (old_count == 1) {
            // 最后一个引用，归还到池中
            self.in_use.store(false, .SeqCst);
            self.pool.returnMessage(self);
        }
    }
    
    pub fn getRefCount(self: *Self) u32 {
        return self.ref_count.load(.Monotonic);
    }
    
    pub fn isInUse(self: *Self) bool {
        return self.in_use.load(.Monotonic);
    }
};

// 消息池实现
pub const MessagePool = struct {
    const Self = @This();
    
    allocator: Allocator,
    config: MessagePoolConfig,
    stats: MessagePoolStats,
    
    // 池存储
    available_messages: LockFreeQueue(*PooledMessage),
    all_messages: ArrayList(*PooledMessage),
    
    // 同步原语
    mutex: Thread.Mutex,
    
    // 状态
    initialized: Atomic(bool),
    
    pub fn init(allocator: Allocator, config: MessagePoolConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.* = Self{
            .allocator = allocator,
            .config = config,
            .stats = MessagePoolStats.init(),
            .available_messages = try LockFreeQueue(*PooledMessage).init(allocator, config.max_size),
            .all_messages = ArrayList(*PooledMessage).init(allocator),
            .mutex = Thread.Mutex{},
            .initialized = Atomic(bool).init(false),
        };
        
        // 预分配消息
        if (config.enable_preallocation) {
            try self.preallocateMessages(config.initial_size);
        }
        
        self.initialized.store(true, .SeqCst);
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.initialized.store(false, .SeqCst);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 清理所有消息
        for (self.all_messages.items) |pooled_msg| {
            pooled_msg.message.deinit();
            self.allocator.destroy(pooled_msg);
        }
        self.all_messages.deinit();
        
        self.available_messages.deinit();
        self.allocator.destroy(self);
    }
    
    // 获取消息
    pub fn acquire(self: *Self) !*Message {
        if (!self.initialized.load(.SeqCst)) {
            return error.PoolNotInitialized;
        }
        
        // 尝试从池中获取
        if (self.available_messages.pop()) |pooled_msg| {
            pooled_msg.in_use.store(true, .SeqCst);
            pooled_msg.ref_count.store(1, .SeqCst);
            
            // 重置消息状态
            try pooled_msg.message.reset();
            
            self.stats.cache_hits.fetchAdd(1, .Monotonic);
            _ = self.stats.current_used.fetchAdd(1, .Monotonic);
            
            return pooled_msg.message;
        }
        
        // 池中没有可用消息，创建新的
        self.stats.cache_misses.fetchAdd(1, .Monotonic);
        return self.createNewMessage();
    }
    
    // 获取指定类型的消息
    pub fn acquireTyped(self: *Self, message_type: MessageType) !*Message {
        const message = try self.acquire();
        try message.setType(message_type);
        return message;
    }
    
    // 获取指定优先级的消息
    pub fn acquireWithPriority(self: *Self, priority: MessagePriority) !*Message {
        const message = try self.acquire();
        message.setPriority(priority);
        return message;
    }
    
    // 批量获取消息
    pub fn acquireBatch(self: *Self, count: u32, messages: []*Message) !u32 {
        var acquired: u32 = 0;
        
        for (0..count) |i| {
            if (self.acquire()) |msg| {
                messages[i] = msg;
                acquired += 1;
            } else |_| {
                break;
            }
        }
        
        return acquired;
    }
    
    // 归还消息（内部使用）
    fn returnMessage(self: *Self, pooled_msg: *PooledMessage) void {
        if (!self.initialized.load(.SeqCst)) {
            return;
        }
        
        // 检查池是否已满
        if (self.available_messages.size() >= self.config.max_size) {
            // 池已满，直接销毁消息
            self.destroyMessage(pooled_msg);
            return;
        }
        
        // 归还到池中
        if (self.available_messages.push(pooled_msg)) {
            _ = self.stats.current_used.fetchSub(1, .Monotonic);
        } else {
            // 推入失败，销毁消息
            self.destroyMessage(pooled_msg);
        }
    }
    
    // 获取统计信息
    pub fn getStats(self: *Self) MessagePoolStats {
        return self.stats;
    }
    
    // 获取配置
    pub fn getConfig(self: *Self) MessagePoolConfig {
        return self.config;
    }
    
    // 池管理
    pub fn grow(self: *Self, additional_size: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const current_size = self.stats.current_pool_size.load(.Monotonic);
        const new_size = @min(current_size + additional_size, self.config.max_size);
        const to_add = new_size - current_size;
        
        if (to_add > 0) {
            try self.preallocateMessages(to_add);
            _ = self.stats.pool_grows.fetchAdd(1, .Monotonic);
        }
    }
    
    pub fn shrink(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const current_usage = self.stats.getCurrentUsage();
        if (current_usage < self.config.shrink_threshold) {
            const target_size = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.stats.current_used.load(.Monotonic))) / self.config.shrink_threshold));
            self.shrinkToSize(target_size);
            _ = self.stats.pool_shrinks.fetchAdd(1, .Monotonic);
        }
    }
    
    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 清空可用消息队列
        while (self.available_messages.pop()) |pooled_msg| {
            self.destroyMessage(pooled_msg);
        }
    }
    
    // 私有方法
    fn preallocateMessages(self: *Self, count: u32) !void {
        for (0..count) |_| {
            const message = try Message.init(self.allocator, MessageType{ .user = .{ .data = null } });
            const pooled_msg = try self.allocator.create(PooledMessage);
            pooled_msg.* = PooledMessage.init(message, self);
            pooled_msg.in_use.store(false, .SeqCst);
            
            try self.all_messages.append(pooled_msg);
            
            if (!self.available_messages.push(pooled_msg)) {
                // 推入失败，销毁消息
                message.deinit();
                self.allocator.destroy(pooled_msg);
                _ = self.all_messages.pop();
                break;
            }
        }
        
        self.stats.current_pool_size.store(@intCast(self.all_messages.items.len), .SeqCst);
    }
    
    fn createNewMessage(self: *Self) !*Message {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 检查是否可以扩展池
        if (self.all_messages.items.len >= self.config.max_size) {
            return error.PoolExhausted;
        }
        
        // 创建新消息
        const message = try Message.init(self.allocator, MessageType{ .user = .{ .data = null } });
        const pooled_msg = try self.allocator.create(PooledMessage);
        pooled_msg.* = PooledMessage.init(message, self);
        
        try self.all_messages.append(pooled_msg);
        
        self.stats.current_pool_size.store(@intCast(self.all_messages.items.len), .SeqCst);
        _ = self.stats.current_used.fetchAdd(1, .Monotonic);
        
        // 更新峰值使用量
        const current_used = self.stats.current_used.load(.Monotonic);
        const peak = self.stats.peak_usage.load(.Monotonic);
        if (current_used > peak) {
            self.stats.peak_usage.store(current_used, .SeqCst);
        }
        
        return message;
    }
    
    fn destroyMessage(self: *Self, pooled_msg: *PooledMessage) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 从all_messages中移除
        for (self.all_messages.items, 0..) |msg, i| {
            if (msg == pooled_msg) {
                _ = self.all_messages.swapRemove(i);
                break;
            }
        }
        
        pooled_msg.message.deinit();
        self.allocator.destroy(pooled_msg);
        
        self.stats.current_pool_size.store(@intCast(self.all_messages.items.len), .SeqCst);
        _ = self.stats.total_deallocated.fetchAdd(1, .Monotonic);
    }
    
    fn shrinkToSize(self: *Self, target_size: u32) void {
        const current_size = self.all_messages.items.len;
        if (target_size >= current_size) return;
        
        const to_remove = current_size - target_size;
        var removed: u32 = 0;
        
        while (removed < to_remove and self.available_messages.pop() != null) {
            if (self.available_messages.pop()) |pooled_msg| {
                self.destroyMessage(pooled_msg);
                removed += 1;
            }
        }
    }
};

// 线程本地消息池
pub const ThreadLocalMessagePool = struct {
    const Self = @This();
    
    global_pool: *MessagePool,
    local_pool: *MessagePool,
    thread_id: Thread.Id,
    
    pub fn init(global_pool: *MessagePool, allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        // 创建本地池配置（较小的池）
        var local_config = global_pool.getConfig();
        local_config.initial_size = @min(local_config.initial_size / 4, 25);
        local_config.max_size = @min(local_config.max_size / 4, 100);
        
        self.* = Self{
            .global_pool = global_pool,
            .local_pool = try MessagePool.init(allocator, local_config),
            .thread_id = Thread.getCurrentId(),
        };
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.local_pool.deinit();
        self.global_pool.allocator.destroy(self);
    }
    
    pub fn acquire(self: *Self) !*Message {
        // 首先尝试本地池
        if (self.local_pool.acquire()) |msg| {
            return msg;
        } else |_| {
            // 本地池失败，尝试全局池
            return self.global_pool.acquire();
        }
    }
    
    pub fn getStats(self: *Self) struct { local: MessagePoolStats, global: MessagePoolStats } {
        return .{
            .local = self.local_pool.getStats(),
            .global = self.global_pool.getStats(),
        };
    }
};

// 全局消息池管理器
pub const MessagePoolManager = struct {
    const Self = @This();
    
    allocator: Allocator,
    global_pool: *MessagePool,
    thread_pools: std.HashMap(Thread.Id, *ThreadLocalMessagePool, ThreadIdContext, std.hash_map.default_max_load_percentage),
    mutex: Thread.Mutex,
    
    pub fn init(allocator: Allocator, config: MessagePoolConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.* = Self{
            .allocator = allocator,
            .global_pool = try MessagePool.init(allocator, config),
            .thread_pools = std.HashMap(Thread.Id, *ThreadLocalMessagePool, ThreadIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .mutex = Thread.Mutex{},
        };
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 清理线程本地池
        var iter = self.thread_pools.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.thread_pools.deinit();
        
        self.global_pool.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn acquire(self: *Self) !*Message {
        const thread_id = Thread.getCurrentId();
        
        // 获取或创建线程本地池
        const thread_pool = try self.getOrCreateThreadPool(thread_id);
        return thread_pool.acquire();
    }
    
    fn getOrCreateThreadPool(self: *Self, thread_id: Thread.Id) !*ThreadLocalMessagePool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.thread_pools.get(thread_id)) |pool| {
            return pool;
        }
        
        const new_pool = try ThreadLocalMessagePool.init(self.global_pool, self.allocator);
        try self.thread_pools.put(thread_id, new_pool);
        return new_pool;
    }
};

// 辅助类型
const ThreadIdContext = struct {
    pub fn hash(self: @This(), thread_id: Thread.Id) u64 {
        _ = self;
        return @intCast(thread_id);
    }
    
    pub fn eql(self: @This(), a: Thread.Id, b: Thread.Id) bool {
        _ = self;
        return a == b;
    }
};

// 便利函数
pub fn createPool(allocator: Allocator, config: MessagePoolConfig) !*MessagePool {
    return MessagePool.init(allocator, config);
}

pub fn createManager(allocator: Allocator, config: MessagePoolConfig) !*MessagePoolManager {
    return MessagePoolManager.init(allocator, config);
}

// 测试
test "MessagePool basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = MessagePoolConfig.default();
    const pool = try MessagePool.init(allocator, config);
    defer pool.deinit();
    
    // 获取消息
    const msg1 = try pool.acquire();
    const msg2 = try pool.acquire();
    
    try testing.expect(msg1 != msg2);
    
    // 检查统计信息
    const stats = pool.getStats();
    try testing.expect(stats.cache_hits.load(.Monotonic) >= 0);
    try testing.expect(stats.cache_misses.load(.Monotonic) >= 0);
}

test "MessagePoolStats" {
    const testing = std.testing;
    
    var stats = MessagePoolStats.init();
    
    _ = stats.cache_hits.fetchAdd(80, .Monotonic);
    _ = stats.cache_misses.fetchAdd(20, .Monotonic);
    
    const hit_rate = stats.getHitRate();
    try testing.expect(hit_rate == 0.8);
}

test "PooledMessage reference counting" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = MessagePoolConfig.default();
    const pool = try MessagePool.init(allocator, config);
    defer pool.deinit();
    
    const msg = try pool.acquire();
    
    // 消息应该被正确包装
    try testing.expect(msg != null);
}