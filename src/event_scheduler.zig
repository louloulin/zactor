const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const zactor = @import("zactor.zig");
const Actor = @import("actor.zig").Actor;

// Event-driven scheduler that reschedules actors when they receive messages
pub const EventScheduler = struct {
    const Self = @This();

    // Actor queue with condition variable for event-driven scheduling
    const ActorQueue = struct {
        queue: std.ArrayList(*Actor),
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        allocator: Allocator,

        fn init(allocator: Allocator) ActorQueue {
            return ActorQueue{
                .queue = std.ArrayList(*Actor).init(allocator),
                .mutex = std.Thread.Mutex{},
                .condition = std.Thread.Condition{},
                .allocator = allocator,
            };
        }

        fn deinit(self: *ActorQueue) void {
            self.queue.deinit();
        }

        fn push(self: *ActorQueue, actor: *Actor) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Check if actor is already in queue to avoid duplicates
            for (self.queue.items) |queued_actor| {
                if (queued_actor.getId() == actor.getId()) {
                    return; // Actor already queued
                }
            }

            try self.queue.append(actor);
            self.condition.signal();
        }

        fn pop(self: *ActorQueue) ?*Actor {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.items.len > 0) {
                return self.queue.pop();
            }
            return null;
        }

        fn waitForWork(self: *ActorQueue) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.queue.items.len == 0) {
                self.condition.wait(&self.mutex);
            }
        }

        fn size(self: *ActorQueue) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.queue.items.len;
        }
    };

    // Worker thread context
    const WorkerContext = struct {
        id: u32,
        scheduler: *EventScheduler,
        thread: ?Thread,
        running: std.atomic.Value(bool),

        fn init(id: u32, scheduler: *EventScheduler) WorkerContext {
            return WorkerContext{
                .id = id,
                .scheduler = scheduler,
                .thread = null,
                .running = std.atomic.Value(bool).init(false),
            };
        }
    };

    allocator: Allocator,
    workers: []WorkerContext,
    num_threads: u32,
    running: std.atomic.Value(bool),
    actor_queue: ActorQueue,

    pub fn init(allocator: Allocator, num_threads: u32) !Self {
        const actual_threads = if (num_threads == 0)
            @as(u32, @intCast(@max(1, std.Thread.getCpuCount() catch 4)))
        else
            num_threads;

        const workers = try allocator.alloc(WorkerContext, actual_threads);
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerContext.init(@intCast(i), undefined);
        }

        var scheduler = Self{
            .allocator = allocator,
            .workers = workers,
            .num_threads = actual_threads,
            .running = std.atomic.Value(bool).init(false),
            .actor_queue = ActorQueue.init(allocator),
        };

        // Set scheduler reference in workers
        for (workers) |*worker| {
            worker.scheduler = &scheduler;
        }

        return scheduler;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.actor_queue.deinit();
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

        std.log.info("EventScheduler started with {} worker threads", .{self.num_threads});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.swap(false, .acq_rel)) {
            return; // Already stopped
        }

        // Signal all workers to stop
        for (self.workers) |*worker| {
            worker.running.store(false, .release);
        }

        // Wake up all workers
        self.actor_queue.condition.broadcast();

        // Wait for all threads to finish
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }

        std.log.info("EventScheduler stopped", .{});
    }

    // Schedule an actor for execution
    pub fn schedule(self: *Self, actor: *Actor) !void {
        if (!self.running.load(.acquire)) {
            return zactor.ActorError.SystemShutdown;
        }

        std.log.info("Scheduling actor {} for execution", .{actor.getId()});
        try self.actor_queue.push(actor);
    }

    // Get scheduler statistics
    pub fn getStats(self: *Self) SchedulerStats {
        var active_workers: u32 = 0;
        for (self.workers) |*worker| {
            if (worker.running.load(.acquire)) {
                active_workers += 1;
            }
        }

        const queue_size = @as(u32, @intCast(self.actor_queue.size()));
        const worker_stats = self.allocator.alloc(u32, 1) catch return SchedulerStats{
            .total_queued_actors = 0,
            .worker_queue_sizes = &[_]u32{},
            .active_workers = 0,
        };
        worker_stats[0] = queue_size;

        return SchedulerStats{
            .total_queued_actors = queue_size,
            .worker_queue_sizes = worker_stats,
            .active_workers = active_workers,
        };
    }

    fn workerLoop(worker: *WorkerContext) void {
        std.log.info("EventWorker {} started", .{worker.id});

        while (worker.running.load(.acquire)) {
            // Try to get work from queue
            const actor = worker.scheduler.actor_queue.pop();

            if (actor) |a| {
                // Process messages for this actor
                processActor(worker, a);
            } else {
                // No work available, wait for new work
                worker.scheduler.actor_queue.waitForWork();
            }
        }

        std.log.info("EventWorker {} stopped", .{worker.id});
    }

    fn processActor(self: *WorkerContext, actor: *Actor) void {
        _ = self;

        const start_time = std.time.nanoTimestamp();
        var messages_processed: u32 = 0;
        const max_messages_per_run = 100; // Prevent actor starvation

        std.log.info("Processing actor {}", .{actor.getId()});

        // Process messages until mailbox is empty or limit reached
        while (messages_processed < max_messages_per_run) {
            const processed = actor.processMessage() catch |err| {
                std.log.err("Actor {} failed to process message: {}", .{ actor.getId(), err });
                break;
            };

            if (!processed) break;
            messages_processed += 1;
        }

        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;

        std.log.info("Actor {} processed {} messages", .{ actor.getId(), messages_processed });

        // If actor still has messages, reschedule it
        const actor_state = actor.getState();
        if (actor_state == .running) {
            const has_messages = !actor.mailbox.isEmpty();
            if (has_messages) {
                actor.context.system.scheduler.schedule(actor) catch |err| {
                    std.log.err("Failed to reschedule actor {}: {}", .{ actor.getId(), err });
                };
            }
        }

        // Log performance metrics for debugging
        if (messages_processed > 0) {
            const avg_latency_ns = @divTrunc(duration_ns, @as(i128, messages_processed));
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
