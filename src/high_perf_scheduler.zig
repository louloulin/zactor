const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const HighPerfActor = @import("high_perf_actor.zig").HighPerfActor;
const ProcessingState = @import("high_perf_actor.zig").ProcessingState;
const MPSCQueue = @import("lockfree_queue.zig").MPSCQueue;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;

// 高性能调度器 - 专为极限吞吐量设计
pub const HighPerfScheduler = struct {
    const Self = @This();
    const MAX_WORKERS = 32;
    const WORK_STEALING_THRESHOLD = 10;
    const BATCH_SCHEDULE_SIZE = 64;

    // 工作线程池
    workers: []Worker,
    worker_count: u32,

    // 调度队列
    global_queue: MPSCQueue(*HighPerfActor),
    high_priority_queue: MPSCQueue(*HighPerfActor),

    // 工作窃取队列
    local_queues: []LockFreeQueue(*HighPerfActor),

    // 控制和统计
    running: std.atomic.Value(bool),
    stats: SchedulerStats,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: SchedulerConfig) !*Self {
        const worker_count = @min(config.worker_threads, MAX_WORKERS);

        // 在堆上分配调度器
        const self = try allocator.create(Self);

        // 分配工作线程
        const workers = try allocator.alloc(Worker, worker_count);

        // 分配本地队列（每个工作线程一个）
        const local_queues = try allocator.alloc(LockFreeQueue(*HighPerfActor), worker_count);
        for (local_queues) |*queue| {
            queue.* = LockFreeQueue(*HighPerfActor).init();
        }

        self.* = Self{
            .workers = workers,
            .worker_count = worker_count,
            .global_queue = try MPSCQueue(*HighPerfActor).init(allocator),
            .high_priority_queue = try MPSCQueue(*HighPerfActor).init(allocator),
            .local_queues = local_queues,
            .running = std.atomic.Value(bool).init(true), // 初始化时就设置为true
            .stats = SchedulerStats.init(),
            .allocator = allocator,
        };

        // 初始化工作线程
        for (workers, 0..) |*worker, i| {
            worker.* = Worker.init(@intCast(i), self, config);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // 清理队列
        self.global_queue.deinit();
        self.high_priority_queue.deinit();

        // 清理本地队列
        const allocator = self.allocator;
        allocator.free(self.local_queues);
        allocator.free(self.workers);

        // 释放调度器本身
        allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        std.log.info("HighPerfScheduler started with {} workers", .{self.worker_count});

        // 启动所有工作线程
        for (self.workers) |*worker| {
            try worker.start();
        }

        // 等待所有Worker线程启动
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);

        // 停止所有工作线程
        for (self.workers) |*worker| {
            worker.stop();
        }

        std.log.info("HighPerfScheduler stopped", .{});
    }

    // 调度Actor（高优先级）
    pub fn scheduleHighPriority(self: *Self, actor: *HighPerfActor) !void {
        try self.high_priority_queue.push(actor);
        _ = self.stats.high_priority_scheduled.fetchAdd(1, .monotonic);
    }

    // 调度Actor（普通优先级）
    pub fn schedule(self: *Self, actor: *HighPerfActor) !void {
        // 尝试放入最空闲的本地队列
        var min_size: u32 = std.math.maxInt(u32);
        var best_queue_idx: u32 = 0;

        for (self.local_queues, 0..) |*queue, i| {
            const size = queue.size();
            if (size < min_size) {
                min_size = size;
                best_queue_idx = @intCast(i);
            }
        }

        // 如果本地队列太满，使用全局队列
        if (min_size > WORK_STEALING_THRESHOLD) {
            try self.global_queue.push(actor);
            _ = self.stats.global_scheduled.fetchAdd(1, .monotonic);
        } else {
            if (!self.local_queues[best_queue_idx].push(actor)) {
                // 本地队列满了，回退到全局队列
                try self.global_queue.push(actor);
                _ = self.stats.global_scheduled.fetchAdd(1, .monotonic);
            } else {
                _ = self.stats.local_scheduled.fetchAdd(1, .monotonic);
            }
        }
    }

    // 批量调度
    pub fn scheduleBatch(self: *Self, actors: []*HighPerfActor) !u32 {
        var scheduled: u32 = 0;

        for (actors) |actor| {
            self.schedule(actor) catch break;
            scheduled += 1;
        }

        _ = self.stats.batch_scheduled.fetchAdd(1, .monotonic);
        return scheduled;
    }

    pub fn getStats(self: *Self) SchedulerStats {
        var stats = self.stats;

        // 聚合工作线程统计
        for (self.workers) |*worker| {
            const worker_stats = worker.getStats();
            stats.total_processed += worker_stats.actors_processed.load(.monotonic);
            stats.total_work_stolen += worker_stats.work_stolen.load(.monotonic);
            stats.total_idle_cycles += worker_stats.idle_cycles.load(.monotonic);
        }

        return stats;
    }
};

// 工作线程
const Worker = struct {
    const Self = @This();
    const IDLE_SLEEP_US = 1; // 1微秒空闲睡眠
    const WORK_STEAL_ATTEMPTS = 3;

    id: u32,
    thread: ?Thread,
    scheduler: *HighPerfScheduler,
    config: SchedulerConfig,

    // 工作线程统计
    stats: WorkerStats,
    running: std.atomic.Value(bool),

    pub fn init(id: u32, scheduler: *HighPerfScheduler, config: SchedulerConfig) Self {
        return Self{
            .id = id,
            .thread = null,
            .scheduler = scheduler,
            .config = config,
            .stats = WorkerStats.init(),
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.thread = try Thread.spawn(.{}, workerLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn workerLoop(self: *Self) void {
        std.log.info("Worker {} started", .{self.id});

        // 等待调度器启动
        var wait_count: u32 = 0;
        while (!self.scheduler.running.load(.seq_cst)) {
            std.time.sleep(1 * std.time.ns_per_ms);
            wait_count += 1;
            if (wait_count > 100) {
                std.log.warn("Worker {} waiting too long for scheduler", .{self.id});
                break;
            }
        }

        std.log.info("Worker {} scheduler ready (waited {}ms), starting work loop", .{ self.id, wait_count });

        while (self.scheduler.running.load(.acquire) and self.running.load(.acquire)) {
            var processed_any = false;

            // 简化处理逻辑，只处理本地队列
            if (self.processFromLocalQueue()) {
                processed_any = true;
            }

            // 如果没有工作，短暂休眠
            if (!processed_any) {
                _ = self.stats.idle_cycles.fetchAdd(1, .monotonic);
                std.time.sleep(IDLE_SLEEP_US * std.time.ns_per_us);
            }
        }

        std.log.info("Worker {} stopped", .{self.id});
    }

    fn processFromQueue(self: *Self, queue: *MPSCQueue(*HighPerfActor)) bool {
        if (queue.pop()) |actor| {
            self.processActor(actor);
            return true;
        }
        return false;
    }

    fn processFromLocalQueue(self: *Self) bool {
        const local_queue = &self.scheduler.local_queues[self.id];
        if (local_queue.pop()) |actor| {
            std.log.info("Worker {} processing actor {}", .{ self.id, actor.id });
            self.processActor(actor);
            return true;
        }
        return false;
    }

    fn stealWork(self: *Self) bool {
        // 尝试从其他工作线程窃取工作
        for (0..WORK_STEAL_ATTEMPTS) |_| {
            // 随机选择一个其他工作线程
            const victim_id = (self.id + 1 + @as(u32, @intCast(std.crypto.random.int(u32)))) % self.scheduler.worker_count;
            if (victim_id == self.id) continue;

            const victim_queue = &self.scheduler.local_queues[victim_id];
            if (victim_queue.pop()) |actor| {
                self.processActor(actor);
                _ = self.stats.work_stolen.fetchAdd(1, .monotonic);
                return true;
            }
        }
        return false;
    }

    fn processActor(self: *Self, actor: *HighPerfActor) void {
        // 处理Actor的消息批次
        const processed = actor.processBatch();

        std.log.info("Worker {} processed {} messages from actor {}", .{ self.id, processed, actor.id });

        _ = self.stats.actors_processed.fetchAdd(1, .monotonic);
        _ = self.stats.messages_processed.fetchAdd(processed, .monotonic);

        // 如果Actor还有消息，重新调度
        if (!actor.mailbox.isEmpty()) {
            const state = actor.processing_state.load(.monotonic);
            if (state == .running or state == .processing) {
                self.scheduler.schedule(actor) catch {};
                std.log.info("Worker {} rescheduled actor {} (has more messages)", .{ self.id, actor.id });
            }
        }
    }

    pub fn getStats(self: *Self) WorkerStats {
        return self.stats;
    }
};

// 调度器配置
pub const SchedulerConfig = struct {
    worker_threads: u32 = 8,
    enable_work_stealing: bool = true,
    high_priority_ratio: f32 = 0.2, // 20%时间处理高优先级
};

// 调度器统计
pub const SchedulerStats = struct {
    high_priority_scheduled: std.atomic.Value(u64),
    global_scheduled: std.atomic.Value(u64),
    local_scheduled: std.atomic.Value(u64),
    batch_scheduled: std.atomic.Value(u64),

    // 聚合统计
    total_processed: u64,
    total_work_stolen: u64,
    total_idle_cycles: u64,

    pub fn init() SchedulerStats {
        return SchedulerStats{
            .high_priority_scheduled = std.atomic.Value(u64).init(0),
            .global_scheduled = std.atomic.Value(u64).init(0),
            .local_scheduled = std.atomic.Value(u64).init(0),
            .batch_scheduled = std.atomic.Value(u64).init(0),
            .total_processed = 0,
            .total_work_stolen = 0,
            .total_idle_cycles = 0,
        };
    }
};

// 工作线程统计
pub const WorkerStats = struct {
    actors_processed: std.atomic.Value(u64),
    messages_processed: std.atomic.Value(u64),
    work_stolen: std.atomic.Value(u64),
    idle_cycles: std.atomic.Value(u64),

    pub fn init() WorkerStats {
        return WorkerStats{
            .actors_processed = std.atomic.Value(u64).init(0),
            .messages_processed = std.atomic.Value(u64).init(0),
            .work_stolen = std.atomic.Value(u64).init(0),
            .idle_cycles = std.atomic.Value(u64).init(0),
        };
    }
};
