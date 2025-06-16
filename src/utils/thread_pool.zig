//! Thread Pool Implementation - 线程池实现
//! 提供高性能的线程池，支持任务调度、工作窃取和动态扩缩容

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const atomic = std.atomic;
const testing = std.testing;
const RingBuffer = @import("ring_buffer.zig").SPSCRingBuffer;

// 线程池错误
pub const ThreadPoolError = error{
    PoolShutdown,
    TaskRejected,
    InvalidThreadCount,
    OutOfMemory,
    ThreadCreationFailed,
};

// 任务优先级
pub const TaskPriority = enum(u8) {
    Low = 0,
    Normal = 1,
    High = 2,
    Critical = 3,
    
    pub fn compare(self: TaskPriority, other: TaskPriority) std.math.Order {
        return std.math.order(@intFromEnum(self), @intFromEnum(other));
    }
};

// 任务状态
pub const TaskState = enum(u8) {
    Pending,
    Running,
    Completed,
    Failed,
    Cancelled,
};

// 任务接口
pub const Task = struct {
    id: u64,
    priority: TaskPriority,
    state: std.atomic.Value(TaskState),
    execute_fn: *const fn (ctx: *anyopaque) anyerror!void,
    context: *anyopaque,
    result: ?anyerror = null,
    created_at: i64,
    started_at: ?i64 = null,
    completed_at: ?i64 = null,
    
    pub fn init(id: u64, priority: TaskPriority, execute_fn: *const fn (ctx: *anyopaque) anyerror!void, context: *anyopaque) Task {
        return Task{
            .id = id,
            .priority = priority,
            .state = std.atomic.Value(TaskState).init(.Pending),
            .execute_fn = execute_fn,
            .context = context,
            .created_at = std.time.milliTimestamp(),
        };
    }
    
    pub fn execute(self: *Task) void {
        self.state.store(.Running, .release);
        self.started_at = std.time.milliTimestamp();
        
        if (self.execute_fn(self.context)) {
            self.result = null;
            self.state.store(.Completed, .release);
        } else |err| {
            self.result = err;
            self.state.store(.Failed, .release);
        }
        
        self.completed_at = std.time.milliTimestamp();
    }
    
    pub fn cancel(self: *Task) bool {
        const current_state = self.state.load(.acquire);
        if (current_state == .Pending) {
            self.state.store(.Cancelled, .release);
            return true;
        }
        return false;
    }
    
    pub fn getState(self: *const Task) TaskState {
        return self.state.load(.acquire);
    }
    
    pub fn isCompleted(self: *const Task) bool {
        const state = self.getState();
        return state == .Completed or state == .Failed or state == .Cancelled;
    }
    
    pub fn getExecutionTime(self: *const Task) ?i64 {
        if (self.started_at != null and self.completed_at != null) {
            return self.completed_at.? - self.started_at.?;
        }
        return null;
    }
};

// 工作队列
const WorkQueue = struct {
    tasks: std.ArrayList(*Task),
    mutex: Mutex,
    condition: Condition,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) WorkQueue {
        return WorkQueue{
            .tasks = std.ArrayList(*Task).init(allocator),
            .mutex = Mutex{},
            .condition = Condition{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WorkQueue) void {
        self.tasks.deinit();
    }
    
    pub fn push(self: *WorkQueue, task: *Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 按优先级插入
        var insert_index: usize = 0;
        for (self.tasks.items, 0..) |existing_task, i| {
            if (task.priority.compare(existing_task.priority) == .gt) {
                insert_index = i;
                break;
            }
            insert_index = i + 1;
        }
        
        try self.tasks.insert(insert_index, task);
        self.condition.signal();
    }
    
    pub fn pop(self: *WorkQueue) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.tasks.items.len > 0) {
            return self.tasks.orderedRemove(0);
        }
        return null;
    }
    
    pub fn popWait(self: *WorkQueue, timeout_ms: ?u64) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (timeout_ms) |timeout| {
            const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout));
            while (self.tasks.items.len == 0) {
                const now = std.time.milliTimestamp();
                if (now >= deadline) {
                    return null;
                }
                self.condition.timedWait(&self.mutex, @as(u64, @intCast(deadline - now)) * std.time.ns_per_ms) catch return null;
            }
        } else {
            while (self.tasks.items.len == 0) {
                self.condition.wait(&self.mutex);
            }
        }
        
        return self.tasks.orderedRemove(0);
    }
    
    pub fn size(self: *WorkQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.items.len;
    }
    
    pub fn clear(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tasks.clearRetainingCapacity();
    }
};

// 工作线程
const WorkerThread = struct {
    id: u32,
    thread: ?Thread,
    pool: *ThreadPool,
    local_queue: WorkQueue,
    is_running: std.atomic.Value(bool),
    tasks_executed: std.atomic.Value(u64),
    
    pub fn init(id: u32, pool: *ThreadPool, allocator: Allocator) WorkerThread {
        return WorkerThread{
            .id = id,
            .thread = null,
            .pool = pool,
            .local_queue = WorkQueue.init(allocator),
            .is_running = std.atomic.Value(bool).init(false),
        .tasks_executed = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn deinit(self: *WorkerThread) void {
        self.local_queue.deinit();
    }
    
    pub fn start(self: *WorkerThread) !void {
        self.is_running.store(true, .release);
        self.thread = try Thread.spawn(.{}, workerLoop, .{self});
    }
    
    pub fn stop(self: *WorkerThread) void {
        self.is_running.store(false, .release);
        self.local_queue.condition.signal();
    }
    
    pub fn join(self: *WorkerThread) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
    
    fn workerLoop(self: *WorkerThread) void {
        while (self.is_running.load(.acquire)) {
            // 1. 尝试从本地队列获取任务
            var task = self.local_queue.pop();
            
            // 2. 如果本地队列为空，尝试从全局队列获取
            if (task == null) {
                task = self.pool.global_queue.pop();
            }
            
            // 3. 如果还是没有任务，尝试工作窃取
            if (task == null) {
                task = self.stealWork();
            }
            
            // 4. 如果仍然没有任务，等待
            if (task == null) {
                task = self.pool.global_queue.popWait(100); // 100ms超时
                if (task == null) continue;
            }
            
            // 5. 执行任务
            if (task) |t| {
                t.execute();
                _ = self.tasks_executed.fetchAdd(1, .release);
                _ = self.pool.stats.tasks_completed.fetchAdd(1, .release);
            }
        }
    }
    
    fn stealWork(self: *WorkerThread) ?*Task {
        // 简单的工作窃取：从其他线程的本地队列偷取任务
        for (self.pool.workers.items) |*worker| {
            if (worker.id != self.id) {
                if (worker.local_queue.pop()) |task| {
                    _ = self.pool.stats.tasks_stolen.fetchAdd(1, .release);
                    return task;
                }
            }
        }
        return null;
    }
};

// 线程池配置
pub const ThreadPoolConfig = struct {
    core_threads: u32,
    max_threads: u32,
    keep_alive_ms: u64,
    queue_capacity: usize,
    enable_work_stealing: bool,
    thread_name_prefix: []const u8,
    
    pub fn default() ThreadPoolConfig {
        const cpu_count = @max(1, Thread.getCpuCount() catch 4);
        return ThreadPoolConfig{
            .core_threads = @intCast(cpu_count),
            .max_threads = @intCast(cpu_count * 2),
            .keep_alive_ms = 60000, // 1分钟
            .queue_capacity = 1000,
            .enable_work_stealing = true,
            .thread_name_prefix = "ThreadPool-Worker",
        };
    }
    
    pub fn fixed(thread_count: u32) ThreadPoolConfig {
        return ThreadPoolConfig{
            .core_threads = thread_count,
            .max_threads = thread_count,
            .keep_alive_ms = 0,
            .queue_capacity = 1000,
            .enable_work_stealing = true,
            .thread_name_prefix = "FixedThreadPool-Worker",
        };
    }
    
    pub fn single() ThreadPoolConfig {
        return ThreadPoolConfig{
            .core_threads = 1,
            .max_threads = 1,
            .keep_alive_ms = 0,
            .queue_capacity = 1000,
            .enable_work_stealing = false,
            .thread_name_prefix = "SingleThreadPool-Worker",
        };
    }
};

// 线程池统计信息
pub const ThreadPoolStats = struct {
    tasks_submitted: std.atomic.Value(u64),
    tasks_completed: std.atomic.Value(u64),
    tasks_failed: std.atomic.Value(u64),
    tasks_cancelled: std.atomic.Value(u64),
    tasks_stolen: std.atomic.Value(u64),
    active_threads: std.atomic.Value(u32),
    peak_threads: std.atomic.Value(u32),
    total_execution_time_ms: std.atomic.Value(u64),
    
    pub fn init() ThreadPoolStats {
        return ThreadPoolStats{
            .tasks_submitted = std.atomic.Value(u64).init(0),
        .tasks_completed = std.atomic.Value(u64).init(0),
        .tasks_failed = std.atomic.Value(u64).init(0),
        .tasks_cancelled = std.atomic.Value(u64).init(0),
        .tasks_stolen = std.atomic.Value(u64).init(0),
        .active_threads = std.atomic.Value(u32).init(0),
        .peak_threads = std.atomic.Value(u32).init(0),
        .total_execution_time_ms = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn getCompletionRate(self: *const ThreadPoolStats) f64 {
        const submitted = self.tasks_submitted.load(.acquire);
        if (submitted == 0) return 0.0;
        const completed = self.tasks_completed.load(.acquire);
        return @as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(submitted));
    }
    
    pub fn getFailureRate(self: *const ThreadPoolStats) f64 {
        const completed = self.tasks_completed.load(.acquire);
        if (completed == 0) return 0.0;
        const failed = self.tasks_failed.load(.acquire);
        return @as(f64, @floatFromInt(failed)) / @as(f64, @floatFromInt(completed));
    }
    
    pub fn getAverageExecutionTime(self: *const ThreadPoolStats) f64 {
        const completed = self.tasks_completed.load(.acquire);
        if (completed == 0) return 0.0;
        const total_time = self.total_execution_time_ms.load(.acquire);
        return @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(completed));
    }
};

// 主线程池结构
pub const ThreadPool = struct {
    const Self = @This();
    
    allocator: Allocator,
    config: ThreadPoolConfig,
    workers: std.ArrayList(WorkerThread),
    global_queue: WorkQueue,
    stats: ThreadPoolStats,
    next_task_id: std.atomic.Value(u64),
    is_shutdown: std.atomic.Value(bool),
    shutdown_mutex: Mutex,
    shutdown_condition: Condition,
    
    pub fn init(allocator: Allocator, config: ThreadPoolConfig) !*Self {
        if (config.core_threads == 0 or config.max_threads == 0 or config.core_threads > config.max_threads) {
            return ThreadPoolError.InvalidThreadCount;
        }
        
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.* = Self{
            .allocator = allocator,
            .config = config,
            .workers = std.ArrayList(WorkerThread).init(allocator),
            .global_queue = WorkQueue.init(allocator),
            .stats = ThreadPoolStats.init(),
            .next_task_id = std.atomic.Value(u64).init(1),
        .is_shutdown = std.atomic.Value(bool).init(false),
            .shutdown_mutex = Mutex{},
            .shutdown_condition = Condition{},
        };
        
        // 创建核心线程
        try self.workers.ensureTotalCapacity(config.max_threads);
        for (0..config.core_threads) |i| {
            var worker = WorkerThread.init(@intCast(i), self, allocator);
            try worker.start();
            try self.workers.append(worker);
        }
        
        self.stats.active_threads.store(config.core_threads, .release);
        self.stats.peak_threads.store(config.core_threads, .release);
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.shutdown();
        _ = self.awaitTermination(null);
        
        for (self.workers.items) |*worker| {
            worker.deinit();
        }
        self.workers.deinit();
        self.global_queue.deinit();
        self.allocator.destroy(self);
    }
    
    // 提交任务
    pub fn submit(self: *Self, priority: TaskPriority, execute_fn: *const fn (ctx: *anyopaque) anyerror!void, context: *anyopaque) !*Task {
        if (self.is_shutdown.load(.acquire)) {
            return ThreadPoolError.PoolShutdown;
        }
        
        const task_id = self.next_task_id.fetchAdd(1, .release);
        const task = try self.allocator.create(Task);
        task.* = Task.init(task_id, priority, execute_fn, context);
        
        // 尝试提交到工作线程的本地队列
        if (self.config.enable_work_stealing and self.workers.items.len > 0) {
            // 简单的负载均衡：选择任务最少的工作线程
            var min_tasks: usize = std.math.maxInt(usize);
            var target_worker: ?*WorkerThread = null;
            
            for (self.workers.items) |*worker| {
                const queue_size = worker.local_queue.size();
                if (queue_size < min_tasks) {
                    min_tasks = queue_size;
                    target_worker = worker;
                }
            }
            
            if (target_worker) |worker| {
                worker.local_queue.push(task) catch {
                    // 如果本地队列满了，回退到全局队列
                    try self.global_queue.push(task);
                };
            } else {
                try self.global_queue.push(task);
            }
        } else {
            try self.global_queue.push(task);
        }
        
        _ = self.stats.tasks_submitted.fetchAdd(1, .release);
        return task;
    }
    
    // 便利方法：提交普通优先级任务
    pub fn execute(self: *Self, execute_fn: *const fn (ctx: *anyopaque) anyerror!void, context: *anyopaque) !*Task {
        return self.submit(.Normal, execute_fn, context);
    }
    
    // 便利方法：提交高优先级任务
    pub fn executeHigh(self: *Self, execute_fn: *const fn (ctx: *anyopaque) anyerror!void, context: *anyopaque) !*Task {
        return self.submit(.High, execute_fn, context);
    }
    
    // 获取活跃线程数
    pub fn getActiveThreadCount(self: *Self) u32 {
        return self.stats.active_threads.load(.acquire);
    }
    
    // 获取队列大小
    pub fn getQueueSize(self: *Self) usize {
        var total_size = self.global_queue.size();
        for (self.workers.items) |*worker| {
            total_size += worker.local_queue.size();
        }
        return total_size;
    }
    
    // 获取统计信息
    pub fn getStats(self: *Self) ThreadPoolStats {
        return self.stats;
    }
    
    // 重置统计信息
    pub fn resetStats(self: *Self) void {
        self.stats = ThreadPoolStats.init();
    }
    
    // 关闭线程池
    pub fn shutdown(self: *Self) void {
        self.is_shutdown.store(true, .release);
        
        // 停止所有工作线程
        for (self.workers.items) |*worker| {
            worker.stop();
        }
        
        // 唤醒等待的线程
        self.global_queue.condition.broadcast();
        self.shutdown_condition.broadcast();
    }
    
    // 等待线程池终止
    pub fn awaitTermination(self: *Self, timeout_ms: ?u64) bool {
        const start_time = std.time.milliTimestamp();
        
        for (self.workers.items) |*worker| {
            if (timeout_ms) |timeout| {
                const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
                if (elapsed >= timeout) {
                    return false;
                }
            }
            worker.join();
        }
        
        return true;
    }
    
    // 检查是否已关闭
    pub fn isShutdown(self: *Self) bool {
        return self.is_shutdown.load(.acquire);
    }
    
    // 检查是否已终止
    pub fn isTerminated(self: *Self) bool {
        if (!self.isShutdown()) return false;
        
        for (self.workers.items) |*worker| {
            if (worker.is_running.load(.acquire)) {
                return false;
            }
        }
        return true;
    }
};

// 工厂函数
pub fn createThreadPool(allocator: Allocator, config: ThreadPoolConfig) !*ThreadPool {
    return ThreadPool.init(allocator, config);
}

pub fn createFixedThreadPool(allocator: Allocator, thread_count: u32) !*ThreadPool {
    const config = ThreadPoolConfig.fixed(thread_count);
    return createThreadPool(allocator, config);
}

pub fn createSingleThreadPool(allocator: Allocator) !*ThreadPool {
    const config = ThreadPoolConfig.single();
    return createThreadPool(allocator, config);
}

pub fn createDefaultThreadPool(allocator: Allocator) !*ThreadPool {
    const config = ThreadPoolConfig.default();
    return createThreadPool(allocator, config);
}

// 测试辅助函数
fn testTask(ctx: *anyopaque) anyerror!void {
    const value: *u32 = @ptrCast(@alignCast(ctx));
    value.* += 1;
}

fn slowTask(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    std.time.sleep(10 * std.time.ns_per_ms); // 10ms
}

// 测试
// test "ThreadPool basic operations" {
    const allocator = testing.allocator;
    const config = ThreadPoolConfig.fixed(2);
    
    const pool = try createThreadPool(allocator, config);
    defer pool.deinit();
    
    var counter: u32 = 0;
    const task = try pool.execute(testTask, &counter);
    
    // 等待任务完成
    while (!task.isCompleted()) {
        std.time.sleep(1 * std.time.ns_per_ms);
    }
    
    try testing.expect(counter == 1);
    try testing.expect(task.getState() == .Completed);
    
    allocator.destroy(task);
}

// test "ThreadPool multiple tasks" {
    const allocator = testing.allocator;
    const config = ThreadPoolConfig.fixed(4);
    
    const pool = try createThreadPool(allocator, config);
    defer pool.deinit();
    
    var counters = [_]u32{0} ** 10;
    var tasks = std.ArrayList(*Task).init(allocator);
    defer {
        for (tasks.items) |task| {
            allocator.destroy(task);
        }
        tasks.deinit();
    }
    
    // 提交多个任务
    for (counters[0..], 0..) |*counter, i| {
        const priority = if (i % 2 == 0) TaskPriority.High else TaskPriority.Normal;
        const task = try pool.submit(priority, testTask, counter);
        try tasks.append(task);
    }
    
    // 等待所有任务完成
    for (tasks.items) |task| {
        while (!task.isCompleted()) {
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }
    
    // 验证结果
    for (counters) |counter| {
        try testing.expect(counter == 1);
    }
    
    const stats = pool.getStats();
    try testing.expect(stats.tasks_submitted.load(.acquire) == 10);
    try testing.expect(stats.tasks_completed.load(.acquire) == 10);
}

// test "ThreadPool shutdown" {
    const allocator = testing.allocator;
    const config = ThreadPoolConfig.fixed(2);
    
    const pool = try createThreadPool(allocator, config);
    
    try testing.expect(!pool.isShutdown());
    try testing.expect(!pool.isTerminated());
    
    pool.shutdown();
    try testing.expect(pool.isShutdown());
    
    const terminated = pool.awaitTermination(1000); // 1秒超时
    try testing.expect(terminated);
    try testing.expect(pool.isTerminated());
    
    // 关闭后提交任务应该失败
    var counter: u32 = 0;
    try testing.expectError(ThreadPoolError.PoolShutdown, pool.execute(testTask, &counter));
    
    pool.deinit();
}

// test "Task priority" {
    const allocator = testing.allocator;
    const config = ThreadPoolConfig.single(); // 单线程确保顺序
    
    const pool = try createThreadPool(allocator, config);
    defer pool.deinit();
    
    var counters = [_]u32{0} ** 4;
    
    // 提交不同优先级的任务
    _ = try pool.submit(.Low, testTask, &counters[0]);
    _ = try pool.submit(.Critical, testTask, &counters[1]);
    _ = try pool.submit(.Normal, testTask, &counters[2]);
    _ = try pool.submit(.High, testTask, &counters[3]);
    
    // 等待一段时间让任务执行
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // 验证所有任务都执行了
    for (counters) |counter| {
        try testing.expect(counter == 1);
    }
}

// test "ThreadPoolStats" {
    var stats = ThreadPoolStats.init();
    
    _ = stats.tasks_submitted.fetchAdd(100, .release);
    _ = stats.tasks_completed.fetchAdd(90, .release);
    _ = stats.tasks_failed.fetchAdd(5, .release);
    _ = stats.total_execution_time_ms.fetchAdd(1000, .release);
    
    try testing.expect(stats.getCompletionRate() == 0.9);
    try testing.expect(stats.getFailureRate() == 5.0 / 90.0);
    try testing.expect(stats.getAverageExecutionTime() == 1000.0 / 90.0);
}