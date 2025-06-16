//! Scheduler Module - 调度器模块
//! 提供高性能的Actor调度和任务分发机制

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const AtomicValue = std.atomic.Value;

// 重新导出调度器组件
// TODO: 待实现的调度器模块
// pub const Scheduler = @import("scheduler.zig").Scheduler;
// pub const WorkStealingScheduler = @import("work_stealing.zig").WorkStealingScheduler;
// pub const ThreadPoolScheduler = @import("thread_pool.zig").ThreadPoolScheduler;
// pub const FiberScheduler = @import("fiber.zig").FiberScheduler;
// pub const Dispatcher = @import("dispatcher.zig").Dispatcher;
// pub const TaskQueue = @import("task_queue.zig").TaskQueue;

// 调度器相关错误
pub const SchedulerError = error{
    SchedulerNotStarted,
    SchedulerAlreadyStarted,
    SchedulerShutdown,
    TaskQueueFull,
    WorkerThreadFailed,
    InvalidSchedulerConfig,
    ResourceExhausted,
    TaskExecutionFailed,
};

// 调度策略
pub const SchedulingStrategy = enum {
    round_robin,
    work_stealing,
    priority_based,
    locality_aware,
    adaptive,
    fair_share,
};

// 任务优先级
pub const TaskPriority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    critical = 3,
    
    pub fn compare(self: TaskPriority, other: TaskPriority) std.math.Order {
        return std.math.order(@intFromEnum(self), @intFromEnum(other));
    }
};

// 调度器配置
pub const SchedulerConfig = struct {
    strategy: SchedulingStrategy = .work_stealing,
    worker_threads: u32 = 0, // 0 = auto-detect CPU cores
    task_queue_capacity: u32 = 65536,
    enable_work_stealing: bool = true,
    enable_priority_scheduling: bool = true,
    enable_affinity: bool = false,
    max_steal_attempts: u32 = 3,
    idle_sleep_ms: u64 = 1,
    shutdown_timeout_ms: u64 = 5000,
    enable_metrics: bool = true,
    
    pub fn autoDetect() SchedulerConfig {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        return SchedulerConfig{
            .worker_threads = @intCast(cpu_count),
        };
    }
    
    pub fn forHighThroughput() SchedulerConfig {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        return SchedulerConfig{
            .strategy = .work_stealing,
            .worker_threads = @intCast(cpu_count * 2),
            .task_queue_capacity = 131072,
            .enable_work_stealing = true,
            .max_steal_attempts = 5,
            .idle_sleep_ms = 0,
        };
    }
    
    pub fn forLowLatency() SchedulerConfig {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        return SchedulerConfig{
            .strategy = .priority_based,
            .worker_threads = @intCast(cpu_count),
            .task_queue_capacity = 32768,
            .enable_priority_scheduling = true,
            .enable_affinity = true,
            .idle_sleep_ms = 0,
        };
    }
};

// 任务接口
pub const Task = struct {
    const Self = @This();
    
    // 虚函数表
    vtable: *const VTable,
    priority: TaskPriority = .normal,
    created_at: i64,
    scheduled_at: i64 = 0,
    executed_at: i64 = 0,
    
    pub const VTable = struct {
        execute: *const fn (self: *Task) anyerror!void,
        deinit: *const fn (self: *Task) void,
        getName: *const fn (self: *Task) []const u8,
    };
    
    pub fn init(vtable: *const VTable, priority: TaskPriority) Task {
        return Task{
            .vtable = vtable,
            .priority = priority,
            .created_at = std.time.nanoTimestamp(),
        };
    }
    
    pub fn execute(self: *Task) !void {
        self.executed_at = std.time.nanoTimestamp();
        try self.vtable.execute(self);
    }
    
    pub fn deinit(self: *Task) void {
        self.vtable.deinit(self);
    }
    
    pub fn getName(self: *Task) []const u8 {
        return self.vtable.getName(self);
    }
    
    pub fn getWaitTime(self: *const Task) i64 {
        if (self.executed_at == 0) {
            return std.time.nanoTimestamp() - self.created_at;
        }
        return self.executed_at - self.created_at;
    }
    
    pub fn getExecutionTime(self: *const Task) i64 {
        if (self.executed_at == 0) {
            return 0;
        }
        return std.time.nanoTimestamp() - self.executed_at;
    }
};

// 简单任务实现
pub fn SimpleTask(comptime Context: type) type {
    return struct {
        const Self = @This();
        
        task: Task,
        context: Context,
        execute_fn: *const fn (context: *Context) anyerror!void,
        name: []const u8,
        allocator: Allocator,
        
        const vtable = Task.VTable{
            .execute = execute,
            .deinit = deinitTask,
            .getName = getName,
        };
        
        pub fn init(
            allocator: Allocator,
            context: Context,
            execute_fn: *const fn (context: *Context) anyerror!void,
            name: []const u8,
            priority: TaskPriority,
        ) !*Self {
            const self = try allocator.create(Self);
            self.* = Self{
                .task = Task.init(&vtable, priority),
                .context = context,
                .execute_fn = execute_fn,
                .name = try allocator.dupe(u8, name),
                .allocator = allocator,
            };
            return self;
        }
        
        fn execute(task: *Task) !void {
            const self = @as(*Self, @fieldParentPtr("task", task));
            try self.execute_fn(&self.context);
        }
        
        fn deinitTask(task: *Task) void {
            const self = @as(*Self, @fieldParentPtr("task", task));
            self.allocator.free(self.name);
            self.allocator.destroy(self);
        }
        
        fn getName(task: *Task) []const u8 {
            const self = @as(*Self, @fieldParentPtr("task", task));
            return self.name;
        }
    };
}

// 调度器统计信息
pub const SchedulerStats = struct {
    tasks_submitted: AtomicValue(u64) = AtomicValue(u64).init(0),
    tasks_completed: AtomicValue(u64) = AtomicValue(u64).init(0),
    tasks_failed: AtomicValue(u64) = AtomicValue(u64).init(0),
    tasks_stolen: AtomicValue(u64) = AtomicValue(u64).init(0),
    total_execution_time_ns: AtomicValue(u64) = AtomicValue(u64).init(0),
    total_wait_time_ns: AtomicValue(u64) = AtomicValue(u64).init(0),
    active_workers: AtomicValue(u32) = AtomicValue(u32).init(0),
    idle_workers: AtomicValue(u32) = AtomicValue(u32).init(0),
    
    pub fn recordTaskSubmitted(self: *SchedulerStats) void {
        _ = self.tasks_submitted.fetchAdd(1, .monotonic);
    }
    
    pub fn recordTaskCompleted(self: *SchedulerStats, execution_time_ns: u64, wait_time_ns: u64) void {
        _ = self.tasks_completed.fetchAdd(1, .monotonic);
        _ = self.total_execution_time_ns.fetchAdd(execution_time_ns, .monotonic);
        _ = self.total_wait_time_ns.fetchAdd(wait_time_ns, .monotonic);
    }
    
    pub fn recordTaskFailed(self: *SchedulerStats) void {
        _ = self.tasks_failed.fetchAdd(1, .monotonic);
    }
    
    pub fn recordTaskStolen(self: *SchedulerStats) void {
        _ = self.tasks_stolen.fetchAdd(1, .monotonic);
    }
    
    pub fn recordWorkerActive(self: *SchedulerStats) void {
        _ = self.active_workers.fetchAdd(1, .monotonic);
        _ = self.idle_workers.fetchSub(1, .monotonic);
    }
    
    pub fn recordWorkerIdle(self: *SchedulerStats) void {
        _ = self.idle_workers.fetchAdd(1, .monotonic);
        _ = self.active_workers.fetchSub(1, .monotonic);
    }
    
    pub fn getThroughput(self: *const SchedulerStats, duration_ns: u64) f64 {
        const completed = self.tasks_completed.load(.monotonic);
        const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(completed)) / duration_s;
    }
    
    pub fn getAverageExecutionTime(self: *const SchedulerStats) f64 {
        const completed = self.tasks_completed.load(.monotonic);
        if (completed == 0) return 0.0;
        
        const total_time = self.total_execution_time_ns.load(.monotonic);
        return @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(completed));
    }
    
    pub fn getAverageWaitTime(self: *const SchedulerStats) f64 {
        const completed = self.tasks_completed.load(.monotonic);
        if (completed == 0) return 0.0;
        
        const total_time = self.total_wait_time_ns.load(.monotonic);
        return @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(completed));
    }
    
    pub fn getUtilization(self: *const SchedulerStats, total_workers: u32) f64 {
        const active = self.active_workers.load(.monotonic);
        return @as(f64, @floatFromInt(active)) / @as(f64, @floatFromInt(total_workers));
    }
    
    pub fn reset(self: *SchedulerStats) void {
        self.tasks_submitted.store(0, .monotonic);
        self.tasks_completed.store(0, .monotonic);
        self.tasks_failed.store(0, .monotonic);
        self.tasks_stolen.store(0, .monotonic);
        self.total_execution_time_ns.store(0, .monotonic);
        self.total_wait_time_ns.store(0, .monotonic);
    }
};

// 工作线程状态
pub const WorkerState = enum {
    idle,
    running,
    stealing,
    blocked,
    shutdown,
};

// 工作线程信息
pub const WorkerInfo = struct {
    id: u32,
    thread_id: Thread.Id,
    state: AtomicValue(WorkerState),
    tasks_processed: AtomicValue(u64),
    tasks_stolen: AtomicValue(u64),
    last_activity: AtomicValue(i64),
    
    pub fn init(id: u32, thread_id: Thread.Id) WorkerInfo {
        return WorkerInfo{
            .id = id,
            .thread_id = thread_id,
                .state = AtomicValue(WorkerState).init(.idle),
            .tasks_processed = AtomicValue(u64).init(0),
            .tasks_stolen = AtomicValue(u64).init(0),
            .last_activity = AtomicValue(i64).init(std.time.milliTimestamp()),
        };
    }
    
    pub fn setState(self: *WorkerInfo, state: WorkerState) void {
        self.state.store(state, .monotonic);
        self.last_activity.store(std.time.milliTimestamp(), .monotonic);
    }
    
    pub fn getState(self: *const WorkerInfo) WorkerState {
        return self.state.load(.monotonic);
    }
    
    pub fn recordTaskProcessed(self: *WorkerInfo) void {
        _ = self.tasks_processed.fetchAdd(1, .monotonic);
        self.last_activity.store(std.time.milliTimestamp(), .monotonic);
    }
    
    pub fn recordTaskStolen(self: *WorkerInfo) void {
        _ = self.tasks_stolen.fetchAdd(1, .monotonic);
        self.last_activity.store(std.time.milliTimestamp(), .monotonic);
    }
    
    pub fn getIdleTime(self: *const WorkerInfo) i64 {
        const now = std.time.milliTimestamp();
        const last = self.last_activity.load(.monotonic);
        return now - last;
    }
};

// 调度器接口
pub const SchedulerInterface = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        start: *const fn (self: *SchedulerInterface) SchedulerError!void,
        stop: *const fn (self: *SchedulerInterface) SchedulerError!void,
        submit: *const fn (self: *SchedulerInterface, task: *Task) SchedulerError!void,
        submitBatch: *const fn (self: *SchedulerInterface, tasks: []*Task) SchedulerError!u32,
        getStats: *const fn (self: *SchedulerInterface) *const SchedulerStats,
        getWorkerCount: *const fn (self: *SchedulerInterface) u32,
        isRunning: *const fn (self: *SchedulerInterface) bool,
    };
    
    pub fn start(self: *SchedulerInterface) !void {
        return self.vtable.start(self);
    }
    
    pub fn stop(self: *SchedulerInterface) !void {
        return self.vtable.stop(self);
    }
    
    pub fn submit(self: *SchedulerInterface, task: *Task) !void {
        return self.vtable.submit(self, task);
    }
    
    pub fn submitBatch(self: *SchedulerInterface, tasks: []*Task) !u32 {
        return self.vtable.submitBatch(self, tasks);
    }
    
    pub fn getStats(self: *SchedulerInterface) *const SchedulerStats {
        return self.vtable.getStats(self);
    }
    
    pub fn getWorkerCount(self: *SchedulerInterface) u32 {
        return self.vtable.getWorkerCount(self);
    }
    
    pub fn isRunning(self: *SchedulerInterface) bool {
        return self.vtable.isRunning(self);
    }
};

// 调度器工厂
pub const SchedulerFactory = struct {
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) SchedulerFactory {
        return SchedulerFactory{
            .allocator = allocator,
        };
    }
    
    pub fn createScheduler(self: *SchedulerFactory, config: SchedulerConfig) !*SchedulerInterface {
        _ = self;
        switch (config.strategy) {
            .work_stealing => {
                // TODO: WorkStealingScheduler未实现
                return error.NotImplemented;
            },
            .round_robin, .priority_based, .locality_aware, .adaptive, .fair_share => {
                // TODO: ThreadPoolScheduler未实现
                return error.NotImplemented;
            },
        }
    }
    
    pub fn destroyScheduler(self: *SchedulerFactory, scheduler: *SchedulerInterface) void {
        // 根据调度器类型进行适当的清理
        // 这里需要根据实际的调度器实现来确定如何正确释放内存
        _ = self;
        _ = scheduler;
    }
};

// 测试
test "TaskPriority comparison" {
    const testing = std.testing;
    
    try testing.expect(TaskPriority.low.compare(.normal) == .lt);
    try testing.expect(TaskPriority.normal.compare(.high) == .lt);
    try testing.expect(TaskPriority.high.compare(.critical) == .lt);
    try testing.expect(TaskPriority.critical.compare(.critical) == .eq);
}

test "SchedulerConfig presets" {
    const testing = std.testing;
    
    const auto_config = SchedulerConfig.autoDetect();
    try testing.expect(auto_config.worker_threads > 0);
    
    const high_throughput = SchedulerConfig.forHighThroughput();
    try testing.expect(high_throughput.strategy == .work_stealing);
    try testing.expect(high_throughput.enable_work_stealing);
    
    const low_latency = SchedulerConfig.forLowLatency();
    try testing.expect(low_latency.strategy == .priority_based);
    try testing.expect(low_latency.enable_priority_scheduling);
}

test "SchedulerStats operations" {
    const testing = std.testing;
    
    var stats = SchedulerStats{};
    
    stats.recordTaskSubmitted();
    try testing.expect(stats.tasks_submitted.load(.monotonic) == 1);
    
    stats.recordTaskCompleted(1000, 500);
    try testing.expect(stats.tasks_completed.load(.monotonic) == 1);
    try testing.expect(stats.total_execution_time_ns.load(.monotonic) == 1000);
    try testing.expect(stats.total_wait_time_ns.load(.monotonic) == 500);
    
    const avg_exec = stats.getAverageExecutionTime();
    try testing.expect(avg_exec == 1000.0);
    
    const avg_wait = stats.getAverageWaitTime();
    try testing.expect(avg_wait == 500.0);
}