const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zactor = @import("zactor.zig");
const Actor = @import("actor.zig").Actor;
const ActorRef = @import("actor_ref.zig").ActorRef;
const ActorRefRegistry = @import("actor_ref.zig").ActorRefRegistry;
const EventScheduler = @import("event_scheduler.zig").EventScheduler;
const SchedulerStats = @import("event_scheduler.zig").SchedulerStats;
const Message = @import("message.zig").Message;
const Supervisor = @import("supervisor.zig").Supervisor;
const SupervisorConfig = @import("supervisor.zig").SupervisorConfig;

// Main ActorSystem that manages the lifecycle of all actors
pub const ActorSystem = struct {
    const Self = @This();

    name: []const u8,
    allocator: Allocator,
    scheduler: EventScheduler,
    registry: ActorRefRegistry,
    supervisor: Supervisor,
    next_actor_id: std.atomic.Value(u64),
    running: std.atomic.Value(bool),
    // Track all created actors for cleanup
    actors: std.ArrayList(*Actor),
    actors_mutex: std.Thread.Mutex,

    pub fn init(name: []const u8, allocator: Allocator) !Self {
        const num_threads = if (zactor.config.scheduler_threads == 0)
            @as(u32, @intCast(std.Thread.getCpuCount() catch 4))
        else
            zactor.config.scheduler_threads;

        return Self{
            .name = try allocator.dupe(u8, name),
            .allocator = allocator,
            .scheduler = try EventScheduler.init(allocator, num_threads),
            .registry = ActorRefRegistry.init(allocator),
            .supervisor = Supervisor.init(allocator, .{}),
            .next_actor_id = std.atomic.Value(u64).init(1),
            .running = std.atomic.Value(bool).init(false),
            .actors = std.ArrayList(*Actor).init(allocator),
            .actors_mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.scheduler.deinit();
        self.registry.deinit();
        self.supervisor.deinit();
        self.actors.deinit();
        self.allocator.free(self.name);
    }

    // Start the actor system
    pub fn start(self: *Self) !void {
        if (self.running.swap(true, .acq_rel)) {
            return; // Already running
        }

        try self.scheduler.start();
        std.log.info("ActorSystem '{s}' started", .{self.name});
    }

    // Shutdown the actor system gracefully
    pub fn shutdown(self: *Self) void {
        if (!self.running.swap(false, .acq_rel)) {
            return; // Already stopped
        }

        std.log.info("ActorSystem '{s}' shutting down...", .{self.name});

        // Stop all actors
        self.registry.stopAll(self.allocator) catch |err| {
            std.log.err("Error stopping actors: {}", .{err});
        };

        // Wait for actors to finish processing
        std.time.sleep(50 * std.time.ns_per_ms);

        // Clean up all actors
        self.cleanupAllActors();

        // Stop scheduler
        self.scheduler.stop();

        std.log.info("ActorSystem '{s}' shutdown complete", .{self.name});
    }

    // Clean up all actors and their resources
    fn cleanupAllActors(self: *Self) void {
        self.actors_mutex.lock();
        defer self.actors_mutex.unlock();

        std.log.info("Cleaning up {} actors...", .{self.actors.items.len});

        for (self.actors.items) |actor| {
            // Ensure actor is stopped
            actor.stop() catch |err| {
                std.log.warn("Error stopping actor {}: {}", .{ actor.getId(), err });
            };

            // Clean up actor resources
            actor.deinit();

            // Free the actor itself
            self.allocator.destroy(actor);
        }

        // Clear the actors list
        self.actors.clearAndFree();

        std.log.info("All actors cleaned up", .{});
    }

    // Spawn a new actor
    pub fn spawn(self: *Self, comptime BehaviorType: type, behavior_data: BehaviorType) !ActorRef {
        if (!self.running.load(.acquire)) {
            return zactor.ActorError.SystemShutdown;
        }

        const actor_id = self.next_actor_id.fetchAdd(1, .monotonic);

        // Create the actor
        const actor = try self.allocator.create(Actor);
        actor.* = try Actor.init(BehaviorType, behavior_data, actor_id, self.allocator, self);

        // Track the actor for cleanup
        {
            self.actors_mutex.lock();
            defer self.actors_mutex.unlock();
            try self.actors.append(actor);
        }

        // Get actor reference
        const actor_ref = actor.getRef();

        // Register the actor
        try self.registry.register(actor_ref);

        // Add to supervision
        try self.supervisor.addChild(actor_ref);

        // Start the actor
        try actor.start();

        // Schedule the actor for execution
        try self.scheduler.schedule(actor);

        std.log.info("Spawned actor {} of type {s}", .{ actor_id, @typeName(BehaviorType) });

        return actor_ref;
    }

    // Find an actor by ID
    pub fn findActor(self: *Self, actor_id: zactor.ActorId) ?ActorRef {
        return self.registry.lookup(actor_id);
    }

    // Broadcast a message to all actors
    pub fn broadcast(self: *Self, comptime T: type, data: T) !void {
        try self.registry.broadcast(T, data, self.allocator);
    }

    // Get system statistics
    pub fn getStats(self: *Self) ActorSystemStats {
        const scheduler_stats = self.scheduler.getStats();

        return ActorSystemStats{
            .name = self.name,
            .running = self.running.load(.acquire),
            .total_actors = self.registry.count(),
            .messages_sent = zactor.metrics.getMessagesSent(),
            .messages_received = zactor.metrics.getMessagesReceived(),
            .actors_created = zactor.metrics.getActorsCreated(),
            .actors_destroyed = zactor.metrics.getActorsDestroyed(),
            .scheduler_stats = scheduler_stats,
        };
    }

    // Handle actor failure (called by actors when they fail)
    pub fn handleActorFailure(self: *Self, actor_id: zactor.ActorId, error_info: anyerror) !void {
        std.log.warn("ActorSystem: Actor {} failed with error: {}", .{ actor_id, error_info });

        // Delegate to supervisor
        try self.supervisor.handleFailure(actor_id, error_info);

        // Update metrics
        zactor.metrics.incrementActorFailures();
    }

    // Configure supervision strategy
    pub fn setSupervisorConfig(self: *Self, config: SupervisorConfig) void {
        self.supervisor.config = config;
        std.log.info("ActorSystem: Updated supervisor configuration", .{});
    }

    // Get supervisor statistics
    pub fn getSupervisorStats(self: *Self) @import("supervisor.zig").SupervisorStats {
        return self.supervisor.getStats();
    }

    // Wait for the system to process all pending messages
    pub fn awaitQuiescence(self: *Self, timeout_ms: u64) !void {
        const start_time = std.time.milliTimestamp();

        while (std.time.milliTimestamp() - start_time < timeout_ms) {
            const stats = self.scheduler.getStats();
            defer stats.deinit(self.allocator);

            if (stats.total_queued_actors == 0) {
                return; // System is quiescent
            }

            std.time.sleep(1 * std.time.ns_per_ms);
        }

        return zactor.ActorError.SystemShutdown; // Timeout
    }
};

pub const ActorSystemStats = struct {
    name: []const u8,
    running: bool,
    total_actors: u32,
    messages_sent: u64,
    messages_received: u64,
    actors_created: u64,
    actors_destroyed: u64,
    scheduler_stats: SchedulerStats,

    pub fn deinit(self: ActorSystemStats, allocator: Allocator) void {
        self.scheduler_stats.deinit(allocator);
    }

    pub fn print(self: ActorSystemStats) void {
        std.log.info("=== ActorSystem '{s}' Stats ===", .{self.name});
        std.log.info("Running: {}", .{self.running});
        std.log.info("Total Actors: {}", .{self.total_actors});
        std.log.info("Messages Sent: {}", .{self.messages_sent});
        std.log.info("Messages Received: {}", .{self.messages_received});
        std.log.info("Actors Created: {}", .{self.actors_created});
        std.log.info("Actors Destroyed: {}", .{self.actors_destroyed});
        std.log.info("Queued Actors: {}", .{self.scheduler_stats.total_queued_actors});
        std.log.info("Active Workers: {}", .{self.scheduler_stats.active_workers});

        for (self.scheduler_stats.worker_queue_sizes, 0..) |size, i| {
            std.log.info("Worker {} Queue Size: {}", .{ i, size });
        }
    }
};

test "actor system creation and lifecycle" {
    const allocator = testing.allocator;

    var system = try ActorSystem.init("test-system", allocator);
    defer system.deinit();

    try testing.expectEqualStrings("test-system", system.name);
    try testing.expect(!system.running.load(.acquire));

    // Start the system
    try system.start();
    try testing.expect(system.running.load(.acquire));

    // Get initial stats
    const stats = system.getStats();
    defer stats.deinit(allocator);

    try testing.expect(stats.running);
    try testing.expect(stats.total_actors == 0);

    // Shutdown
    system.shutdown();
    try testing.expect(!system.running.load(.acquire));
}
