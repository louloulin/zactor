//! Work Stealing Scheduler - 工作窃取调度器
//! 实现高性能的工作窃取算法，用于Actor任务调度

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const AtomicValue = std.atomic.Value;
const ArrayList = std.ArrayList;

const SchedulerConfig = @import("mod.zig").SchedulerConfig;
const SchedulerError = @import("mod.zig").SchedulerError;
const Task = @import("mod.zig").Task;
const TaskPriority = @import("mod.zig").TaskPriority;

/// 工作窃取调度器
pub const WorkStealingScheduler = struct {
    const Self = @This();
    
    allocator: Allocator,
    config: SchedulerConfig,
    state: AtomicValue(SchedulerState),
    
    // 工作线程
    workers: []Worker,
    threads: []Thread,
    
    // 全局任务队列（用于负载均衡）
    global_queue: TaskQueue,
    
    // 统计信息
    stats: SchedulerStats,
    
    pub const SchedulerState = enum(u8) {
        stopped = 0,
        starting = 1,
        running = 2,
        stopping = 3,
    };
    
    /// 工作线程
    const Worker = struct {
        id: u32,
        scheduler: *WorkStealingScheduler,
        local_queue: TaskQueue,
        steal_attempts: AtomicValue(u64),
        tasks_executed: AtomicValue(u64),
        
        pub fn init(id: u32, scheduler: *WorkStealingScheduler, allocator: Allocator) !Worker {
            return Worker{
                .id = id,
                .scheduler = scheduler,
                .local_queue = try TaskQueue.init(allocator, scheduler.config.task_queue_capacity),
                .steal_attempts = AtomicValue(u64).init(0),
                .tasks_executed = AtomicValue(u64).init(0),
            };
        }
        
        pub fn deinit(self: *Worker) void {
            self.local_queue.deinit();
        }
        
        /// 工作线程主循环
        pub fn run(self: *Worker) void {
            while (self.scheduler.state.load(.monotonic) == .running) {
                // 1. 尝试从本地队列获取任务
                if (self.local_queue.pop()) |task| {
                    self.executeTask(task);
                    continue;
                }
                
                // 2. 尝试从全局队列获取任务
                if (self.scheduler.global_queue.pop()) |task| {
                    self.executeTask(task);
                    continue;
                }
                
                // 3. 尝试从其他工作线程窃取任务
                if (self.stealTask()) |task| {
                    self.executeTask(task);
                    continue;
                }
                
                // 4. 没有任务，短暂休眠
                if (self.scheduler.config.idle_sleep_ms > 0) {
                    std.time.sleep(self.scheduler.config.idle_sleep_ms * std.time.ns_per_ms);
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
        
        fn executeTask(self: *Worker, task: Task) void {
            const start_time = std.time.nanoTimestamp();
            
            // 执行任务
            task.execute() catch |err| {
                std.log.warn("Task execution failed: {}", .{err});
                _ = self.scheduler.stats.tasks_failed.fetchAdd(1, .monotonic);
            };
            
            const end_time = std.time.nanoTimestamp();
            const execution_time = @as(u64, @intCast(end_time - start_time));
            
            // 更新统计信息
            _ = self.tasks_executed.fetchAdd(1, .monotonic);
            _ = self.scheduler.stats.tasks_completed.fetchAdd(1, .monotonic);
            _ = self.scheduler.stats.total_execution_time_ns.fetchAdd(execution_time, .monotonic);
        }
        
        fn stealTask(self: *Worker) ?Task {
            if (!self.scheduler.config.enable_work_stealing) {
                return null;
            }
            
            var attempts: u32 = 0;
            while (attempts < self.scheduler.config.max_steal_attempts) {
                // 随机选择一个其他工作线程
                const target_id = std.crypto.random.intRangeAtMost(u32, 0, @as(u32, @intCast(self.scheduler.workers.len - 1)));
                if (target_id == self.id) {
                    attempts += 1;
                    continue;
                }
                
                // 尝试从目标工作线程窃取任务
                if (self.scheduler.workers[target_id].local_queue.steal()) |task| {
                    _ = self.steal_attempts.fetchAdd(1, .monotonic);
                    _ = self.scheduler.stats.steal_attempts.fetchAdd(1, .monotonic);
                    return task;
                }
                
                attempts += 1;
            }
            
            return null;
        }
    };
    
    /// 任务队列（支持工作窃取）
    const TaskQueue = struct {
        tasks: []Task,
        capacity: u32,
        head: AtomicValue(u32), // 消费者端
        tail: AtomicValue(u32), // 生产者端
        allocator: Allocator,
        
        pub fn init(allocator: Allocator, capacity: u32) !TaskQueue {
            const tasks = try allocator.alloc(Task, capacity);
            return TaskQueue{
                .tasks = tasks,
                .capacity = capacity,
                .head = AtomicValue(u32).init(0),
                .tail = AtomicValue(u32).init(0),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *TaskQueue) void {
            self.allocator.free(self.tasks);
        }
        
        /// 推入任务（生产者端）
        pub fn push(self: *TaskQueue, task: Task) bool {
            const tail = self.tail.load(.monotonic);
            const next_tail = (tail + 1) % self.capacity;
            
            if (next_tail == self.head.load(.acquire)) {
                return false; // 队列满
            }
            
            self.tasks[tail] = task;
            self.tail.store(next_tail, .release);
            return true;
        }
        
        /// 弹出任务（消费者端）
        pub fn pop(self: *TaskQueue) ?Task {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) {
                return null; // 队列空
            }
            
            const task = self.tasks[head];
            self.head.store((head + 1) % self.capacity, .release);
            return task;
        }
        
        /// 窃取任务（从尾部窃取）
        pub fn steal(self: *TaskQueue) ?Task {
            const tail = self.tail.load(.acquire);
            const head = self.head.load(.monotonic);
            
            if (head >= tail) {
                return null; // 队列空
            }
            
            const prev_tail = if (tail == 0) self.capacity - 1 else tail - 1;
            
            // 尝试原子性地减少尾部指针
            if (self.tail.compareAndSwap(tail, prev_tail, .acq_rel, .monotonic)) |_| {
                return null; // CAS失败，其他线程已经窃取了
            }
            
            return self.tasks[prev_tail];
        }
        
        pub fn size(self: *const TaskQueue) u32 {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.monotonic);
            if (tail >= head) {
                return tail - head;
            } else {
                return self.capacity - head + tail;
            }
        }
        
        pub fn isEmpty(self: *const TaskQueue) bool {
            return self.head.load(.monotonic) == self.tail.load(.monotonic);
        }
    };
    
    /// 调度器统计信息
    const SchedulerStats = struct {
        tasks_submitted: AtomicValue(u64),
        tasks_completed: AtomicValue(u64),
        tasks_failed: AtomicValue(u64),
        steal_attempts: AtomicValue(u64),
        total_execution_time_ns: AtomicValue(u64),
        
        pub fn init() SchedulerStats {
            return SchedulerStats{
                .tasks_submitted = AtomicValue(u64).init(0),
                .tasks_completed = AtomicValue(u64).init(0),
                .tasks_failed = AtomicValue(u64).init(0),
                .steal_attempts = AtomicValue(u64).init(0),
                .total_execution_time_ns = AtomicValue(u64).init(0),
            };
        }
        
        pub fn getAverageExecutionTime(self: *const SchedulerStats) f64 {
            const completed = self.tasks_completed.load(.monotonic);
            if (completed == 0) return 0.0;
            
            const total_time = self.total_execution_time_ns.load(.monotonic);
            return @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(completed));
        }
        
        pub fn getThroughput(self: *const SchedulerStats, window_ms: u64) f64 {
            const completed = self.tasks_completed.load(.monotonic);
            return @as(f64, @floatFromInt(completed * 1000)) / @as(f64, @floatFromInt(window_ms));
        }
    };
    
    pub fn init(config: SchedulerConfig, allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        // 初始化工作线程
        const workers = try allocator.alloc(Worker, config.worker_threads);
        errdefer allocator.free(workers);
        
        for (workers, 0..) |*worker, i| {
            worker.* = try Worker.init(@intCast(i), self, allocator);
        }
        
        // 初始化线程数组
        const threads = try allocator.alloc(Thread, config.worker_threads);
        errdefer allocator.free(threads);
        
        self.* = Self{
            .allocator = allocator,
            .config = config,
            .state = AtomicValue(SchedulerState).init(.stopped),
            .workers = workers,
            .threads = threads,
            .global_queue = try TaskQueue.init(allocator, config.task_queue_capacity),
            .stats = SchedulerStats.init(),
        };
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.stop() catch {};
        
        // 清理工作线程
        for (self.workers) |*worker| {
            worker.deinit();
        }
        self.allocator.free(self.workers);
        self.allocator.free(self.threads);
        
        // 清理全局队列
        self.global_queue.deinit();
        
        self.allocator.destroy(self);
    }
    
    pub fn start(self: *Self) !void {
        if (self.state.load(.monotonic) != .stopped) {
            return SchedulerError.SchedulerAlreadyStarted;
        }
        
        self.state.store(.starting, .monotonic);
        
        // 启动工作线程
        for (self.workers, 0..) |*worker, i| {
            self.threads[i] = try Thread.spawn(.{}, Worker.run, .{worker});
        }
        
        self.state.store(.running, .monotonic);
    }
    
    pub fn stop(self: *Self) !void {
        const current_state = self.state.load(.monotonic);
        if (current_state == .stopped or current_state == .stopping) {
            return;
        }
        
        self.state.store(.stopping, .monotonic);
        
        // 等待所有工作线程完成
        for (self.threads) |*thread| {
            thread.join();
        }
        
        self.state.store(.stopped, .monotonic);
    }
    
    pub fn submit(self: *Self, task: Task) !void {
        if (self.state.load(.monotonic) != .running) {
            return SchedulerError.SchedulerNotStarted;
        }
        
        _ = self.stats.tasks_submitted.fetchAdd(1, .monotonic);
        
        // 尝试将任务分配给负载最轻的工作线程
        var min_load_worker: ?*Worker = null;
        var min_load: u32 = std.math.maxInt(u32);
        
        for (self.workers) |*worker| {
            const load = worker.local_queue.size();
            if (load < min_load) {
                min_load = load;
                min_load_worker = worker;
            }
        }
        
        if (min_load_worker) |worker| {
            if (worker.local_queue.push(task)) {
                return;
            }
        }
        
        // 如果本地队列都满了，尝试全局队列
        if (!self.global_queue.push(task)) {
            return SchedulerError.QueueFull;
        }
    }
    
    pub fn getState(self: *const Self) SchedulerState {
        return self.state.load(.monotonic);
    }
    
    pub fn getStats(self: *const Self) SchedulerStats {
        return self.stats;
    }
};
