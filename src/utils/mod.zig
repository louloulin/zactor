//! Utils Module - 工具模块
//! 提供Actor系统所需的各种工具和数据结构

const std = @import("std");

// 重新导出工具类型
pub const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;
pub const MessagePool = @import("message_pool.zig").MessagePool;
pub const RingBuffer = @import("ring_buffer.zig").RingBuffer;
pub const AtomicCounter = @import("atomic_counter.zig").AtomicCounter;
pub const ThreadSafeHashMap = @import("thread_safe_hashmap.zig").ThreadSafeHashMap;
pub const ObjectPool = @import("object_pool.zig").ObjectPool;
pub const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;
pub const SpinLock = @import("spin_lock.zig").SpinLock;
pub const WaitFreeQueue = @import("wait_free_queue.zig").WaitFreeQueue;
pub const MemoryPool = @import("memory_pool.zig").MemoryPool;
pub const CacheAlignedAllocator = @import("cache_aligned_allocator.zig").CacheAlignedAllocator;
pub const PerformanceTimer = @import("performance_timer.zig").PerformanceTimer;
pub const StatisticsCollector = @import("statistics_collector.zig").StatisticsCollector;

// 工具函数
pub const utils = struct {
    // CPU相关工具
    pub fn getCpuCount() u32 {
        return @intCast(std.Thread.getCpuCount() catch 1);
    }
    
    pub fn getCacheLineSize() u32 {
        return 64; // 大多数现代CPU的缓存行大小
    }
    
    pub fn alignToCacheLine(size: usize) usize {
        const cache_line_size = getCacheLineSize();
        return (size + cache_line_size - 1) & ~(cache_line_size - 1);
    }
    
    // 内存相关工具
    pub fn isPowerOfTwo(n: u32) bool {
        return n != 0 and (n & (n - 1)) == 0;
    }
    
    pub fn nextPowerOfTwo(n: u32) u32 {
        if (n == 0) return 1;
        return std.math.ceilPowerOfTwo(u32, n) catch n;
    }
    
    pub fn alignToSize(value: usize, alignment: usize) usize {
        return (value + alignment - 1) & ~(alignment - 1);
    }
    
    // 时间相关工具
    pub fn nanoTime() u64 {
        return @intCast(std.time.nanoTimestamp());
    }
    
    pub fn microTime() u64 {
        return @intCast(std.time.microTimestamp());
    }
    
    pub fn milliTime() u64 {
        return @intCast(std.time.milliTimestamp());
    }
    
    // 哈希相关工具
    pub fn hashBytes(data: []const u8) u64 {
        return std.hash_map.hashString(data);
    }
    
    pub fn hashPointer(ptr: *const anyopaque) u64 {
        return @intFromPtr(ptr);
    }
    
    // 原子操作工具
    pub fn atomicLoad(comptime T: type, ptr: *const std.atomic.Atomic(T), ordering: std.atomic.Ordering) T {
        return ptr.load(ordering);
    }
    
    pub fn atomicStore(comptime T: type, ptr: *std.atomic.Atomic(T), value: T, ordering: std.atomic.Ordering) void {
        ptr.store(value, ordering);
    }
    
    pub fn atomicCompareAndSwap(comptime T: type, ptr: *std.atomic.Atomic(T), expected: T, desired: T, success_ordering: std.atomic.Ordering, failure_ordering: std.atomic.Ordering) ?T {
        return ptr.compareAndSwap(expected, desired, success_ordering, failure_ordering);
    }
    
    // 性能相关工具
    pub fn spinLoopHint() void {
        std.atomic.spinLoopHint();
    }
    
    pub fn memoryFence(ordering: std.atomic.Ordering) void {
        std.atomic.fence(ordering);
    }
    
    pub fn prefetchRead(ptr: *const anyopaque, locality: u2) void {
        std.mem.prefetchRead(ptr, locality);
    }
    
    pub fn prefetchWrite(ptr: *anyopaque, locality: u2) void {
        std.mem.prefetchWrite(ptr, locality);
    }
    
    // 调试工具
    pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {
        if (std.debug.runtime_safety) {
            std.debug.print(fmt, args);
        }
    }
    
    pub fn debugAssert(condition: bool) void {
        if (std.debug.runtime_safety) {
            std.debug.assert(condition);
        }
    }
    
    // 错误处理工具
    pub fn panicWithMessage(comptime msg: []const u8) noreturn {
        @panic(msg);
    }
    
    pub fn unreachable() noreturn {
        std.debug.panic("Reached unreachable code", .{});
    }
};

// 常用常量
pub const constants = struct {
    pub const CACHE_LINE_SIZE: u32 = 64;
    pub const PAGE_SIZE: u32 = 4096;
    pub const DEFAULT_ALIGNMENT: u32 = 8;
    pub const MAX_CPUS: u32 = 256;
    pub const SPIN_LIMIT: u32 = 1000;
    pub const YIELD_THRESHOLD: u32 = 10;
    pub const BACKOFF_LIMIT: u32 = 16;
    
    // 性能相关常量
    pub const HIGH_CONTENTION_THRESHOLD: f32 = 0.8;
    pub const MEDIUM_CONTENTION_THRESHOLD: f32 = 0.5;
    pub const LOW_CONTENTION_THRESHOLD: f32 = 0.2;
    
    // 内存相关常量
    pub const DEFAULT_POOL_SIZE: u32 = 1000;
    pub const MAX_POOL_SIZE: u32 = 100000;
    pub const POOL_GROWTH_FACTOR: f32 = 1.5;
    
    // 时间相关常量
    pub const NANOSECONDS_PER_MICROSECOND: u64 = 1000;
    pub const NANOSECONDS_PER_MILLISECOND: u64 = 1000000;
    pub const NANOSECONDS_PER_SECOND: u64 = 1000000000;
    
    // 队列相关常量
    pub const DEFAULT_QUEUE_SIZE: u32 = 1024;
    pub const MAX_QUEUE_SIZE: u32 = 1048576; // 1M
    pub const MIN_QUEUE_SIZE: u32 = 16;
};

// 性能配置
pub const PerformanceConfig = struct {
    enable_statistics: bool = true,
    enable_profiling: bool = false,
    enable_tracing: bool = false,
    cache_line_padding: bool = true,
    use_memory_prefetch: bool = true,
    use_simd_optimization: bool = true,
    contention_detection: bool = true,
    adaptive_backoff: bool = true,
    
    pub fn optimizeForLatency() PerformanceConfig {
        return PerformanceConfig{
            .enable_statistics = false,
            .enable_profiling = false,
            .enable_tracing = false,
            .cache_line_padding = true,
            .use_memory_prefetch = true,
            .use_simd_optimization = true,
            .contention_detection = false,
            .adaptive_backoff = true,
        };
    }
    
    pub fn optimizeForThroughput() PerformanceConfig {
        return PerformanceConfig{
            .enable_statistics = true,
            .enable_profiling = false,
            .enable_tracing = false,
            .cache_line_padding = true,
            .use_memory_prefetch = true,
            .use_simd_optimization = true,
            .contention_detection = true,
            .adaptive_backoff = true,
        };
    }
    
    pub fn optimizeForDebugging() PerformanceConfig {
        return PerformanceConfig{
            .enable_statistics = true,
            .enable_profiling = true,
            .enable_tracing = true,
            .cache_line_padding = false,
            .use_memory_prefetch = false,
            .use_simd_optimization = false,
            .contention_detection = true,
            .adaptive_backoff = false,
        };
    }
};

// 错误类型
pub const UtilsError = error{
    OutOfMemory,
    InvalidArgument,
    BufferTooSmall,
    QueueFull,
    QueueEmpty,
    PoolExhausted,
    AllocationFailed,
    InvalidAlignment,
    InvalidSize,
    Timeout,
    Contention,
    ResourceBusy,
};

// 测试
const testing = std.testing;

test "utils basic functions" {
    // 测试CPU相关函数
    const cpu_count = utils.getCpuCount();
    try testing.expect(cpu_count > 0);
    
    const cache_line_size = utils.getCacheLineSize();
    try testing.expect(cache_line_size == 64);
    
    // 测试内存相关函数
    try testing.expect(utils.isPowerOfTwo(8));
    try testing.expect(!utils.isPowerOfTwo(7));
    
    try testing.expect(utils.nextPowerOfTwo(7) == 8);
    try testing.expect(utils.nextPowerOfTwo(8) == 8);
    
    // 测试对齐函数
    try testing.expect(utils.alignToSize(10, 8) == 16);
    try testing.expect(utils.alignToCacheLine(10) == 64);
}

test "performance config" {
    const latency_config = PerformanceConfig.optimizeForLatency();
    try testing.expect(!latency_config.enable_statistics);
    try testing.expect(latency_config.cache_line_padding);
    
    const throughput_config = PerformanceConfig.optimizeForThroughput();
    try testing.expect(throughput_config.enable_statistics);
    try testing.expect(throughput_config.contention_detection);
    
    const debug_config = PerformanceConfig.optimizeForDebugging();
    try testing.expect(debug_config.enable_profiling);
    try testing.expect(debug_config.enable_tracing);
}

test "constants" {
    try testing.expect(constants.CACHE_LINE_SIZE == 64);
    try testing.expect(constants.PAGE_SIZE == 4096);
    try testing.expect(constants.DEFAULT_ALIGNMENT == 8);
    try testing.expect(constants.NANOSECONDS_PER_SECOND == 1000000000);
}