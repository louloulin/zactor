const std = @import("std");
const testing = std.testing;
const zactor = @import("zactor");

// Simple test actor for supervision testing
const TestActor = struct {
    const Self = @This();

    id: u32,
    should_fail: bool,

    pub fn init(id: u32, should_fail: bool) Self {
        return Self{
            .id = id,
            .should_fail = should_fail,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.data) {
            .user => |user_msg| {
                const parsed = try user_msg.get([]const u8, context.allocator);
                defer parsed.deinit();
                const data = parsed.value;

                if (std.mem.eql(u8, data, "work")) {
                    if (self.should_fail) {
                        return error.TestFailure;
                    }
                    std.log.info("TestActor {} completed work", .{self.id});
                }
            },
            .system => |sys_msg| {
                switch (sys_msg) {
                    .start => std.log.info("TestActor {} started", .{self.id}),
                    .stop => std.log.info("TestActor {} stopped", .{self.id}),
                    .restart => {
                        std.log.info("TestActor {} restarted", .{self.id});
                        self.should_fail = false; // Don't fail after restart
                    },
                    else => {},
                }
            },
            .control => {},
        }
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("TestActor {} starting", .{self.id});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("TestActor {} stopped", .{self.id});
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.warn("TestActor {} restarting due to: {}", .{ self.id, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("TestActor {} restarted successfully", .{self.id});
    }

    pub fn preStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("TestActor {} stopping", .{self.id});
    }
};

test "supervisor basic functionality" {
    const allocator = testing.allocator;

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .scheduler_threads = 1,
    });

    var system = try zactor.ActorSystem.init("test-system", allocator);
    defer system.deinit();

    // Configure supervision strategy
    system.setSupervisorConfig(.{
        .strategy = .restart,
        .max_restarts = 2,
        .restart_window_seconds = 10,
    });

    try system.start();

    // Create test actors
    const actor1 = TestActor.init(1, false); // Normal actor
    const actor2 = TestActor.init(2, true); // Failing actor

    const actor_ref1 = try system.spawn(TestActor, actor1);
    const actor_ref2 = try system.spawn(TestActor, actor2);

    // Send work to actors
    try actor_ref1.send([]const u8, "work", allocator);
    try actor_ref2.send([]const u8, "work", allocator); // This should fail and trigger restart

    // Wait for processing
    std.time.sleep(100 * std.time.ns_per_ms);

    // Check supervisor stats
    const stats = system.getSupervisorStats();
    try testing.expect(stats.total_children == 2);

    // Send work again to the restarted actor
    try actor_ref2.send([]const u8, "work", allocator); // Should work after restart

    std.time.sleep(100 * std.time.ns_per_ms);

    system.shutdown();
}

test "supervisor restart strategy" {
    const allocator = testing.allocator;

    zactor.init(.{
        .max_actors = 5,
        .scheduler_threads = 1,
    });

    var system = try zactor.ActorSystem.init("restart-test", allocator);
    defer system.deinit();

    // Configure restart strategy
    system.setSupervisorConfig(.{
        .strategy = .restart,
        .max_restarts = 1,
        .restart_window_seconds = 5,
    });

    try system.start();

    // Create a failing actor
    const failing_actor = TestActor.init(99, true);
    const actor_ref = try system.spawn(TestActor, failing_actor);

    // Send work multiple times to exceed restart limit
    try actor_ref.send([]const u8, "work", allocator); // First failure -> restart
    std.time.sleep(50 * std.time.ns_per_ms);

    try actor_ref.send([]const u8, "work", allocator); // Should work after restart
    std.time.sleep(50 * std.time.ns_per_ms);

    const stats = system.getSupervisorStats();
    std.log.info("Final supervisor stats: {} children, {} restarts", .{ stats.total_children, stats.total_restarts });

    system.shutdown();
}

test "supervisor metrics" {
    const allocator = testing.allocator;

    zactor.init(.{
        .max_actors = 3,
        .scheduler_threads = 1,
    });

    var system = try zactor.ActorSystem.init("metrics-test", allocator);
    defer system.deinit();

    try system.start();

    // Create actors
    const actor1 = TestActor.init(1, false);
    const actor2 = TestActor.init(2, false);

    const actor_ref1 = try system.spawn(TestActor, actor1);
    const actor_ref2 = try system.spawn(TestActor, actor2);

    // Check initial stats
    const stats = system.getSupervisorStats();
    try testing.expect(stats.total_children == 2);
    try testing.expect(stats.active_children <= 2);

    // Send some work
    try actor_ref1.send([]const u8, "work", allocator);
    try actor_ref2.send([]const u8, "work", allocator);

    std.time.sleep(50 * std.time.ns_per_ms);

    // Check metrics
    const metrics = &zactor.metrics;
    try testing.expect(metrics.getActorsCreated() >= 2);
    try testing.expect(metrics.getMessagesSent() >= 2);

    system.shutdown();
}
