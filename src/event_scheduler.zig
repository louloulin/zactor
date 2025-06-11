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
        semaphore: std.Thread.Semaphore,
        allocator: Allocator,

        fn init(allocator: Allocator) ActorQueue {
            return ActorQueue{
                .queue = std.ArrayList(*Actor).init(allocator),
                .mutex = std.Thread.Mutex{},
                .semaphore = std.Thread.Semaphore{},
                .allocator = allocator,
            };
        }

        fn deinit(self: *ActorQueue) void {
            self.queue.deinit();
        }

        fn push(self: *ActorQueue, actor: *Actor) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.queue.append(actor);
            std.log.info("ActorQueue: Added actor {} to queue (size: {}), posting semaphore @{*}", .{ actor.getId(), self.queue.items.len, &self.semaphore });
            self.semaphore.post();
        }

        fn popOrWait(self: *ActorQueue, worker_running: *std.atomic.Value(bool)) ?*Actor {
            while (worker_running.load(.acquire)) {
                // Wait for work to be available
                std.log.info("ActorQueue: Worker waiting for semaphore @{*}", .{&self.semaphore});
                self.semaphore.wait();
                std.log.info("ActorQueue: Worker got semaphore signal @{*}", .{&self.semaphore});

                // Check if we should stop after waking up
                if (!worker_running.load(.acquire)) {
                    return null;
                }

                // Try to get work from queue
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    if (self.queue.items.len > 0) {
                        const actor = self.queue.pop();
                        if (actor) |a| {
                            std.log.info("ActorQueue: Worker got actor {} (remaining queue size: {})", .{ a.getId(), self.queue.items.len });
                        }
                        return actor;
                    }
                }

                // No work available (spurious wakeup), continue waiting
                std.log.info("ActorQueue: No work available after semaphore signal, continuing", .{});
            }

            return null;
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

        var scheduler = Self{
            .allocator = allocator,
            .workers = undefined,
            .num_threads = actual_threads,
            .running = std.atomic.Value(bool).init(false),
            .actor_queue = ActorQueue.init(allocator),
        };

        const workers = try allocator.alloc(WorkerContext, actual_threads);
        // Initialize workers without scheduler reference first
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerContext{
                .id = @intCast(i),
                .scheduler = undefined, // Will be set later
                .thread = null,
                .running = std.atomic.Value(bool).init(false),
            };
        }

        scheduler.workers = workers;

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

        // Set scheduler reference for all workers
        for (self.workers) |*worker| {
            worker.scheduler = self;
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

        // Wake up all workers by posting to semaphore
        for (self.workers) |_| {
            self.actor_queue.semaphore.post();
        }

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
            // Get work from queue (blocks until work is available)
            const actor = worker.scheduler.actor_queue.popOrWait(&worker.running);

            if (actor) |a| {
                // Process messages for this actor
                processActor(worker, a);
            }
        }

        std.log.info("EventWorker {} stopped", .{worker.id});
    }

    fn processActor(self: *WorkerContext, actor: *Actor) void {
        _ = self;

        var messages_processed: u32 = 0;
        const max_messages_per_run = 1000; // Dramatically increased batch size

        // Process messages until mailbox is empty or limit reached
        while (messages_processed < max_messages_per_run) {
            const processed = actor.processMessage() catch {
                // Minimal error handling - just break on error
                break;
            };

            if (!processed) break;
            messages_processed += 1;
        }

        // Reschedule if there are still messages to process
        const actor_state = actor.getState();
        if (actor_state == .running and !actor.mailbox.isEmpty()) {
            // Always reschedule if there are more messages
            actor.context.system.scheduler.schedule(actor) catch {};
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
