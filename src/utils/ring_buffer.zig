//! Ring Buffer Implementation - 环形缓冲区实现
//! 提供高性能的环形缓冲区，支持单生产者单消费者(SPSC)和多生产者多消费者(MPMC)模式

const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic = std.atomic;
const testing = std.testing;

// 缓存行大小，用于避免伪共享
const CACHE_LINE_SIZE = 64;

// 环形缓冲区错误
pub const RingBufferError = error{
    BufferFull,
    BufferEmpty,
    InvalidCapacity,
    OutOfMemory,
    InvalidIndex,
};

// 环形缓冲区配置
pub const RingBufferConfig = struct {
    capacity: usize,
    allow_overwrite: bool = false,
    thread_safe: bool = true,
    cache_aligned: bool = true,
    
    pub fn default(capacity: usize) RingBufferConfig {
        return RingBufferConfig{
            .capacity = capacity,
        };
    }
    
    pub fn singleThreaded(capacity: usize) RingBufferConfig {
        return RingBufferConfig{
            .capacity = capacity,
            .thread_safe = false,
            .cache_aligned = false,
        };
    }
    
    pub fn overwriteMode(capacity: usize) RingBufferConfig {
        return RingBufferConfig{
            .capacity = capacity,
            .allow_overwrite = true,
        };
    }
};

// 环形缓冲区统计信息
pub const RingBufferStats = struct {
    total_writes: u64 = 0,
    total_reads: u64 = 0,
    total_overwrites: u64 = 0,
    total_underruns: u64 = 0,
    peak_usage: usize = 0,
    current_size: usize = 0,
    
    pub fn getUtilization(self: *const RingBufferStats, capacity: usize) f64 {
        if (capacity == 0) return 0.0;
        return @as(f64, @floatFromInt(self.current_size)) / @as(f64, @floatFromInt(capacity));
    }
    
    pub fn getPeakUtilization(self: *const RingBufferStats, capacity: usize) f64 {
        if (capacity == 0) return 0.0;
        return @as(f64, @floatFromInt(self.peak_usage)) / @as(f64, @floatFromInt(capacity));
    }
    
    pub fn getOverwriteRate(self: *const RingBufferStats) f64 {
        if (self.total_writes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_overwrites)) / @as(f64, @floatFromInt(self.total_writes));
    }
};

// 单生产者单消费者环形缓冲区
pub fn SPSCRingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        
        // 缓存行对齐的原子变量
        head: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
    tail: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
        
        buffer: []T,
        capacity: usize,
        mask: usize,
        config: RingBufferConfig,
        stats: RingBufferStats,
        allocator: Allocator,
        
        pub fn init(allocator: Allocator, config: RingBufferConfig) !*Self {
            // 确保容量是2的幂
            const capacity = std.math.ceilPowerOfTwo(usize, config.capacity) catch return RingBufferError.InvalidCapacity;
            
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            
            const buffer = try allocator.alloc(T, capacity);
            errdefer allocator.free(buffer);
            
            self.* = Self{
                .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
                .buffer = buffer,
                .capacity = capacity,
                .mask = capacity - 1,
                .config = config,
                .stats = RingBufferStats{},
                .allocator = allocator,
            };
            
            return self;
        }
        
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.allocator.destroy(self);
        }
        
        // 写入单个元素
        pub fn write(self: *Self, item: T) RingBufferError!void {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            
            // 检查是否已满
            if (head - tail >= self.capacity) {
                if (self.config.allow_overwrite) {
                    // 覆盖模式：移动tail
                    _ = self.tail.fetchAdd(1, .release);
                    self.stats.total_overwrites += 1;
                } else {
                    return RingBufferError.BufferFull;
                }
            }
            
            // 写入数据
            self.buffer[head & self.mask] = item;
            
            // 更新head
            _ = self.head.fetchAdd(1, .release);
            
            // 更新统计信息
            self.stats.total_writes += 1;
            self.updateStats();
        }
        
        // 读取单个元素
        pub fn read(self: *Self) RingBufferError!T {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            
            // 检查是否为空
            if (head == tail) {
                self.stats.total_underruns += 1;
                return RingBufferError.BufferEmpty;
            }
            
            // 读取数据
            const item = self.buffer[tail & self.mask];
            
            // 更新tail
            _ = self.tail.fetchAdd(1, .release);
            
            // 更新统计信息
            self.stats.total_reads += 1;
            self.updateStats();
            
            return item;
        }
        
        // 批量写入
        pub fn writeBatch(self: *Self, items: []const T) RingBufferError!usize {
            var written: usize = 0;
            
            for (items) |item| {
                self.write(item) catch |err| {
                    if (err == RingBufferError.BufferFull and written > 0) {
                        break;
                    }
                    return err;
                };
                written += 1;
            }
            
            return written;
        }
        
        // 批量读取
        pub fn readBatch(self: *Self, buffer: []T) RingBufferError!usize {
            var read_count: usize = 0;
            
            for (buffer) |*slot| {
                slot.* = self.read() catch |err| {
                    if (err == RingBufferError.BufferEmpty and read_count > 0) {
                        break;
                    }
                    return err;
                };
                read_count += 1;
            }
            
            return read_count;
        }
        
        // 查看下一个元素（不移除）
        pub fn peek(self: *Self) RingBufferError!T {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            
            if (head == tail) {
                return RingBufferError.BufferEmpty;
            }
            
            return self.buffer[tail & self.mask];
        }
        
        // 获取当前大小
        pub fn size(self: *Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return head - tail;
        }
        
        // 检查是否为空
        pub fn isEmpty(self: *Self) bool {
            return self.size() == 0;
        }
        
        // 检查是否已满
        pub fn isFull(self: *Self) bool {
            return self.size() >= self.capacity;
        }
        
        // 获取剩余容量
        pub fn remaining(self: *Self) usize {
            return self.capacity - self.size();
        }
        
        // 清空缓冲区
        pub fn clear(self: *Self) void {
            self.head.store(0, .release);
            self.tail.store(0, .release);
        }
        
        // 获取统计信息
        pub fn getStats(self: *Self) RingBufferStats {
            self.updateStats();
            return self.stats;
        }
        
        // 重置统计信息
        pub fn resetStats(self: *Self) void {
            self.stats = RingBufferStats{};
        }
        
        // 更新统计信息
        fn updateStats(self: *Self) void {
            const current_size = self.size();
            self.stats.current_size = current_size;
            if (current_size > self.stats.peak_usage) {
                self.stats.peak_usage = current_size;
            }
        }
    };
}

// 多生产者多消费者环形缓冲区
pub fn MPMCRingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        
        // 使用更强的同步原语
        head: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
    tail: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
    write_cursor: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
    read_cursor: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
        
        buffer: []T,
        capacity: usize,
        mask: usize,
        config: RingBufferConfig,
        stats: RingBufferStats,
        allocator: Allocator,
        mutex: std.Thread.Mutex,
        
        pub fn init(allocator: Allocator, config: RingBufferConfig) !*Self {
            const capacity = std.math.ceilPowerOfTwo(usize, config.capacity) catch return RingBufferError.InvalidCapacity;
            
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            
            const buffer = try allocator.alloc(T, capacity);
            errdefer allocator.free(buffer);
            
            self.* = Self{
                .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .write_cursor = std.atomic.Value(usize).init(0),
            .read_cursor = std.atomic.Value(usize).init(0),
                .buffer = buffer,
                .capacity = capacity,
                .mask = capacity - 1,
                .config = config,
                .stats = RingBufferStats{},
                .allocator = allocator,
                .mutex = std.Thread.Mutex{},
            };
            
            return self;
        }
        
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.allocator.destroy(self);
        }
        
        // 写入单个元素（线程安全）
        pub fn write(self: *Self, item: T) RingBufferError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            
            if (head - tail >= self.capacity) {
                if (self.config.allow_overwrite) {
                    _ = self.tail.fetchAdd(1, .release);
                    self.stats.total_overwrites += 1;
                } else {
                    return RingBufferError.BufferFull;
                }
            }
            
            self.buffer[head & self.mask] = item;
            _ = self.head.fetchAdd(1, .release);
            
            self.stats.total_writes += 1;
            self.updateStats();
        }
        
        // 读取单个元素（线程安全）
        pub fn read(self: *Self) RingBufferError!T {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            
            if (head == tail) {
                self.stats.total_underruns += 1;
                return RingBufferError.BufferEmpty;
            }
            
            const item = self.buffer[tail & self.mask];
            _ = self.tail.fetchAdd(1, .release);
            
            self.stats.total_reads += 1;
            self.updateStats();
            
            return item;
        }
        
        // 其他方法与SPSC版本类似，但都需要加锁
        pub fn size(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return head - tail;
        }
        
        pub fn isEmpty(self: *Self) bool {
            return self.size() == 0;
        }
        
        pub fn isFull(self: *Self) bool {
            return self.size() >= self.capacity;
        }
        
        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            self.head.store(0, .release);
            self.tail.store(0, .release);
        }
        
        pub fn getStats(self: *Self) RingBufferStats {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            self.updateStats();
            return self.stats;
        }
        
        fn updateStats(self: *Self) void {
            const current_size = self.head.load(.acquire) - self.tail.load(.acquire);
            self.stats.current_size = current_size;
            if (current_size > self.stats.peak_usage) {
                self.stats.peak_usage = current_size;
            }
        }
    };
}

// 通用环形缓冲区接口
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        
        vtable: *const VTable,
        
        pub const VTable = struct {
            write: *const fn (self: *Self, item: T) RingBufferError!void,
            read: *const fn (self: *Self) RingBufferError!T,
            size: *const fn (self: *Self) usize,
            isEmpty: *const fn (self: *Self) bool,
            isFull: *const fn (self: *Self) bool,
            clear: *const fn (self: *Self) void,
            getStats: *const fn (self: *Self) RingBufferStats,
            deinit: *const fn (self: *Self) void,
        };
        
        pub fn write(self: *Self, item: T) RingBufferError!void {
            return self.vtable.write(self, item);
        }
        
        pub fn read(self: *Self) RingBufferError!T {
            return self.vtable.read(self);
        }
        
        pub fn size(self: *Self) usize {
            return self.vtable.size(self);
        }
        
        pub fn isEmpty(self: *Self) bool {
            return self.vtable.isEmpty(self);
        }
        
        pub fn isFull(self: *Self) bool {
            return self.vtable.isFull(self);
        }
        
        pub fn clear(self: *Self) void {
            self.vtable.clear(self);
        }
        
        pub fn getStats(self: *Self) RingBufferStats {
            return self.vtable.getStats(self);
        }
        
        pub fn deinit(self: *Self) void {
            self.vtable.deinit(self);
        }
    };
}

// 工厂函数
pub fn createSPSCRingBuffer(comptime T: type, allocator: Allocator, config: RingBufferConfig) !*SPSCRingBuffer(T) {
    return SPSCRingBuffer(T).init(allocator, config);
}

pub fn createMPMCRingBuffer(comptime T: type, allocator: Allocator, config: RingBufferConfig) !*MPMCRingBuffer(T) {
    return MPMCRingBuffer(T).init(allocator, config);
}

// 便利函数
pub fn createRingBuffer(comptime T: type, allocator: Allocator, capacity: usize) !*SPSCRingBuffer(T) {
    const config = RingBufferConfig.default(capacity);
    return createSPSCRingBuffer(T, allocator, config);
}

pub fn createThreadSafeRingBuffer(comptime T: type, allocator: Allocator, capacity: usize) !*MPMCRingBuffer(T) {
    const config = RingBufferConfig.default(capacity);
    return createMPMCRingBuffer(T, allocator, config);
}

// 测试
test "SPSCRingBuffer basic operations" {
    const allocator = testing.allocator;
    const config = RingBufferConfig.default(8);
    
    const ring_buffer = try createSPSCRingBuffer(u32, allocator, config);
    defer ring_buffer.deinit();
    
    // 测试写入和读取
    try ring_buffer.write(1);
    try ring_buffer.write(2);
    try ring_buffer.write(3);
    
    try testing.expect(ring_buffer.size() == 3);
    try testing.expect(!ring_buffer.isEmpty());
    try testing.expect(!ring_buffer.isFull());
    
    const item1 = try ring_buffer.read();
    const item2 = try ring_buffer.read();
    const item3 = try ring_buffer.read();
    
    try testing.expect(item1 == 1);
    try testing.expect(item2 == 2);
    try testing.expect(item3 == 3);
    try testing.expect(ring_buffer.isEmpty());
}

test "SPSCRingBuffer overflow handling" {
    const allocator = testing.allocator;
    const config = RingBufferConfig.default(4);
    
    const ring_buffer = try createSPSCRingBuffer(u32, allocator, config);
    defer ring_buffer.deinit();
    
    // 填满缓冲区
    try ring_buffer.write(1);
    try ring_buffer.write(2);
    try ring_buffer.write(3);
    try ring_buffer.write(4);
    
    try testing.expect(ring_buffer.isFull());
    
    // 尝试再写入应该失败
    try testing.expectError(RingBufferError.BufferFull, ring_buffer.write(5));
}

test "SPSCRingBuffer overwrite mode" {
    const allocator = testing.allocator;
    const config = RingBufferConfig.overwriteMode(4);
    
    const ring_buffer = try createSPSCRingBuffer(u32, allocator, config);
    defer ring_buffer.deinit();
    
    // 填满缓冲区
    try ring_buffer.write(1);
    try ring_buffer.write(2);
    try ring_buffer.write(3);
    try ring_buffer.write(4);
    
    // 覆盖模式下应该能继续写入
    try ring_buffer.write(5);
    
    // 第一个元素应该被覆盖
    const item = try ring_buffer.read();
    try testing.expect(item == 2); // 1被覆盖了
}

test "RingBufferStats" {
    const allocator = testing.allocator;
    const config = RingBufferConfig.default(8);
    
    const ring_buffer = try createSPSCRingBuffer(u32, allocator, config);
    defer ring_buffer.deinit();
    
    try ring_buffer.write(1);
    try ring_buffer.write(2);
    _ = try ring_buffer.read();
    
    const stats = ring_buffer.getStats();
    try testing.expect(stats.total_writes == 2);
    try testing.expect(stats.total_reads == 1);
    try testing.expect(stats.current_size == 1);
    try testing.expect(stats.peak_usage == 2);
}

test "MPMCRingBuffer thread safety" {
    const allocator = testing.allocator;
    const config = RingBufferConfig.default(1000);
    
    const ring_buffer = try createMPMCRingBuffer(u32, allocator, config);
    defer ring_buffer.deinit();
    
    // 简单的线程安全测试
    try ring_buffer.write(42);
    const item = try ring_buffer.read();
    try testing.expect(item == 42);
}