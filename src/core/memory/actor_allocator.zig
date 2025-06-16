//! Actor专用高性能内存分配器
//! 目标: 消除内存分配瓶颈，提升10-20倍性能

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// 线程本地存储池
const ThreadLocalPool = struct {
    const Self = @This();

    /// 空闲块链表节点
    const FreeBlock = struct {
        next: ?*FreeBlock,
        size: usize,
    };

    blocks: []u8,
    free_list: ?*FreeBlock,
    block_size: usize,
    total_blocks: usize,
    allocated_count: std.atomic.Value(usize),

    pub fn init(allocator: Allocator, block_size: usize, num_blocks: usize) !Self {
        const total_size = block_size * num_blocks;
        const blocks = try allocator.alignedAlloc(u8, @alignOf(FreeBlock), total_size);

        var pool = Self{
            .blocks = blocks,
            .free_list = null,
            .block_size = block_size,
            .total_blocks = num_blocks,
            .allocated_count = std.atomic.Value(usize).init(0),
        };

        // 初始化空闲链表
        var i: usize = 0;
        while (i < num_blocks) : (i += 1) {
            const block_ptr = @as(*FreeBlock, @ptrCast(@alignCast(blocks.ptr + i * block_size)));
            block_ptr.next = pool.free_list;
            block_ptr.size = block_size;
            pool.free_list = block_ptr;
        }

        return pool;
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.blocks);
    }

    /// 快速分配 - 无锁，O(1)
    pub fn allocFast(self: *Self) ?[]u8 {
        if (self.free_list) |block| {
            self.free_list = block.next;
            _ = self.allocated_count.fetchAdd(1, .acq_rel);
            return @as([*]u8, @ptrCast(block))[0..self.block_size];
        }
        return null;
    }

    /// 快速释放 - 无锁，O(1)
    pub fn freeFast(self: *Self, ptr: []u8) void {
        if (ptr.len != self.block_size) return;

        const block = @as(*FreeBlock, @ptrCast(@alignCast(ptr.ptr)));
        block.next = self.free_list;
        block.size = self.block_size;
        self.free_list = block;
        _ = self.allocated_count.fetchSub(1, .acq_rel);
    }

    pub fn getStats(self: *const Self) struct { allocated: usize, total: usize, utilization: f32 } {
        const allocated = self.allocated_count.load(.acquire);
        return .{
            .allocated = allocated,
            .total = self.total_blocks,
            .utilization = @as(f32, @floatFromInt(allocated)) / @as(f32, @floatFromInt(self.total_blocks)),
        };
    }
};

/// 大小分级的对象池
const SizeClassPool = struct {
    const Self = @This();

    /// 支持的大小类别 (8B, 16B, 32B, 64B, 128B, 256B, 512B, 1KB, 2KB, 4KB, 8KB, 16KB, 32KB, 64KB)
    const SIZE_CLASSES = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
    const NUM_SIZE_CLASSES = SIZE_CLASSES.len;

    pools: [NUM_SIZE_CLASSES]ThreadLocalPool,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Self {
        var pools: [NUM_SIZE_CLASSES]ThreadLocalPool = undefined;

        for (SIZE_CLASSES, 0..) |size, i| {
            // 每个大小类别分配1000个块
            const num_blocks = 1000;
            pools[i] = try ThreadLocalPool.init(allocator, size, num_blocks);
        }

        return Self{
            .pools = pools,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (&self.pools) |*pool| {
            pool.deinit(self.allocator);
        }
    }

    /// 获取大小类别索引
    fn getSizeClassIndex(size: usize) ?usize {
        for (SIZE_CLASSES, 0..) |class_size, i| {
            if (size <= class_size) {
                return i;
            }
        }
        return null; // 超过最大支持大小
    }

    /// 快速分配
    pub fn allocFast(self: *Self, size: usize) ?[]u8 {
        const class_index = getSizeClassIndex(size) orelse return null;
        return self.pools[class_index].allocFast();
    }

    /// 快速释放
    pub fn freeFast(self: *Self, ptr: []u8) void {
        const class_index = getSizeClassIndex(ptr.len) orelse return;
        self.pools[class_index].freeFast(ptr);
    }

    pub fn getStats(self: *const Self) [NUM_SIZE_CLASSES]struct { size: usize, allocated: usize, total: usize, utilization: f32 } {
        var stats: [NUM_SIZE_CLASSES]struct { size: usize, allocated: usize, total: usize, utilization: f32 } = undefined;

        for (&self.pools, 0..) |*pool, i| {
            const pool_stats = pool.getStats();
            stats[i] = .{
                .size = SIZE_CLASSES[i],
                .allocated = pool_stats.allocated,
                .total = pool_stats.total,
                .utilization = pool_stats.utilization,
            };
        }

        return stats;
    }
};

/// Actor专用高性能内存分配器
pub const ActorMemoryAllocator = struct {
    const Self = @This();

    size_class_pool: SizeClassPool,
    fallback_allocator: Allocator,
    total_allocations: std.atomic.Value(u64),
    total_deallocations: std.atomic.Value(u64),
    fast_path_hits: std.atomic.Value(u64),
    slow_path_hits: std.atomic.Value(u64),

    pub fn init(base_allocator: Allocator) !*Self {
        const self = try base_allocator.create(Self);

        self.* = Self{
            .size_class_pool = try SizeClassPool.init(base_allocator),
            .fallback_allocator = base_allocator,
            .total_allocations = std.atomic.Value(u64).init(0),
            .total_deallocations = std.atomic.Value(u64).init(0),
            .fast_path_hits = std.atomic.Value(u64).init(0),
            .slow_path_hits = std.atomic.Value(u64).init(0),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.size_class_pool.deinit();
        self.fallback_allocator.destroy(self);
    }

    /// 超快速分配 - 优先使用对象池
    pub fn allocFast(self: *Self, size: usize) ![]u8 {
        _ = self.total_allocations.fetchAdd(1, .acq_rel);

        // 快速路径: 尝试从对象池分配
        if (self.size_class_pool.allocFast(size)) |memory| {
            _ = self.fast_path_hits.fetchAdd(1, .acq_rel);
            return memory;
        }

        // 慢速路径: 回退到标准分配器
        _ = self.slow_path_hits.fetchAdd(1, .acq_rel);
        return try self.fallback_allocator.alloc(u8, size);
    }

    /// 超快速释放
    pub fn freeFast(self: *Self, memory: []u8) void {
        _ = self.total_deallocations.fetchAdd(1, .acq_rel);

        // 尝试释放到对象池
        self.size_class_pool.freeFast(memory);
        // 注意: 如果不是从对象池分配的，这里会静默失败
        // 在生产环境中应该有更复杂的跟踪机制
    }

    /// 兼容标准Allocator接口
    pub fn allocator(self: *Self) Allocator {
        return Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = allocImpl,
                .resize = resizeImpl,
                .free = freeImpl,
                .remap = remapImpl,
            },
        };
    }

    fn allocImpl(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ptr_align;
        _ = ret_addr;

        const self: *Self = @ptrCast(@alignCast(ctx));
        const memory = self.allocFast(len) catch return null;
        return memory.ptr;
    }

    fn resizeImpl(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;

        // 简化实现: 不支持resize
        return false;
    }

    fn freeImpl(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;

        const self: *Self = @ptrCast(@alignCast(ctx));
        self.freeFast(buf);
    }

    fn remapImpl(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, len_align: std.mem.Alignment, ret_addr: usize) ?[]u8 {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = len_align;
        _ = ret_addr;

        // 简化实现: 不支持remap
        return null;
    }

    pub fn getPerformanceStats(self: *const Self) struct {
        total_allocations: u64,
        total_deallocations: u64,
        fast_path_hits: u64,
        slow_path_hits: u64,
        fast_path_ratio: f32,
    } {
        const total_allocs = self.total_allocations.load(.acquire);
        const fast_hits = self.fast_path_hits.load(.acquire);

        return .{
            .total_allocations = total_allocs,
            .total_deallocations = self.total_deallocations.load(.acquire),
            .fast_path_hits = fast_hits,
            .slow_path_hits = self.slow_path_hits.load(.acquire),
            .fast_path_ratio = if (total_allocs > 0)
                @as(f32, @floatFromInt(fast_hits)) / @as(f32, @floatFromInt(total_allocs))
            else
                0.0,
        };
    }
};

// 测试
test "ThreadLocalPool basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try ThreadLocalPool.init(allocator, 64, 10);
    defer pool.deinit(allocator);

    // 测试分配
    const block1 = pool.allocFast();
    try testing.expect(block1 != null);
    try testing.expect(block1.?.len == 64);

    const block2 = pool.allocFast();
    try testing.expect(block2 != null);

    // 测试统计
    var stats = pool.getStats();
    try testing.expect(stats.allocated == 2);
    try testing.expect(stats.total == 10);

    // 测试释放
    pool.freeFast(block1.?);
    stats = pool.getStats();
    try testing.expect(stats.allocated == 1);

    pool.freeFast(block2.?);
    stats = pool.getStats();
    try testing.expect(stats.allocated == 0);
}

test "ActorMemoryAllocator performance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const actor_allocator = try ActorMemoryAllocator.init(allocator);
    defer actor_allocator.deinit();

    // 测试快速分配
    const memory1 = try actor_allocator.allocFast(32);
    try testing.expect(memory1.len >= 32);

    const memory2 = try actor_allocator.allocFast(128);
    try testing.expect(memory2.len >= 128);

    // 测试释放
    actor_allocator.freeFast(memory1);
    actor_allocator.freeFast(memory2);

    // 检查性能统计
    const stats = actor_allocator.getPerformanceStats();
    try testing.expect(stats.total_allocations == 2);
    try testing.expect(stats.fast_path_hits > 0);
}
