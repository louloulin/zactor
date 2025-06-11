const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const zactor = @import("zactor.zig");
const Actor = @import("actor.zig").Actor;

// Work-stealing scheduler for high-performance actor execution
pub const Scheduler = struct {
    const Self = @This();

    // Work queue for each thread
    const WorkQueue = struct {
        queue: std.ArrayList(*Actor),
        mutex: Thread.Mutex,
        condition: Thread.Condition,

        fn init(allocator: Allocator) WorkQueue {
            return WorkQueue{
                .queue = std.ArrayList(*Actor).init(allocator),
                .mutex = Thread.Mutex{},
                .condition = Thread.Condition{},
            };
        }

        fn deinit(self: *WorkQueue) void {
            self.queue.deinit();
        }

        fn push(self: *WorkQueue, actor: *Actor) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.queue.append(actor);
            self.condition.signal();
        }

        fn pop(self: *WorkQueue) ?*Actor {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.items.len > 0) {
                return self.queue.pop();
            }
            return null;
        }

        fn steal(self: *WorkQueue) ?*Actor {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.items.len > 1) {
                // Steal from the front (FIFO for stealing)
                return self.queue.orderedRemove(0);
            }
            return null;
        }

        fn waitForWork(self: *WorkQueue) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.queue.items.len == 0) {
                self.condition.wait(&self.mutex);
            }
        }

        fn size(self: *WorkQueue) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.queue.items.len;
        }
    };

    // Worker thread context
    const WorkerContext = struct {
        id: u32,
        scheduler: *Scheduler,
        work_queue: WorkQueue,
        thread: ?Thread,
        running: std.atomic.Value(bool),

        fn init(id: u32, scheduler: *Scheduler, allocator: Allocator) WorkerContext {
            return WorkerContext{
                .id = id,
                .scheduler = scheduler,
                .work_queue = WorkQueue.init(allocator),
                .thread = null,
                .running = std.atomic.Value(bool).init(false),
            };
        }

        fn deinit(self: *WorkerContext) void {
            self.work_queue.deinit();
        }
    };

    allocator: Allocator,
    workers: []WorkerContext,
    num_threads: u32,
    running: std.atomic.Value(bool),
    round_robin_counter: std.atomic.Value(u32),

    pub fn init(allocator: Allocator, num_threads: u32) !Self {
        const actual_threads = if (num_threads == 0)
            @as(u32, @intCast(@max(1, std.Thread.getCpuCount() catch 4)))
        else
            num_threads;

        const workers = try allocator.alloc(WorkerContext, actual_threads);
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerContext.init(@intCast(i), undefined, allocator);
        }

        var scheduler = Self{
            .allocator = allocator,
            .workers = workers,
            .num_threads = actual_threads,
            .running = std.atomic.Value(bool).init(false),
            .round_robin_counter = std.atomic.Value(u32).init(0),
        };

        // Set scheduler reference in workers
        for (workers) |*worker| {
            worker.scheduler = &scheduler;
        }

        return scheduler;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        for (self.workers) |*worker| {
            worker.deinit();
        }
        self.allocator.free(self.workers);
    }

    pub fn start(self: *Self) !void {
        if (self.running.swap(true, .acq_rel)) {
            return; // Already running
        }

        // Start worker threads
        for (self.workers) |*worker| {
            worker.running.store(true, .release);
            worker.thread = try Thread.spawn(.{}, workerLoop, .{worker});
        }

        std.log.info("Scheduler started with {} worker threads", .{self.num_threads});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.swap(false, .acq_rel)) {
            return; // Already stopped
        }

        // Signal all workers to stop
        for (self.workers) |*worker| {
            worker.running.store(false, .release);
            worker.work_queue.condition.signal();
        }

        // Wait for all threads to finish
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }

        std.log.info("Scheduler stopped");
    }

    // Schedule an actor for execution
    pub fn schedule(self: *Self, actor: *Actor) !void {
        if (!self.running.load(.acquire)) {
            return zactor.ActorError.SystemShutdown;
        }

        // Round-robin assignment to workers
        const worker_id = self.round_robin_counter.fetchAdd(1, .monotonic) % self.num_threads;
        try self.workers[worker_id].work_queue.push(actor);
    }

    // Get scheduler statistics
    pub fn getStats(self: *Self) SchedulerStats {
        var total_queued: u64 = 0;
        var worker_stats = self.allocator.alloc(u32, self.num_threads) catch return SchedulerStats{
            .total_queued_actors = 0,
            .worker_queue_sizes = &[_]u32{},
            .active_workers = 0,
        };

        var active_workers: u32 = 0;
        for (self.workers, 0..) |*worker, i| {
            const queue_size = @as(u32, @intCast(worker.work_queue.size()));
            worker_stats[i] = queue_size;
            total_queued += queue_size;

            if (worker.running.load(.acquire)) {
                active_workers += 1;
            }
        }

        return SchedulerStats{
            .total_queued_actors = total_queued,
            .worker_queue_sizes = worker_stats,
            .active_workers = active_workers,
        };
    }

    fn workerLoop(worker: *WorkerContext) void {
        std.log.info("Worker {} started", .{worker.id});

        while (worker.running.load(.acquire)) {
            // Try to get work from own queue first
            var actor = worker.work_queue.pop();

            // If no work, try to steal from other workers
            if (actor == null and zactor.config.enable_work_stealing) {
                actor = worker.tryStealWork();
            }

            if (actor) |a| {
                // Process messages for this actor
                worker.processActor(a);
            } else {
                // No work available, wait for new work
                worker.work_queue.waitForWork();
            }
        }

        std.log.info("Worker {} stopped", .{worker.id});
    }

    fn tryStealWork(self: *WorkerContext) ?*Actor {
        // Try to steal from other workers (excluding self)
        for (self.scheduler.workers) |*other_worker| {
            if (other_worker.id == self.id) continue;

            if (other_worker.work_queue.steal()) |stolen_actor| {
                return stolen_actor;
            }
        }
        return null;
    }

    fn processActor(self: *WorkerContext, actor: *Actor) void {
        _ = self;

        const start_time = std.time.nanoTimestamp();
        var messages_processed: u32 = 0;
        const max_messages_per_run = 100; // Prevent actor starvation

        // Process messages until mailbox is empty or limit reached
        while (messages_processed < max_messages_per_run) {
            const processed = actor.processMessage() catch |err| {
                std.log.err("Actor {} failed to process message: {}", .{ actor.getId(), err });
                // Could implement supervision strategy here
                break;
            };

            if (!processed) break;
            messages_processed += 1;
        }

        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;

        // If actor still has messages, reschedule it
        if (!actor.mailbox.isEmpty() and actor.getState() == .running) {
            actor.context.system.scheduler.schedule(actor) catch |err| {
                std.log.err("Failed to reschedule actor {}: {}", .{ actor.getId(), err });
            };
        }

        // Log performance metrics for debugging
        if (messages_processed > 0) {
            const avg_latency_ns = duration_ns / messages_processed;
            if (avg_latency_ns > 1000000) { // > 1ms
                std.log.warn("Actor {} high latency: {}ns avg per message", .{ actor.getId(), avg_latency_ns });
            }
        }
    }
};

pub const SchedulerStats = struct {
    total_queued_actors: u64,
    worker_queue_sizes: []const u32,
    active_workers: u32,

    pub fn deinit(self: SchedulerStats, allocator: Allocator) void {
        allocator.free(self.worker_queue_sizes);
    }
};

test "scheduler creation and lifecycle" {
    const allocator = testing.allocator;

    var scheduler = try Scheduler.init(allocator, 2);
    defer scheduler.deinit();

    try testing.expect(scheduler.num_threads == 2);
    try testing.expect(!scheduler.running.load(.acquire));

    // Test start/stop
    try scheduler.start();
    try testing.expect(scheduler.running.load(.acquire));

    // Give threads time to start
    std.time.sleep(10 * std.time.ns_per_ms);

    scheduler.stop();
    try testing.expect(!scheduler.running.load(.acquire));
}

test "scheduler stats" {
    const allocator = testing.allocator;

    var scheduler = try Scheduler.init(allocator, 2);
    defer scheduler.deinit();

    const stats = scheduler.getStats();
    defer stats.deinit(allocator);

    try testing.expect(stats.worker_queue_sizes.len == 2);
    try testing.expect(stats.total_queued_actors == 0);
    try testing.expect(stats.active_workers == 0);
}
