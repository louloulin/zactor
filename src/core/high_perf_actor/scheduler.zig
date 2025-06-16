//! High-Performance Actor Scheduler
//! 基于工作窃取和批量处理的高性能调度器

const std = @import("std");
const Allocator = std.mem.Allocator;
const AtomicValue = std.atomic.Value;
const Thread = std.Thread;
const mod = @import("mod.zig");
const SPSCQueue = mod.SPSCQueue;
const PerformanceConfig = mod.PerformanceConfig;
const PerformanceStats = mod.PerformanceStats;

// 调度器状态
pub const SchedulerState = enum(u8) {
    stopped = 0,
    starting = 1,
    running = 2,
    stopping = 3,
};

// Actor任务 - 轻量级任务表示
pub const ActorTask = struct {
    actor_ptr: *anyopaque, // Actor指针
    process_fn: *const fn (*anyopaque) u32, // 处理函数
    priority: u8 = 0, // 优先级

    pub fn init(actor_ptr: *anyopaque, process_fn: *const fn (*anyopaque) u32) ActorTask {
        return ActorTask{
            .actor_ptr = actor_ptr,
            .process_fn = process_fn,
        };
    }

    pub fn execute(self: *const ActorTask) u32 {
        return self.process_fn(self.actor_ptr);
    }
};

// 工作线程
const Worker = struct {
    const Self = @This();
    const TaskQueue = SPSCQueue(ActorTask, 1024);

    id: u32,
    thread: ?Thread,
    scheduler: *Scheduler,

    // 任务队列
    local_queue: TaskQueue,

    // 统计信息
    tasks_processed: AtomicValue(u64),
    tasks_stolen: AtomicValue(u64),
    idle_cycles: AtomicValue(u64),

    // 运行状态
    running: AtomicValue(bool),

    pub fn init(id: u32, scheduler: *Scheduler) Self {
        return Self{
            .id = id,
            .thread = null,
            .scheduler = scheduler,
            .local_queue = TaskQueue.init(),
            .tasks_processed = AtomicValue(u64).init(0),
            .tasks_stolen = AtomicValue(u64).init(0),
            .idle_cycles = AtomicValue(u64).init(0),
            .running = AtomicValue(bool).init(false),
        };
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.thread = try Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn submit(self: *Self, task: ActorTask) bool {
        return self.local_queue.push(task);
    }

    pub fn steal(self: *Self) ?ActorTask {
        return self.local_queue.pop();
    }

    fn run(self: *Self) void {
        var spin_count: u32 = 0;
        const max_spin = self.scheduler.config.max_spin_cycles;

        while (self.running.load(.acquire)) {
            var processed_any = false;

            // 1. 处理本地队列任务
            if (self.processLocalTasks()) {
                processed_any = true;
                spin_count = 0;
            }

            // 2. 尝试从全局队列获取任务
            if (self.processGlobalTasks()) {
                processed_any = true;
                spin_count = 0;
            }

            // 3. 尝试工作窃取
            if (self.scheduler.config.enable_work_stealing and self.stealTasks()) {
                processed_any = true;
                spin_count = 0;
            }

            if (!processed_any) {
                spin_count += 1;
                _ = self.idle_cycles.fetchAdd(1, .monotonic);

                if (spin_count < max_spin) {
                    // 自旋等待
                    std.atomic.spinLoopHint();
                } else {
                    // 让出CPU
                    Thread.yield() catch {};
                    spin_count = 0;
                }
            }
        }
    }

    fn processLocalTasks(self: *Self) bool {
        var processed = false;
        var batch_count: u32 = 0;
        const max_batch = self.scheduler.config.batch_size;

        while (batch_count < max_batch) {
            if (self.local_queue.pop()) |task| {
                const messages_processed = task.execute();
                if (messages_processed > 0) {
                    _ = self.tasks_processed.fetchAdd(messages_processed, .monotonic);
                    processed = true;
                }
                batch_count += 1;
            } else {
                break;
            }
        }

        return processed;
    }

    fn processGlobalTasks(self: *Self) bool {
        if (self.scheduler.global_queue.pop()) |task| {
            const messages_processed = task.execute();
            if (messages_processed > 0) {
                _ = self.tasks_processed.fetchAdd(messages_processed, .monotonic);
                return true;
            }
        }
        return false;
    }

    fn stealTasks(self: *Self) bool {
        const worker_count = self.scheduler.workers.len;
        if (worker_count <= 1) return false;

        // 随机选择目标工作线程
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
        const target_id = rng.random().intRangeAtMost(u32, 0, @intCast(worker_count - 1));

        if (target_id == self.id) return false;

        if (self.scheduler.workers[target_id].steal()) |task| {
            const messages_processed = task.execute();
            if (messages_processed > 0) {
                _ = self.tasks_processed.fetchAdd(messages_processed, .monotonic);
                _ = self.tasks_stolen.fetchAdd(1, .monotonic);
                return true;
            }
        }

        return false;
    }

    pub fn getStats(self: *const Self) WorkerStats {
        return WorkerStats{
            .id = self.id,
            .tasks_processed = self.tasks_processed.load(.monotonic),
            .tasks_stolen = self.tasks_stolen.load(.monotonic),
            .idle_cycles = self.idle_cycles.load(.monotonic),
            .queue_size = self.local_queue.size(),
        };
    }
};

pub const WorkerStats = struct {
    id: u32,
    tasks_processed: u64,
    tasks_stolen: u64,
    idle_cycles: u64,
    queue_size: u32,

    pub fn print(self: *const WorkerStats) void {
        std.log.info("Worker {} Stats:", .{self.id});
        std.log.info("  Tasks processed: {}", .{self.tasks_processed});
        std.log.info("  Tasks stolen: {}", .{self.tasks_stolen});
        std.log.info("  Idle cycles: {}", .{self.idle_cycles});
        std.log.info("  Queue size: {}", .{self.queue_size});
    }
};

// 高性能调度器
pub const Scheduler = struct {
    const Self = @This();
    const GlobalQueue = SPSCQueue(ActorTask, 4096);

    // 配置
    config: PerformanceConfig,
    allocator: Allocator,

    // 状态
    state: AtomicValue(SchedulerState),

    // 工作线程
    workers: []Worker,

    // 全局队列
    global_queue: GlobalQueue,

    // 统计信息
    stats: PerformanceStats,
    start_time: i64,

    // 负载均衡
    next_worker: AtomicValue(u32),

    pub fn init(allocator: Allocator, config: PerformanceConfig) !*Self {
        const worker_count = if (config.worker_threads == 0)
            @max(1, std.Thread.getCpuCount() catch 4)
        else
            config.worker_threads;

        const scheduler = try allocator.create(Self);
        const workers = try allocator.alloc(Worker, worker_count);

        // 初始化工作线程
        for (workers, 0..) |*worker, i| {
            worker.* = Worker.init(@intCast(i), scheduler);
        }

        scheduler.* = Self{
            .config = config,
            .allocator = allocator,
            .state = AtomicValue(SchedulerState).init(.stopped),
            .workers = workers,
            .global_queue = GlobalQueue.init(),
            .stats = PerformanceStats{},
            .start_time = 0,
            .next_worker = AtomicValue(u32).init(0),
        };

        return scheduler;
    }

    pub fn deinit(self: *Self) void {
        self.stop() catch {};
        self.allocator.free(self.workers);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        const expected = SchedulerState.stopped;
        if (self.state.cmpxchgStrong(expected, .starting, .acq_rel, .monotonic)) |_| {
            return error.AlreadyStarted;
        }

        self.start_time = std.time.milliTimestamp();

        // 启动所有工作线程
        for (self.workers) |*worker| {
            try worker.start();
        }

        self.state.store(.running, .release);
        std.log.info("High-performance scheduler started with {} workers", .{self.workers.len});
    }

    pub fn stop(self: *Self) !void {
        const current_state = self.state.load(.acquire);
        if (current_state == .stopped or current_state == .stopping) {
            return;
        }

        self.state.store(.stopping, .release);

        // 停止所有工作线程
        for (self.workers) |*worker| {
            worker.stop();
        }

        self.state.store(.stopped, .release);
        std.log.info("High-performance scheduler stopped", .{});
    }

    pub fn submit(self: *Self, task: ActorTask) bool {
        if (self.state.load(.acquire) != .running) {
            return false;
        }

        // 负载均衡：轮询分配到工作线程
        const worker_id = self.next_worker.fetchAdd(1, .monotonic) % @as(u32, @intCast(self.workers.len));

        if (self.workers[worker_id].submit(task)) {
            return true;
        }

        // 如果工作线程队列满，尝试全局队列
        return self.global_queue.push(task);
    }

    pub fn getState(self: *const Self) SchedulerState {
        return self.state.load(.acquire);
    }

    pub fn isRunning(self: *const Self) bool {
        return self.getState() == .running;
    }

    pub fn getWorkerCount(self: *const Self) u32 {
        return @intCast(self.workers.len);
    }

    pub fn getStats(self: *const Self) SchedulerStats {
        var total_processed: u64 = 0;
        var total_stolen: u64 = 0;
        var total_idle: u64 = 0;

        for (self.workers) |*worker| {
            const worker_stats = worker.getStats();
            total_processed += worker_stats.tasks_processed;
            total_stolen += worker_stats.tasks_stolen;
            total_idle += worker_stats.idle_cycles;
        }

        const uptime = if (self.start_time > 0)
            std.time.milliTimestamp() - self.start_time
        else
            0;

        return SchedulerStats{
            .worker_count = self.getWorkerCount(),
            .total_tasks_processed = total_processed,
            .total_tasks_stolen = total_stolen,
            .total_idle_cycles = total_idle,
            .global_queue_size = self.global_queue.size(),
            .uptime_ms = uptime,
        };
    }

    pub fn printStats(self: *const Self) void {
        const stats = self.getStats();
        stats.print();

        std.log.info("\n=== Worker Details ===", .{});
        for (self.workers) |*worker| {
            const worker_stats = worker.getStats();
            worker_stats.print();
        }
    }
};

pub const SchedulerStats = struct {
    worker_count: u32,
    total_tasks_processed: u64,
    total_tasks_stolen: u64,
    total_idle_cycles: u64,
    global_queue_size: u32,
    uptime_ms: i64,

    pub fn getThroughput(self: *const SchedulerStats) f64 {
        if (self.uptime_ms == 0) return 0.0;
        const uptime_s = @as(f64, @floatFromInt(self.uptime_ms)) / 1000.0;
        return @as(f64, @floatFromInt(self.total_tasks_processed)) / uptime_s;
    }

    pub fn getStealRate(self: *const SchedulerStats) f64 {
        if (self.total_tasks_processed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_tasks_stolen)) / @as(f64, @floatFromInt(self.total_tasks_processed));
    }

    pub fn print(self: *const SchedulerStats) void {
        std.log.info("=== High-Performance Scheduler Stats ===", .{});
        std.log.info("Workers: {}", .{self.worker_count});
        std.log.info("Tasks processed: {}", .{self.total_tasks_processed});
        std.log.info("Tasks stolen: {}", .{self.total_tasks_stolen});
        std.log.info("Idle cycles: {}", .{self.total_idle_cycles});
        std.log.info("Global queue size: {}", .{self.global_queue_size});
        std.log.info("Uptime: {} ms", .{self.uptime_ms});
        std.log.info("Throughput: {d:.2} tasks/s", .{self.getThroughput()});
        std.log.info("Steal rate: {d:.2}%", .{self.getStealRate() * 100.0});
    }
};

// 测试
test "Scheduler creation and lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = PerformanceConfig{
        .worker_threads = 2,
        .batch_size = 32,
    };

    var scheduler = try Scheduler.init(allocator, config);
    defer scheduler.deinit();

    // 测试初始状态
    try testing.expect(scheduler.getState() == .stopped);
    try testing.expect(scheduler.getWorkerCount() == 2);

    // 测试启动
    try scheduler.start();
    try testing.expect(scheduler.isRunning());

    // 等待一小段时间
    std.time.sleep(10 * std.time.ns_per_ms);

    // 测试停止
    try scheduler.stop();
    try testing.expect(scheduler.getState() == .stopped);
}
