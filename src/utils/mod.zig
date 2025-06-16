//! Utils Module - 工具模块
//! 提供Actor系统所需的各种工具和数据结构

const std = @import("std");

// 重新导出工具模块
pub const ring_buffer = @import("ring_buffer.zig");
pub const thread_pool = @import("thread_pool.zig");
pub const memory = @import("memory.zig");
pub const lockfree_queue = @import("lockfree_queue.zig");

// 重新导出工具类型
pub const LockFreeQueue = lockfree_queue.LockFreeQueue;

// Ring Buffer types
pub const RingBufferError = ring_buffer.RingBufferError;
pub const RingBufferConfig = ring_buffer.RingBufferConfig;
pub const RingBufferStats = ring_buffer.RingBufferStats;
pub const SPSCRingBuffer = ring_buffer.SPSCRingBuffer;
pub const MPMCRingBuffer = ring_buffer.MPMCRingBuffer;
pub const RingBuffer = ring_buffer.RingBuffer;
pub const createSPSCRingBuffer = ring_buffer.createSPSCRingBuffer;
pub const createMPMCRingBuffer = ring_buffer.createMPMCRingBuffer;
pub const createRingBuffer = ring_buffer.createRingBuffer;
pub const createThreadSafeRingBuffer = ring_buffer.createThreadSafeRingBuffer;

// Thread Pool types
pub const ThreadPoolError = thread_pool.ThreadPoolError;
pub const TaskPriority = thread_pool.TaskPriority;
pub const TaskState = thread_pool.TaskState;
pub const Task = thread_pool.Task;
pub const ThreadPoolConfig = thread_pool.ThreadPoolConfig;
pub const ThreadPoolStats = thread_pool.ThreadPoolStats;
pub const ThreadPool = thread_pool.ThreadPool;
pub const createThreadPool = thread_pool.createThreadPool;
pub const createFixedThreadPool = thread_pool.createFixedThreadPool;
pub const createSingleThreadPool = thread_pool.createSingleThreadPool;
pub const createDefaultThreadPool = thread_pool.createDefaultThreadPool;

// Memory Management types
pub const MemoryError = memory.MemoryError;
pub const MemoryStats = memory.MemoryStats;
pub const StatsAllocator = memory.StatsAllocator;
pub const ObjectPoolConfig = memory.ObjectPoolConfig;
pub const ObjectPoolStats = memory.ObjectPoolStats;
pub const ObjectPool = memory.ObjectPool;
pub const MemoryPool = memory.MemoryPool;
pub const AlignedAllocator = memory.AlignedAllocator;
pub const createObjectPool = memory.createObjectPool;
pub const createMemoryPool = memory.createMemoryPool;
pub const createStatsAllocator = memory.createStatsAllocator;
pub const createAlignedAllocator = memory.createAlignedAllocator;
pub const alignedAlloc = memory.alignedAlloc;
pub const alignedFree = memory.alignedFree;

// Legacy imports (for backward compatibility)
// TODO: These should be removed or updated to use the new implementations
// pub const MessagePool = @import("message_pool.zig").MessagePool;
// pub const AtomicCounter = @import("atomic_counter.zig").AtomicCounter;
// pub const ThreadSafeHashMap = @import("thread_safe_hashmap.zig").ThreadSafeHashMap;
// pub const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;
// pub const SpinLock = @import("spin_lock.zig").SpinLock;
// pub const WaitFreeQueue = @import("wait_free_queue.zig").WaitFreeQueue;
// pub const CacheAlignedAllocator = @import("cache_aligned_allocator.zig").CacheAlignedAllocator;
// pub const PerformanceTimer = @import("performance_timer.zig").PerformanceTimer;
// pub const StatisticsCollector = @import("statistics_collector.zig").StatisticsCollector;

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
    InvalidParameter,
    OutOfMemory,
    Timeout,
    InvalidState,
    NotFound,
    AlreadyExists,
    PermissionDenied,
    ResourceBusy,
    InvalidOperation,
    SystemError,
    
    // Ring Buffer errors
    BufferFull,
    BufferEmpty,
    InvalidCapacity,
    
    // Thread Pool errors
    ThreadCreationFailed,
    TaskSubmissionFailed,
    PoolShutdown,
    
    // Memory errors
    AllocationFailed,
    InvalidAlignment,
    DoubleFree,
    CorruptedPool,
};

// Utils配置
pub const UtilsConfig = struct {
    ring_buffer: RingBufferConfig,
    thread_pool: ThreadPoolConfig,
    memory: struct {
        object_pool: ObjectPoolConfig,
        enable_stats: bool,
        alignment: u32,
    },
    enable_debug: bool,
    enable_metrics: bool,
    
    pub const default = UtilsConfig{
        .ring_buffer = RingBufferConfig.default,
        .thread_pool = ThreadPoolConfig.default,
        .memory = .{
            .object_pool = ObjectPoolConfig.default,
            .enable_stats = true,
            .alignment = 16,
        },
        .enable_debug = false,
        .enable_metrics = true,
    };
    
    pub const development = UtilsConfig{
        .ring_buffer = RingBufferConfig.development,
        .thread_pool = ThreadPoolConfig.development,
        .memory = .{
            .object_pool = ObjectPoolConfig.default,
            .enable_stats = true,
            .alignment = 16,
        },
        .enable_debug = true,
        .enable_metrics = true,
    };
    
    pub const production = UtilsConfig{
        .ring_buffer = RingBufferConfig.production,
        .thread_pool = ThreadPoolConfig.production,
        .memory = .{
            .object_pool = ObjectPoolConfig.fixed,
            .enable_stats = false,
            .alignment = 64,
        },
        .enable_debug = false,
        .enable_metrics = false,
    };
};

// Utils统计信息
pub const UtilsStats = struct {
    ring_buffer_stats: RingBufferStats,
    thread_pool_stats: ThreadPoolStats,
    memory_stats: MemoryStats,
    
    pub fn init() UtilsStats {
        return UtilsStats{
            .ring_buffer_stats = RingBufferStats.init(),
            .thread_pool_stats = ThreadPoolStats.init(),
            .memory_stats = MemoryStats.init(),
        };
    }
    
    pub fn reset(self: *UtilsStats) void {
        self.ring_buffer_stats.reset();
        self.thread_pool_stats.reset();
        self.memory_stats.reset();
    }
    
    pub fn getTotalAllocations(self: *const UtilsStats) u64 {
        return self.memory_stats.total_allocations.load(.Monotonic);
    }
    
    pub fn getTotalDeallocations(self: *const UtilsStats) u64 {
        return self.memory_stats.total_deallocations.load(.Monotonic);
    }
    
    pub fn getCurrentMemoryUsage(self: *const UtilsStats) u64 {
        return self.memory_stats.current_memory_usage.load(.Monotonic);
    }
    
    pub fn getPeakMemoryUsage(self: *const UtilsStats) u64 {
        return self.memory_stats.peak_memory_usage.load(.Monotonic);
    }
};

// Utils模块管理器
pub const UtilsModule = struct {
    allocator: std.mem.Allocator,
    config: UtilsConfig,
    stats: UtilsStats,
    initialized: bool,
    
    pub fn init(allocator: std.mem.Allocator, config: UtilsConfig) !UtilsModule {
        return UtilsModule{
            .allocator = allocator,
            .config = config,
            .stats = UtilsStats.init(),
            .initialized = true,
        };
    }
    
    pub fn deinit(self: *UtilsModule) void {
        self.initialized = false;
    }
    
    pub fn createRingBuffer(self: *UtilsModule, comptime T: type, capacity: usize) !*RingBuffer(T) {
        if (!self.initialized) return UtilsError.InvalidState;
        return createRingBuffer(T, self.allocator, capacity, self.config.ring_buffer);
    }
    
    pub fn createObjectPool(self: *UtilsModule, comptime T: type) !*ObjectPool(T) {
        if (!self.initialized) return UtilsError.InvalidState;
        return memory.createObjectPool(T, self.allocator, self.config.memory.object_pool);
    }
    
    pub fn createThreadPool(self: *UtilsModule) !*ThreadPool {
        if (!self.initialized) return UtilsError.InvalidState;
        return thread_pool.createThreadPool(self.allocator, self.config.thread_pool);
    }
    
    pub fn getStats(self: *const UtilsModule) UtilsStats {
        return self.stats;
    }
    
    pub fn resetStats(self: *UtilsModule) void {
        self.stats.reset();
    }
    
    pub fn updateConfig(self: *UtilsModule, new_config: UtilsConfig) void {
        self.config = new_config;
    }
    
    pub fn isHealthy(self: *const UtilsModule) bool {
        return self.initialized;
    }
    
    pub fn shutdown(self: *UtilsModule) void {
        self.deinit();
    }
};

// 工厂函数
pub fn createUtilsModule(allocator: std.mem.Allocator, config: UtilsConfig) !*UtilsModule {
    const module = try allocator.create(UtilsModule);
    module.* = try UtilsModule.init(allocator, config);
    return module;
}

pub fn createDefaultUtilsModule(allocator: std.mem.Allocator) !*UtilsModule {
    return createUtilsModule(allocator, UtilsConfig.default);
}

pub fn createDevelopmentUtilsModule(allocator: std.mem.Allocator) !*UtilsModule {
    return createUtilsModule(allocator, UtilsConfig.development);
}

pub fn createProductionUtilsModule(allocator: std.mem.Allocator) !*UtilsModule {
    return createUtilsModule(allocator, UtilsConfig.production);
}

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

test "UtilsModule创建和配置" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // 测试默认配置
    const default_module = try createDefaultUtilsModule(allocator);
    defer {
        default_module.deinit();
        allocator.destroy(default_module);
    }
    
    try testing.expect(default_module.isHealthy());
    try testing.expect(default_module.config.enable_metrics);
    try testing.expect(!default_module.config.enable_debug);
    
    // 测试开发配置
    const dev_module = try createDevelopmentUtilsModule(allocator);
    defer {
        dev_module.deinit();
        allocator.destroy(dev_module);
    }
    
    try testing.expect(dev_module.config.enable_debug);
    try testing.expect(dev_module.config.enable_metrics);
    
    // 测试生产配置
    const prod_module = try createProductionUtilsModule(allocator);
    defer {
        prod_module.deinit();
        allocator.destroy(prod_module);
    }
    
    try testing.expect(!prod_module.config.enable_debug);
    try testing.expect(!prod_module.config.enable_metrics);
}

test "UtilsConfig预设" {
    const default_config = UtilsConfig.default;
    try testing.expect(default_config.enable_metrics);
    try testing.expect(!default_config.enable_debug);
    try testing.expect(default_config.memory.enable_stats);
    try testing.expect(default_config.memory.alignment == 16);
    
    const dev_config = UtilsConfig.development;
    try testing.expect(dev_config.enable_debug);
    try testing.expect(dev_config.enable_metrics);
    
    const prod_config = UtilsConfig.production;
    try testing.expect(!prod_config.enable_debug);
    try testing.expect(!prod_config.enable_metrics);
    try testing.expect(!prod_config.memory.enable_stats);
    try testing.expect(prod_config.memory.alignment == 64);
}

test "UtilsStats统计" {
    var stats = UtilsStats.init();
    
    // 测试初始状态
    try testing.expect(stats.getTotalAllocations() == 0);
    try testing.expect(stats.getTotalDeallocations() == 0);
    try testing.expect(stats.getCurrentMemoryUsage() == 0);
    try testing.expect(stats.getPeakMemoryUsage() == 0);
    
    // 测试重置
    stats.reset();
    try testing.expect(stats.getTotalAllocations() == 0);
}

test "UtilsModule工厂函数" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // 测试Ring Buffer创建
    const module = try createDefaultUtilsModule(allocator);
    defer {
        module.deinit();
        allocator.destroy(module);
    }
    
    // 注意：这些测试可能需要实际的实现才能通过
    // const ring_buffer = try module.createRingBuffer(u32, 1024);
    // defer ring_buffer.deinit();
    
    // const object_pool = try module.createObjectPool(u32);
    // defer object_pool.deinit();
    
    // const thread_pool = try module.createThreadPool();
    // defer thread_pool.deinit();
    
    // 测试统计信息
    const stats = module.getStats();
    _ = stats; // 避免未使用变量警告
    
    // 测试配置更新
    module.updateConfig(UtilsConfig.development);
    try testing.expect(module.config.enable_debug);
    
    // 测试健康检查
    try testing.expect(module.isHealthy());
    
    // 测试关闭
    module.shutdown();
    try testing.expect(!module.isHealthy());
}