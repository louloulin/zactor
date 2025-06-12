const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

// Import all high-performance components
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;
const FastMessage = @import("message_pool.zig").FastMessage;
const MessagePool = @import("message_pool.zig").MessagePool;
const MessageBatch = @import("message_pool.zig").MessageBatch;
const FastMailbox = @import("fast_mailbox.zig").FastMailbox;
const FastScheduler = @import("fast_scheduler.zig").FastScheduler;
const SchedulerConfig = @import("fast_scheduler.zig").SchedulerConfig;
const ActorPriority = @import("fast_scheduler.zig").ActorPriority;
const FastActor = @import("fast_actor.zig").FastActor;
const ActorVTable = @import("fast_actor.zig").ActorVTable;
const FastActorBehavior = @import("fast_actor.zig").FastActorBehavior;

// Ultra-high-performance actor system targeting 1M+ msg/s
pub const UltraFastActorSystem = struct {
    const Self = @This();
    const MAX_ACTORS = 100000;

    // Core components
    message_pool: MessagePool,
    scheduler: FastScheduler,
    actors: std.ArrayList(*FastActor),

    // Actor management
    next_actor_id: std.atomic.Value(u32),
    allocator: Allocator,

    // System state
    running: std.atomic.Value(bool),

    // Performance monitoring
    stats: SystemStats,
    start_time: i128,

    pub fn init(allocator: Allocator, config: SystemConfig) !Self {
        const scheduler_config = SchedulerConfig{
            .message_workers = config.worker_threads,
            .io_workers = config.io_threads,
            .system_workers = 1,
        };

        return Self{
            .message_pool = try MessagePool.init(allocator),
            .scheduler = try FastScheduler.init(allocator, scheduler_config),
            .actors = std.ArrayList(*FastActor).init(allocator),
            .next_actor_id = std.atomic.Value(u32).init(1),
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .stats = SystemStats.init(),
            .start_time = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // Clean up actors
        for (self.actors.items) |actor| {
            actor.deinit();
            self.allocator.destroy(actor);
        }
        self.actors.deinit();

        self.scheduler.deinit();
        self.message_pool.deinit();
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.start_time = std.time.nanoTimestamp();
        try self.scheduler.start();

        std.log.info("UltraFastActorSystem started with {} workers", .{self.scheduler.message_workers.len});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        self.scheduler.stop();

        std.log.info("UltraFastActorSystem stopped", .{});
    }

    // Spawn a new high-performance actor
    pub fn spawn(self: *Self, comptime T: type, behavior: T) !ActorRef {
        const actor_id = self.next_actor_id.fetchAdd(1, .monotonic);

        // Allocate actor and behavior
        const behavior_ptr = try self.allocator.create(T);
        behavior_ptr.* = behavior;

        const vtable = FastActorBehavior(T).getVTable();
        const actor = try self.allocator.create(FastActor);
        actor.* = FastActor.init(actor_id, behavior_ptr, &vtable, self.allocator);

        // Add to actor list
        try self.actors.append(actor);

        // Start the actor
        actor.start();

        // Schedule for initial processing
        try self.scheduler.scheduleActor(actor, .normal);

        _ = self.stats.actors_created.fetchAdd(1, .monotonic);

        return ActorRef{
            .id = actor_id,
            .actor = actor,
            .system = self,
        };
    }

    // High-performance string message sending
    pub fn sendString(self: *Self, actor_id: u32, data: []const u8) !bool {
        if (self.message_pool.acquire()) |msg| {
            const sequence = self.message_pool.nextSequence();
            msg.* = FastMessage.createUserString(actor_id, 0, sequence, data);
            return self.sendMessageToActor(actor_id, msg);
        }
        return false;
    }

    // High-performance int message sending
    pub fn sendInt(self: *Self, actor_id: u32, data: i64) !bool {
        if (self.message_pool.acquire()) |msg| {
            const sequence = self.message_pool.nextSequence();
            msg.* = FastMessage.createUserInt(actor_id, 0, sequence, data);
            return self.sendMessageToActor(actor_id, msg);
        }
        return false;
    }

    // High-performance ping message sending
    pub fn sendPing(self: *Self, actor_id: u32) !bool {
        if (self.message_pool.acquire()) |msg| {
            const sequence = self.message_pool.nextSequence();
            msg.* = FastMessage.createSystemPing(actor_id, 0, sequence);
            return self.sendMessageToActor(actor_id, msg);
        }
        return false;
    }

    // Internal helper to send message to actor
    fn sendMessageToActor(self: *Self, actor_id: u32, msg: *FastMessage) bool {
        // Find actor and send message
        for (self.actors.items) |actor| {
            if (actor.id == actor_id) {
                const sent = actor.send(msg);
                if (sent) {
                    _ = self.stats.messages_sent.fetchAdd(1, .monotonic);

                    // Reschedule actor if needed
                    self.scheduler.scheduleActor(actor, .normal) catch {};
                } else {
                    self.message_pool.release(msg);
                }
                return sent;
            }
        }

        self.message_pool.release(msg);
        return false;
    }

    // Batch message sending for maximum throughput
    pub fn sendBatch(self: *Self, actor_id: u32, messages: []const BatchMessage) !u32 {
        var batch = MessageBatch.init();
        var sent: u32 = 0;

        for (messages) |batch_msg| {
            if (self.message_pool.acquire()) |msg| {
                const sequence = self.message_pool.nextSequence();

                switch (batch_msg.msg_type) {
                    .user_string => {
                        msg.* = FastMessage.createUserString(actor_id, 0, sequence, batch_msg.data.string);
                    },
                    .user_int => {
                        msg.* = FastMessage.createUserInt(actor_id, 0, sequence, batch_msg.data.int_val);
                    },
                    else => {
                        self.message_pool.release(msg);
                        continue;
                    },
                }

                if (!batch.add(msg)) {
                    self.message_pool.release(msg);
                    break;
                }
            }
        }

        // Send batch to actor
        for (self.actors.items) |actor| {
            if (actor.id == actor_id) {
                sent = actor.sendBatch(&batch);
                _ = self.stats.messages_sent.fetchAdd(sent, .monotonic);

                // Reschedule actor
                try self.scheduler.scheduleActor(actor, .normal);
                break;
            }
        }

        // Release unsent messages
        for (batch.getMessages()[sent..]) |msg| {
            self.message_pool.release(msg);
        }

        return sent;
    }

    pub fn getStats(self: *Self) SystemStats {
        // Add scheduler stats
        const scheduler_stats = self.scheduler.getStats();

        // Add pool stats
        const pool_stats = self.message_pool.getStats();

        // Calculate throughput
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(now - self.start_time, 1000000);
        const messages_processed = scheduler_stats.messages_processed.load(.monotonic);
        const throughput = if (elapsed_ms > 0)
            @as(f64, @floatFromInt(messages_processed * 1000)) / @as(f64, @floatFromInt(elapsed_ms))
        else
            0.0;

        return SystemStats{
            .actors_created = self.stats.actors_created,
            .messages_sent = self.stats.messages_sent,
            .messages_processed = std.atomic.Value(u64).init(messages_processed),
            .actors_scheduled = scheduler_stats.actors_scheduled.load(.monotonic),
            .throughput = throughput,
            .pool_utilization = @as(f64, @floatFromInt(pool_stats.used_messages)) / @as(f64, @floatFromInt(pool_stats.total_messages)),
        };
    }

    pub fn printStats(self: *Self) void {
        const stats = self.getStats();

        std.log.info("=== UltraFastActorSystem Statistics ===", .{});
        std.log.info("Actors created: {}", .{stats.actors_created.load(.monotonic)});
        std.log.info("Messages sent: {}", .{stats.messages_sent.load(.monotonic)});
        std.log.info("Messages processed: {}", .{stats.messages_processed.load(.monotonic)});
        std.log.info("Throughput: {d:.0} msg/s", .{stats.throughput});
        std.log.info("Pool utilization: {d:.1}%", .{stats.pool_utilization * 100});
    }
};

pub const SystemConfig = struct {
    worker_threads: u32 = 8,
    io_threads: u32 = 2,
};

pub const SystemStats = struct {
    actors_created: std.atomic.Value(u64),
    messages_sent: std.atomic.Value(u64),
    messages_processed: std.atomic.Value(u64),
    actors_scheduled: u64,
    throughput: f64,
    pool_utilization: f64,

    pub fn init() SystemStats {
        return SystemStats{
            .actors_created = std.atomic.Value(u64).init(0),
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_processed = std.atomic.Value(u64).init(0),
            .actors_scheduled = 0,
            .throughput = 0.0,
            .pool_utilization = 0.0,
        };
    }
};

pub const ActorRef = struct {
    id: u32,
    actor: *FastActor,
    system: *UltraFastActorSystem,

    pub fn sendString(self: ActorRef, data: []const u8) !bool {
        return self.system.sendString(self.id, data);
    }

    pub fn sendInt(self: ActorRef, data: i64) !bool {
        return self.system.sendInt(self.id, data);
    }

    pub fn sendPing(self: ActorRef) !bool {
        return self.system.sendPing(self.id);
    }

    pub fn sendBatch(self: ActorRef, messages: []const BatchMessage) !u32 {
        return self.system.sendBatch(self.id, messages);
    }

    pub fn getStats(self: ActorRef) @import("fast_actor.zig").ActorStats {
        return self.actor.getStats();
    }
};

pub const BatchMessage = struct {
    msg_type: FastMessage.Type,
    data: union {
        string: []const u8,
        int_val: i64,
        float_val: f64,
    },
};

test "ultra fast system basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = SystemConfig{
        .worker_threads = 2,
        .io_threads = 1,
    };

    var system = try UltraFastActorSystem.init(allocator, config);
    defer system.deinit();

    try system.start();
    defer system.stop();

    // Spawn a counter actor
    const CounterActor = @import("fast_actor.zig").CounterActor;
    const counter = CounterActor.init("test");
    const actor_ref = try system.spawn(CounterActor, counter);

    // Send some messages
    for (0..10) |i| {
        _ = try actor_ref.send(.user_int, @as(i64, @intCast(i + 1)));
    }

    // Wait a bit for processing
    std.time.sleep(10 * std.time.ns_per_ms);

    const stats = system.getStats();
    try testing.expect(stats.messages_sent.load(.monotonic) == 10);
}
