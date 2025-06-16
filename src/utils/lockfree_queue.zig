//! Lock-Free Queue Implementation - 无锁队列实现
//! 高性能SPSC (Single Producer Single Consumer) 队列
//! 针对最大吞吐量和最小竞争进行优化

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// 高性能无锁SPSC队列
pub fn LockFreeQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const CACHE_LINE_SIZE = 64;
        const DEFAULT_CAPACITY = 65536; // 必须是2的幂，用于快速模运算
        
        // 分离缓存行以避免伪共享
        buffer: []T,
        capacity: u32,
        mask: u32, // capacity - 1，用于快速模运算
        
        // 生产者缓存行
        head: std.atomic.Atomic(u32) align(CACHE_LINE_SIZE),
        head_cache: u32,
        _padding1: [CACHE_LINE_SIZE - @sizeOf(u32)]u8 = [_]u8{0} ** (CACHE_LINE_SIZE - @sizeOf(u32)),
        
        // 消费者缓存行
        tail: std.atomic.Atomic(u32) align(CACHE_LINE_SIZE),
        tail_cache: u32,
        _padding2: [CACHE_LINE_SIZE - @sizeOf(u32)]u8 = [_]u8{0} ** (CACHE_LINE_SIZE - @sizeOf(u32)),
        
        allocator: ?Allocator,
        
        pub fn init() Self {
            return Self{
                .buffer = undefined,
                .capacity = 0,
                .mask = 0,
                .head = std.atomic.Atomic(u32).init(0),
                .head_cache = 0,
                .tail = std.atomic.Atomic(u32).init(0),
                .tail_cache = 0,
                .allocator = null,
            };
        }
        
        pub fn initWithCapacity(allocator: Allocator, capacity: u32) !Self {
            // 确保容量是2的幂
            const actual_capacity = std.math.ceilPowerOfTwo(u32, capacity) catch capacity;
            const buffer = try allocator.alloc(T, actual_capacity);
            
            return Self{
                .buffer = buffer,
                .capacity = actual_capacity,
                .mask = actual_capacity - 1,
                .head = std.atomic.Atomic(u32).init(0),
                .head_cache = 0,
                .tail = std.atomic.Atomic(u32).init(0),
                .tail_cache = 0,
                .allocator = allocator,
            };
        }
        
        pub fn initFixed(buffer: []T) Self {
            const capacity = @as(u32, @intCast(buffer.len));
            // 验证容量是2的幂
            std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0);
            
            return Self{
                .buffer = buffer,
                .capacity = capacity,
                .mask = capacity - 1,
                .head = std.atomic.Atomic(u32).init(0),
                .head_cache = 0,
                .tail = std.atomic.Atomic(u32).init(0),
                .tail_cache = 0,
                .allocator = null,
            };
        }
        
        pub fn deinit(self: *Self) void {
            if (self.allocator) |allocator| {
                allocator.free(self.buffer);
            }
        }
        
        // 生产者端 - 针对最少原子操作优化
        pub fn push(self: *Self, item: T) bool {
            const head = self.head.load(.Monotonic);
            const next_head = (head + 1) & self.mask;
            
            // 使用缓存的tail检查队列是否已满
            if (next_head == self.tail_cache) {
                // 更新缓存并再次检查
                self.tail_cache = self.tail.load(.Acquire);
                if (next_head == self.tail_cache) {
                    return false; // 队列已满
                }
            }
            
            // 存储项目并更新head
            self.buffer[head] = item;
            self.head.store(next_head, .Release);
            return true;
        }
        
        // 消费者端 - 针对最少原子操作优化
        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.Monotonic);
            const safe_tail = tail & self.mask;
            
            // 使用缓存的head检查队列是否为空
            if (safe_tail == (self.head_cache & self.mask)) {
                // 更新缓存并再次检查
                self.head_cache = self.head.load(.Acquire);
                if (safe_tail == (self.head_cache & self.mask)) {
                    return null; // 队列为空
                }
            }
            
            // 加载项目并更新tail
            const item = self.buffer[safe_tail];
            const next_tail = (safe_tail + 1) & self.mask;
            self.tail.store(next_tail, .Release);
            return item;
        }
        
        // 批量操作以获得更高吞吐量
        pub fn pushBatch(self: *Self, items: []const T) u32 {
            var pushed: u32 = 0;
            
            // 优化：预先检查可用空间
            const head = self.head.load(.Monotonic);
            const tail = self.tail.load(.Acquire);
            const available_space = if (tail > head) {
                tail - head - 1
            } else {
                self.capacity - (head - tail) - 1
            };
            
            const batch_size = @min(items.len, available_space);
            
            // 批量推送
            for (items[0..batch_size]) |item| {
                if (self.push(item)) {
                    pushed += 1;
                } else {
                    break;
                }
            }
            
            return pushed;
        }
        
        pub fn popBatch(self: *Self, buffer: []T) u32 {
            var popped: u32 = 0;
            
            // 优化：预先检查可用项目数量
            const head = self.head.load(.Acquire);
            const tail = self.tail.load(.Monotonic);
            const available_items = (head - tail) & self.mask;
            
            const batch_size = @min(buffer.len, available_items);
            
            // 批量弹出
            for (buffer[0..batch_size]) |*slot| {
                if (self.pop()) |item| {
                    slot.* = item;
                    popped += 1;
                } else {
                    break;
                }
            }
            
            return popped;
        }
        
        // 状态查询
        pub fn isEmpty(self: *Self) bool {
            const tail = self.tail.load(.Monotonic);
            const head = self.head.load(.Acquire);
            return tail == head;
        }
        
        pub fn isFull(self: *Self) bool {
            const head = self.head.load(.Monotonic);
            const tail = self.tail.load(.Acquire);
            const next_head = (head + 1) & self.mask;
            return next_head == tail;
        }
        
        pub fn size(self: *Self) u32 {
            const head = self.head.load(.Acquire);
            const tail = self.tail.load(.Monotonic);
            return (head - tail) & self.mask;
        }
        
        pub fn remainingCapacity(self: *Self) u32 {
            return self.capacity - self.size() - 1; // -1 因为需要保留一个空位来区分满和空
        }
        
        // 高级操作
        pub fn peek(self: *Self) ?T {
            const tail = self.tail.load(.Monotonic);
            const head = self.head.load(.Acquire);
            
            if (tail == head) {
                return null; // 队列为空
            }
            
            const safe_tail = tail & self.mask;
            return self.buffer[safe_tail];
        }
        
        pub fn clear(self: *Self) u32 {
            var cleared: u32 = 0;
            while (self.pop() != null) {
                cleared += 1;
            }
            return cleared;
        }
        
        // 尝试推送，带超时
        pub fn tryPushWithTimeout(self: *Self, item: T, timeout_ns: u64) bool {
            const start_time = std.time.nanoTimestamp();
            
            while (std.time.nanoTimestamp() - start_time < timeout_ns) {
                if (self.push(item)) {
                    return true;
                }
                
                // 短暂让出CPU
                std.Thread.yield() catch {};
            }
            
            return false;
        }
        
        // 尝试弹出，带超时
        pub fn tryPopWithTimeout(self: *Self, timeout_ns: u64) ?T {
            const start_time = std.time.nanoTimestamp();
            
            while (std.time.nanoTimestamp() - start_time < timeout_ns) {
                if (self.pop()) |item| {
                    return item;
                }
                
                // 短暂让出CPU
                std.Thread.yield() catch {};
            }
            
            return null;
        }
        
        // 性能统计
        pub fn getLoadFactor(self: *Self) f32 {
            const current_size = self.size();
            return @as(f32, @floatFromInt(current_size)) / @as(f32, @floatFromInt(self.capacity));
        }
        
        // 调试信息
        pub fn debugInfo(self: *Self) struct { head: u32, tail: u32, size: u32, capacity: u32 } {
            return .{
                .head = self.head.load(.Acquire),
                .tail = self.tail.load(.Monotonic),
                .size = self.size(),
                .capacity = self.capacity,
            };
        }
    };
}

// 多生产者多消费者队列（MPMC）
pub fn MPMCQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const CACHE_LINE_SIZE = 64;
        
        buffer: []T,
        capacity: u32,
        mask: u32,
        
        // 使用更强的同步原语
        head: std.atomic.Atomic(u32) align(CACHE_LINE_SIZE),
        tail: std.atomic.Atomic(u32) align(CACHE_LINE_SIZE),
        
        allocator: ?Allocator,
        
        pub fn init(allocator: Allocator, capacity: u32) !Self {
            const actual_capacity = std.math.ceilPowerOfTwo(u32, capacity) catch capacity;
            const buffer = try allocator.alloc(T, actual_capacity);
            
            return Self{
                .buffer = buffer,
                .capacity = actual_capacity,
                .mask = actual_capacity - 1,
                .head = std.atomic.Atomic(u32).init(0),
                .tail = std.atomic.Atomic(u32).init(0),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *Self) void {
            if (self.allocator) |allocator| {
                allocator.free(self.buffer);
            }
        }
        
        pub fn push(self: *Self, item: T) bool {
            while (true) {
                const head = self.head.load(.Acquire);
                const next_head = (head + 1) & self.mask;
                const tail = self.tail.load(.Acquire);
                
                if (next_head == tail) {
                    return false; // 队列已满
                }
                
                // 尝试原子性地更新head
                if (self.head.compareAndSwap(head, next_head, .SeqCst, .SeqCst) == null) {
                    self.buffer[head] = item;
                    return true;
                }
                
                // 短暂自旋
                std.atomic.spinLoopHint();
            }
        }
        
        pub fn pop(self: *Self) ?T {
            while (true) {
                const tail = self.tail.load(.Acquire);
                const head = self.head.load(.Acquire);
                
                if (tail == head) {
                    return null; // 队列为空
                }
                
                const next_tail = (tail + 1) & self.mask;
                
                // 尝试原子性地更新tail
                if (self.tail.compareAndSwap(tail, next_tail, .SeqCst, .SeqCst) == null) {
                    return self.buffer[tail];
                }
                
                // 短暂自旋
                std.atomic.spinLoopHint();
            }
        }
        
        pub fn isEmpty(self: *Self) bool {
            const tail = self.tail.load(.Acquire);
            const head = self.head.load(.Acquire);
            return tail == head;
        }
        
        pub fn size(self: *Self) u32 {
            const head = self.head.load(.Acquire);
            const tail = self.tail.load(.Acquire);
            return (head - tail) & self.mask;
        }
    };
}

// 测试
test "LockFreeQueue basic operations" {
    const allocator = testing.allocator;
    
    var queue = try LockFreeQueue(u32).initWithCapacity(allocator, 16);
    defer queue.deinit();
    
    // 测试空队列
    try testing.expect(queue.isEmpty());
    try testing.expect(queue.pop() == null);
    try testing.expect(queue.size() == 0);
    
    // 测试推送和弹出
    try testing.expect(queue.push(42));
    try testing.expect(!queue.isEmpty());
    try testing.expect(queue.size() == 1);
    
    const item = queue.pop();
    try testing.expect(item != null);
    try testing.expect(item.? == 42);
    try testing.expect(queue.isEmpty());
}

test "LockFreeQueue batch operations" {
    const allocator = testing.allocator;
    
    var queue = try LockFreeQueue(u32).initWithCapacity(allocator, 32);
    defer queue.deinit();
    
    // 批量推送
    const items = [_]u32{ 1, 2, 3, 4, 5 };
    const pushed = queue.pushBatch(&items);
    try testing.expect(pushed == 5);
    try testing.expect(queue.size() == 5);
    
    // 批量弹出
    var buffer: [5]u32 = undefined;
    const popped = queue.popBatch(&buffer);
    try testing.expect(popped == 5);
    try testing.expect(queue.isEmpty());
    
    // 验证数据
    for (items, buffer) |expected, actual| {
        try testing.expect(expected == actual);
    }
}

test "MPMCQueue basic operations" {
    const allocator = testing.allocator;
    
    var queue = try MPMCQueue(u32).init(allocator, 16);
    defer queue.deinit();
    
    // 测试基本操作
    try testing.expect(queue.isEmpty());
    try testing.expect(queue.push(100));
    try testing.expect(!queue.isEmpty());
    
    const item = queue.pop();
    try testing.expect(item != null);
    try testing.expect(item.? == 100);
    try testing.expect(queue.isEmpty());
}