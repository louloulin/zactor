//! Memory Management Utilities - 内存管理工具
//! 提供高性能的内存分配器、对象池和内存统计功能

const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic = std.atomic;
const testing = std.testing;

// 内存错误
pub const MemoryError = error{
    OutOfMemory,
    InvalidAlignment,
    InvalidSize,
    PoolExhausted,
    DoubleFree,
    CorruptedMemory,
};

// 内存统计信息
pub const MemoryStats = struct {
    total_allocated: std.atomic.Value(u64),
    total_freed: std.atomic.Value(u64),
    current_allocated: std.atomic.Value(u64),
    peak_allocated: std.atomic.Value(u64),
    allocation_count: std.atomic.Value(u64),
    free_count: std.atomic.Value(u64),
    
    pub fn init() MemoryStats {
        return MemoryStats{
            .total_allocated = std.atomic.Value(u64).init(0),
        .total_freed = std.atomic.Value(u64).init(0),
        .current_allocated = std.atomic.Value(u64).init(0),
        .peak_allocated = std.atomic.Value(u64).init(0),
        .allocation_count = std.atomic.Value(u64).init(0),
        .free_count = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn recordAllocation(self: *MemoryStats, size: usize) void {
        _ = self.total_allocated.fetchAdd(size, .release);
        const current = self.current_allocated.fetchAdd(size, .release) + size;
        _ = self.allocation_count.fetchAdd(1, .release);
        
        // 更新峰值
        var peak = self.peak_allocated.load(.acquire);
        while (current > peak) {
            peak = self.peak_allocated.cmpxchgWeak(peak, current, .release, .acquire) orelse break;
        }
    }
    
    pub fn recordFree(self: *MemoryStats, size: usize) void {
        _ = self.current_allocated.fetchSub(size, .release);
        _ = self.total_freed.fetchAdd(size, .release);
        _ = self.free_count.fetchAdd(1, .release);
    }
    
    pub fn getCurrentAllocated(self: *const MemoryStats) u64 {
        return self.current_allocated.load(.acquire);
    }
    
    pub fn getPeakAllocated(self: *const MemoryStats) u64 {
        return self.peak_allocated.load(.acquire);
    }
    
    pub fn getTotalAllocated(self: *const MemoryStats) u64 {
        return self.total_allocated.load(.acquire);
    }
    
    pub fn getTotalFreed(self: *const MemoryStats) u64 {
        return self.total_freed.load(.acquire);
    }
    
    pub fn getAllocationCount(self: *const MemoryStats) u64 {
        return self.allocation_count.load(.acquire);
    }
    
    pub fn getFreeCount(self: *const MemoryStats) u64 {
        return self.free_count.load(.acquire);
    }
    
    pub fn getFragmentationRatio(self: *const MemoryStats) f64 {
        const total = self.getTotalAllocated();
        const freed = self.getTotalFreed();
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(freed)) / @as(f64, @floatFromInt(total));
    }
};

// 统计分配器
pub const StatsAllocator = struct {
    const Self = @This();
    
    child_allocator: Allocator,
    stats: MemoryStats,
    
    pub fn init(child_allocator: Allocator) Self {
        return Self{
            .child_allocator = child_allocator,
            .stats = MemoryStats.init(),
        };
    }
    
    pub fn allocator(self: *Self) Allocator {
        return Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = Allocator.noRemap,
            },
        };
    }
    
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const result = self.child_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            self.stats.recordAllocation(len);
        }
        return result;
    }
    
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const result = self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) {
            if (new_len > buf.len) {
                self.stats.recordAllocation(new_len - buf.len);
            } else if (new_len < buf.len) {
                self.stats.recordFree(buf.len - new_len);
            }
        }
        return result;
    }
    
    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.child_allocator.rawFree(buf, buf_align, ret_addr);
        self.stats.recordFree(buf.len);
    }
    
    pub fn getStats(self: *const Self) MemoryStats {
        return self.stats;
    }
    
    pub fn resetStats(self: *Self) void {
        self.stats = MemoryStats.init();
    }
};

// 对象池配置
pub const ObjectPoolConfig = struct {
    initial_capacity: usize,
    max_capacity: usize,
    growth_factor: f32,
    shrink_threshold: f32,
    enable_stats: bool,
    
    pub fn default(initial_capacity: usize) ObjectPoolConfig {
        return ObjectPoolConfig{
            .initial_capacity = initial_capacity,
            .max_capacity = initial_capacity * 10,
            .growth_factor = 2.0,
            .shrink_threshold = 0.25,
            .enable_stats = true,
        };
    }
    
    pub fn fixed(capacity: usize) ObjectPoolConfig {
        return ObjectPoolConfig{
            .initial_capacity = capacity,
            .max_capacity = capacity,
            .growth_factor = 1.0,
            .shrink_threshold = 0.0,
            .enable_stats = false,
        };
    }
};

// 对象池统计
pub const ObjectPoolStats = struct {
    objects_created: std.atomic.Value(u64),
    objects_acquired: std.atomic.Value(u64),
    objects_returned: std.atomic.Value(u64),
    objects_destroyed: std.atomic.Value(u64),
    pool_hits: std.atomic.Value(u64),
    pool_misses: std.atomic.Value(u64),
    current_pool_size: std.atomic.Value(usize),
    peak_pool_size: std.atomic.Value(usize),
    
    pub fn init() ObjectPoolStats {
        return ObjectPoolStats{
            .objects_created = std.atomic.Value(u64).init(0),
        .objects_acquired = std.atomic.Value(u64).init(0),
        .objects_returned = std.atomic.Value(u64).init(0),
        .objects_destroyed = std.atomic.Value(u64).init(0),
        .pool_hits = std.atomic.Value(u64).init(0),
        .pool_misses = std.atomic.Value(u64).init(0),
        .current_pool_size = std.atomic.Value(usize).init(0),
        .peak_pool_size = std.atomic.Value(usize).init(0),
        };
    }
    
    pub fn getHitRate(self: *const ObjectPoolStats) f64 {
        const hits = self.pool_hits.load(.acquire);
        const misses = self.pool_misses.load(.acquire);
        const total = hits + misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
    }
    
    pub fn getUtilization(self: *const ObjectPoolStats) f64 {
        const current = self.current_pool_size.load(.acquire);
        const peak = self.peak_pool_size.load(.acquire);
        if (peak == 0) return 0.0;
        return @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(peak));
    }
};

// 通用对象池
pub fn ObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();
        
        allocator: Allocator,
        config: ObjectPoolConfig,
        pool: std.ArrayList(*T),
        stats: ObjectPoolStats,
        mutex: std.Thread.Mutex,
        
        pub fn init(allocator: Allocator, config: ObjectPoolConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            
            self.* = Self{
                .allocator = allocator,
                .config = config,
                .pool = std.ArrayList(*T).init(allocator),
                .stats = ObjectPoolStats.init(),
                .mutex = std.Thread.Mutex{},
            };
            
            // 预分配初始对象
            try self.pool.ensureTotalCapacity(config.initial_capacity);
            for (0..config.initial_capacity) |_| {
                const obj = try allocator.create(T);
                try self.pool.append(obj);
            }
            
            self.stats.current_pool_size.store(config.initial_capacity, .release);
            self.stats.peak_pool_size.store(config.initial_capacity, .release);
            
            return self;
        }
        
        pub fn deinit(self: *Self) void {
            // 销毁池中的所有对象
            for (self.pool.items) |obj| {
                self.allocator.destroy(obj);
            }
            self.pool.deinit();
            self.allocator.destroy(self);
        }
        
        // 获取对象
        pub fn acquire(self: *Self) !*T {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            if (self.config.enable_stats) {
                _ = self.stats.objects_acquired.fetchAdd(1, .release);
            }
            
            // 尝试从池中获取
            if (self.pool.items.len > 0) {
                const obj = self.pool.pop().?; // 我们已经检查了长度，所以可以安全地解包
                if (self.config.enable_stats) {
                    _ = self.stats.pool_hits.fetchAdd(1, .release);
                    _ = self.stats.current_pool_size.fetchSub(1, .release);
                }
                return obj;
            }
            
            // 池为空，创建新对象
            if (self.config.enable_stats) {
                _ = self.stats.pool_misses.fetchAdd(1, .release);
                _ = self.stats.objects_created.fetchAdd(1, .release);
            }
            
            return self.allocator.create(T);
        }
        
        // 归还对象
        pub fn release(self: *Self, obj: *T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            if (self.config.enable_stats) {
                _ = self.stats.objects_returned.fetchAdd(1, .release);
            }
            
            // 检查池是否已满
            if (self.pool.items.len >= self.config.max_capacity) {
                // 池已满，直接销毁对象
                self.allocator.destroy(obj);
                if (self.config.enable_stats) {
                    _ = self.stats.objects_destroyed.fetchAdd(1, .release);
                }
                return;
            }
            
            // 归还到池中
            try self.pool.append(obj);
            
            if (self.config.enable_stats) {
                const new_size = self.stats.current_pool_size.fetchAdd(1, .release) + 1;
                // 更新峰值
                var peak = self.stats.peak_pool_size.load(.acquire);
        while (new_size > peak) {
            peak = self.stats.peak_pool_size.cmpxchgWeak(peak, new_size, .release, .acquire) orelse break;
        }
            }
        }
        
        // 获取当前池大小
        pub fn size(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.pool.items.len;
        }
        
        // 清空池
        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            for (self.pool.items) |obj| {
                self.allocator.destroy(obj);
                if (self.config.enable_stats) {
                    _ = self.stats.objects_destroyed.fetchAdd(1, .release);
                }
            }
            self.pool.clearRetainingCapacity();
            
            if (self.config.enable_stats) {
                self.stats.current_pool_size.store(0, .release);
            }
        }
        
        // 收缩池
        pub fn shrink(self: *Self) void {
            if (self.config.shrink_threshold <= 0.0) return;
            
            self.mutex.lock();
            defer self.mutex.unlock();
            
            const current_size = self.pool.items.len;
            const target_size = @as(usize, @intFromFloat(@as(f32, @floatFromInt(self.config.max_capacity)) * self.config.shrink_threshold));
            
            if (current_size > target_size) {
                const to_remove = current_size - target_size;
                for (0..to_remove) |_| {
                    if (self.pool.popOrNull()) |obj| {
                        self.allocator.destroy(obj);
                        if (self.config.enable_stats) {
                            _ = self.stats.objects_destroyed.fetchAdd(1, .release);
                            _ = self.stats.current_pool_size.fetchSub(1, .release);
                        }
                    }
                }
            }
        }
        
        // 获取统计信息
        pub fn getStats(self: *Self) ObjectPoolStats {
            return self.stats;
        }
        
        // 重置统计信息
        pub fn resetStats(self: *Self) void {
            self.stats = ObjectPoolStats.init();
            self.stats.current_pool_size.store(self.size(), .release);
        }
    };
}

// 内存池分配器
pub const MemoryPool = struct {
    const Self = @This();
    const Block = struct {
        data: []u8,
        next: ?*Block,
        used: bool,
    };
    
    allocator: Allocator,
    block_size: usize,
    blocks: ?*Block,
    free_blocks: ?*Block,
    stats: MemoryStats,
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: Allocator, block_size: usize, initial_blocks: usize) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.* = Self{
            .allocator = allocator,
            .block_size = block_size,
            .blocks = null,
            .free_blocks = null,
            .stats = MemoryStats.init(),
            .mutex = std.Thread.Mutex{},
        };
        
        // 预分配初始块
        for (0..initial_blocks) |_| {
            try self.addBlock();
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        var current = self.blocks;
        while (current) |block| {
            const next = block.next;
            self.allocator.free(block.data);
            self.allocator.destroy(block);
            current = next;
        }
        self.allocator.destroy(self);
    }
    
    fn addBlock(self: *Self) !void {
        const block = try self.allocator.create(Block);
        errdefer self.allocator.destroy(block);
        
        const data = try self.allocator.alloc(u8, self.block_size);
        errdefer self.allocator.free(data);
        
        block.* = Block{
            .data = data,
            .next = self.blocks,
            .used = false,
        };
        
        self.blocks = block;
        
        // 添加到空闲列表
        block.next = self.free_blocks;
        self.free_blocks = block;
    }
    
    pub fn alloc(self: *Self, size: usize) ![]u8 {
        if (size > self.block_size) {
            return MemoryError.InvalidSize;
        }
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 查找空闲块
        if (self.free_blocks) |block| {
            self.free_blocks = block.next;
            block.used = true;
            block.next = null;
            
            self.stats.recordAllocation(size);
            return block.data[0..size];
        }
        
        // 没有空闲块，创建新块
        try self.addBlock();
        return self.alloc(size);
    }
    
    pub fn free(self: *Self, ptr: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 查找对应的块
        var current = self.blocks;
        while (current) |block| {
            if (@intFromPtr(ptr.ptr) >= @intFromPtr(block.data.ptr) and @intFromPtr(ptr.ptr) < @intFromPtr(block.data.ptr) + block.data.len) {
                if (!block.used) {
                    // 双重释放检测
                    return; // 或者可以返回错误
                }
                
                block.used = false;
                block.next = self.free_blocks;
                self.free_blocks = block;
                
                self.stats.recordFree(ptr.len);
                return;
            }
            current = block.next;
        }
    }
    
    pub fn getStats(self: *Self) MemoryStats {
        return self.stats;
    }
};

// 对齐分配器
pub const AlignedAllocator = struct {
    const Self = @This();
    
    child_allocator: Allocator,
    alignment: usize,
    
    pub fn init(child_allocator: Allocator, alignment: usize) Self {
        return Self{
            .child_allocator = child_allocator,
            .alignment = alignment,
        };
    }
    
    pub fn allocator(self: *Self) Allocator {
        return Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = Allocator.noRemap,
            },
        };
    }
    
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const alignment = @max(self.alignment, ptr_align.toByteUnits());
        const final_log2_align: u8 = @intCast(std.math.log2_int(usize, alignment));
        const final_align: std.mem.Alignment = @enumFromInt(final_log2_align);
        return self.child_allocator.rawAlloc(len, final_align, ret_addr);
    }
    
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }
    
    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.child_allocator.rawFree(buf, buf_align, ret_addr);
    }
};

// 工厂函数
pub fn createObjectPool(comptime T: type, allocator: Allocator, config: ObjectPoolConfig) !*ObjectPool(T) {
    return ObjectPool(T).init(allocator, config);
}

pub fn createMemoryPool(allocator: Allocator, block_size: usize, initial_blocks: usize) !*MemoryPool {
    return MemoryPool.init(allocator, block_size, initial_blocks);
}

pub fn createStatsAllocator(child_allocator: Allocator) StatsAllocator {
    return StatsAllocator.init(child_allocator);
}

pub fn createAlignedAllocator(child_allocator: Allocator, alignment: usize) AlignedAllocator {
    return AlignedAllocator.init(child_allocator, alignment);
}

// 便利函数
pub fn alignedAlloc(allocator: Allocator, comptime T: type, alignment: usize, n: usize) ![]T {
    const byte_count = n * @sizeOf(T);
    const bytes = try allocator.alignedAlloc(u8, alignment, byte_count);
    return @as([*]T, @ptrCast(@alignCast(bytes.ptr)))[0..n];
}

pub fn alignedFree(allocator: Allocator, slice: anytype) void {
    const bytes = std.mem.sliceAsBytes(slice);
    allocator.free(bytes);
}

// 测试
test "StatsAllocator" {
    var stats_allocator = createStatsAllocator(testing.allocator);
    const allocator = stats_allocator.allocator();
    
    const ptr1 = try allocator.alloc(u8, 100);
    const ptr2 = try allocator.alloc(u8, 200);
    
    const stats = stats_allocator.getStats();
    try testing.expect(stats.getCurrentAllocated() == 300);
    try testing.expect(stats.getAllocationCount() == 2);
    
    allocator.free(ptr1);
    allocator.free(ptr2);
    
    const final_stats = stats_allocator.getStats();
    try testing.expect(final_stats.getCurrentAllocated() == 0);
    try testing.expect(final_stats.getFreeCount() == 2);
}

test "ObjectPool" {
    const TestStruct = struct {
        value: u32 = 0,
    };
    
    const config = ObjectPoolConfig.default(2);
    const pool = try createObjectPool(TestStruct, testing.allocator, config);
    defer pool.deinit();
    
    // 获取对象
    const obj1 = try pool.acquire();
    const obj2 = try pool.acquire();
    const obj3 = try pool.acquire(); // 应该创建新对象
    
    obj1.value = 1;
    obj2.value = 2;
    obj3.value = 3;
    
    // 归还对象
    try pool.release(obj1);
    try pool.release(obj2);
    try pool.release(obj3);
    
    // 再次获取应该重用对象
    const obj4 = try pool.acquire();
    try testing.expect(obj4.value == 2 or obj4.value == 3); // 应该是之前的对象之一
    
    try pool.release(obj4);
    
    const stats = pool.getStats();
    try testing.expect(stats.objects_acquired.load(.acquire) == 4);
    try testing.expect(stats.objects_returned.load(.acquire) == 4);
    try testing.expect(stats.pool_hits.load(.acquire) >= 1);
}

test "MemoryPool" {
    const pool = try createMemoryPool(testing.allocator, 1024, 2);
    defer pool.deinit();
    
    const ptr1 = try pool.alloc(100);
    const ptr2 = try pool.alloc(200);
    const ptr3 = try pool.alloc(300); // 应该创建新块
    
    pool.free(ptr1);
    pool.free(ptr2);
    
    const ptr4 = try pool.alloc(150); // 应该重用释放的块
    
    pool.free(ptr3);
    pool.free(ptr4);
    
    const stats = pool.getStats();
    try testing.expect(stats.getCurrentAllocated() == 0);
}

test "AlignedAllocator" {
    var aligned_allocator = createAlignedAllocator(testing.allocator, 64);
    const allocator = aligned_allocator.allocator();
    
    const ptr = try allocator.alloc(u8, 100);
    defer allocator.free(ptr);
    
    // 检查对齐
    const addr = @intFromPtr(ptr.ptr);
    try testing.expect(addr % 64 == 0);
}

test "MemoryStats" {
    var stats = MemoryStats.init();
    
    stats.recordAllocation(100);
    stats.recordAllocation(200);
    stats.recordFree(100);
    
    try testing.expect(stats.getCurrentAllocated() == 200);
    try testing.expect(stats.getTotalAllocated() == 300);
    try testing.expect(stats.getTotalFreed() == 100);
    try testing.expect(stats.getAllocationCount() == 2);
    try testing.expect(stats.getFreeCount() == 1);
}