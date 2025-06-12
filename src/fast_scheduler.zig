const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;
const MPSCQueue = @import("lockfree_queue.zig").MPSCQueue;
const FastMessage = @import("message_pool.zig").FastMessage;
const MessageBatch = @import("message_pool.zig").MessageBatch;
const FastMailbox = @import("fast_mailbox.zig").FastMailbox;

// Forward declaration
const FastActor = @import("fast_actor.zig").FastActor;

// Specialized thread pools for different workloads
pub const ThreadPoolType = enum {
    message_processing, // High-throughput message processing
    io_operations,      // I/O bound operations
    system_tasks,       // System management tasks
    compute_intensive,  // CPU-intensive tasks
};

// High-performance actor scheduler with specialized thread pools
pub const FastScheduler = struct {
    const Self = @This();
    const MAX_WORKERS = 32;
    const BATCH_SIZE = 256;
    
    // Specialized worker pools
    message_workers: []MessageWorker,
    io_workers: []IOWorker,
    system_workers: []SystemWorker,
    
    // Actor scheduling queues
    ready_queue: MPSCQueue(*FastActor),
    high_priority_queue: MPSCQueue(*FastActor),
    
    // Control
    running: std.atomic.Value(bool),
    allocator: Allocator,
    
    // Statistics
    stats: SchedulerStats,

    pub fn init(allocator: Allocator, config: SchedulerConfig) !Self {
        var self = Self{
            .message_workers = try allocator.alloc(MessageWorker, config.message_workers),
            .io_workers = try allocator.alloc(IOWorker, config.io_workers),
            .system_workers = try allocator.alloc(SystemWorker, config.system_workers),
            .ready_queue = try MPSCQueue(*FastActor).init(allocator),
            .high_priority_queue = try MPSCQueue(*FastActor).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .stats = SchedulerStats.init(),
        };

        // Initialize workers
        for (self.message_workers, 0..) |*worker, i| {
            worker.* = try MessageWorker.init(allocator, @intCast(i), &self);
        }
        
        for (self.io_workers, 0..) |*worker, i| {
            worker.* = try IOWorker.init(allocator, @intCast(i), &self);
        }
        
        for (self.system_workers, 0..) |*worker, i| {
            worker.* = try SystemWorker.init(allocator, @intCast(i), &self);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        
        for (self.message_workers) |*worker| {
            worker.deinit();
        }
        for (self.io_workers) |*worker| {
            worker.deinit();
        }
        for (self.system_workers) |*worker| {
            worker.deinit();
        }
        
        self.allocator.free(self.message_workers);
        self.allocator.free(self.io_workers);
        self.allocator.free(self.system_workers);
        
        self.ready_queue.deinit();
        self.high_priority_queue.deinit();
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        
        // Start all workers
        for (self.message_workers) |*worker| {
            try worker.start();
        }
        for (self.io_workers) |*worker| {
            try worker.start();
        }
        for (self.system_workers) |*worker| {
            try worker.start();
        }
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        
        // Stop all workers
        for (self.message_workers) |*worker| {
            worker.stop();
        }
        for (self.io_workers) |*worker| {
            worker.stop();
        }
        for (self.system_workers) |*worker| {
            worker.stop();
        }
    }

    pub fn scheduleActor(self: *Self, actor: *FastActor, priority: ActorPriority) !void {
        switch (priority) {
            .high => try self.high_priority_queue.push(actor),
            .normal => try self.ready_queue.push(actor),
        }
        _ = self.stats.actors_scheduled.fetchAdd(1, .monotonic);
    }

    pub fn getStats(self: *Self) SchedulerStats {
        return self.stats;
    }
};

pub const ActorPriority = enum {
    normal,
    high,
};

pub const SchedulerConfig = struct {
    message_workers: u32 = 8,
    io_workers: u32 = 2,
    system_workers: u32 = 1,
};

pub const SchedulerStats = struct {
    actors_scheduled: std.atomic.Value(u64),
    messages_processed: std.atomic.Value(u64),
    batch_operations: std.atomic.Value(u64),
    
    pub fn init() SchedulerStats {
        return SchedulerStats{
            .actors_scheduled = std.atomic.Value(u64).init(0),
            .messages_processed = std.atomic.Value(u64).init(0),
            .batch_operations = std.atomic.Value(u64).init(0),
        };
    }
};

// Specialized worker for high-throughput message processing
const MessageWorker = struct {
    const Self = @This();
    
    id: u32,
    thread: ?Thread,
    scheduler: *FastScheduler,
    allocator: Allocator,
    running: std.atomic.Value(bool),
    
    // Local batch for processing
    message_batch: MessageBatch,
    actor_batch: [64]*FastActor,

    pub fn init(allocator: Allocator, id: u32, scheduler: *FastScheduler) !Self {
        return Self{
            .id = id,
            .thread = null,
            .scheduler = scheduler,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .message_batch = MessageBatch.init(),
            .actor_batch = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
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
        while (self.running.load(.acquire)) {
            self.processActors();
            
            // Brief yield to prevent CPU spinning
            std.time.sleep(1000); // 1 microsecond
        }
    }

    fn processActors(self: *Self) void {
        // Process high priority actors first
        if (self.scheduler.high_priority_queue.pop()) |actor| {
            self.processActor(actor);
            return;
        }
        
        // Process normal priority actors
        if (self.scheduler.ready_queue.pop()) |actor| {
            self.processActor(actor);
        }
    }

    fn processActor(self: *Self, actor: *FastActor) void {
        // Process messages in batches for maximum throughput
        const processed = actor.processBatch(&self.message_batch);
        _ = self.scheduler.stats.messages_processed.fetchAdd(processed, .monotonic);
        
        // Reschedule if actor has more messages
        if (!actor.mailbox.isEmpty()) {
            self.scheduler.scheduleActor(actor, .normal) catch {};
        }
    }
};

// Specialized worker for I/O operations
const IOWorker = struct {
    const Self = @This();
    
    id: u32,
    thread: ?Thread,
    scheduler: *FastScheduler,
    allocator: Allocator,
    running: std.atomic.Value(bool),

    pub fn init(allocator: Allocator, id: u32, scheduler: *FastScheduler) !Self {
        return Self{
            .id = id,
            .thread = null,
            .scheduler = scheduler,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
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
        while (self.running.load(.acquire)) {
            // Handle I/O operations
            std.time.sleep(10000); // 10 microseconds
        }
    }
};

// Specialized worker for system tasks
const SystemWorker = struct {
    const Self = @This();
    
    id: u32,
    thread: ?Thread,
    scheduler: *FastScheduler,
    allocator: Allocator,
    running: std.atomic.Value(bool),

    pub fn init(allocator: Allocator, id: u32, scheduler: *FastScheduler) !Self {
        return Self{
            .id = id,
            .thread = null,
            .scheduler = scheduler,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
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
        while (self.running.load(.acquire)) {
            // Handle system tasks
            std.time.sleep(100000); // 100 microseconds
        }
    }
};

test "fast scheduler initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = SchedulerConfig{
        .message_workers = 2,
        .io_workers = 1,
        .system_workers = 1,
    };
    
    var scheduler = try FastScheduler.init(allocator, config);
    defer scheduler.deinit();
    
    try testing.expect(scheduler.message_workers.len == 2);
    try testing.expect(scheduler.io_workers.len == 1);
    try testing.expect(scheduler.system_workers.len == 1);
}
