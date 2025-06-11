const std = @import("std");
const zactor = @import("zactor");

// Simple counter actor that increments a value
const CounterActor = struct {
    const Self = @This();

    count: u32,
    name: []const u8,

    pub fn init(name: []const u8) Self {
        return Self{
            .count = 0,
            .name = name,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                // Try to parse as increment command
                if (std.mem.eql(u8, message.data.user.payload, "\"increment\"")) {
                    self.count += 1;
                    std.log.info("Counter '{s}' incremented to: {}", .{ self.name, self.count });
                } else if (std.mem.eql(u8, message.data.user.payload, "\"get_count\"")) {
                    std.log.info("Counter '{s}' current count: {}", .{ self.name, self.count });
                } else {
                    std.log.warn("Counter '{s}' received unknown message: {s}", .{ self.name, message.data.user.payload });
                }
            },
            .system => {
                switch (message.data.system) {
                    .ping => {
                        std.log.info("Counter '{s}' received ping, sending pong", .{self.name});
                        try context.sendSystem(context.getSelf(), .pong);
                    },
                    .pong => {
                        std.log.info("Counter '{s}' received pong", .{self.name});
                    },
                    else => {},
                }
            },
            .control => {
                std.log.info("Counter '{s}' received control message", .{self.name});
            },
        }
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Counter '{s}' starting with initial count: {}", .{ self.name, self.count });
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Counter '{s}' stopping with final count: {}", .{ self.name, self.count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("Counter '{s}' restarting due to: {}, count was: {}", .{ self.name, reason, self.count });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Counter '{s}' restarted, count reset to: {}", .{ self.name, self.count });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize ZActor with custom configuration
    zactor.init(.{
        .max_actors = 100,
        .mailbox_capacity = 1000,
        .scheduler_threads = 2,
        .enable_work_stealing = true,
    });

    std.log.info("=== ZActor Basic Example ===", .{});

    // Create actor system
    var system = try zactor.ActorSystem.init("basic-example", allocator);
    defer system.deinit();

    // Start the system
    try system.start();
    std.log.info("Actor system started", .{});

    // Give worker threads time to start and enter wait state
    std.time.sleep(100 * std.time.ns_per_ms);

    // Spawn counter actors
    const counter1 = try system.spawn(CounterActor, CounterActor.init("Counter-1"));
    const counter2 = try system.spawn(CounterActor, CounterActor.init("Counter-2"));

    std.log.info("Spawned actors: {} and {}", .{ counter1.getId(), counter2.getId() });

    // Send some messages
    try counter1.send([]const u8, "increment", allocator);
    try counter1.send([]const u8, "increment", allocator);
    try counter1.send([]const u8, "get_count", allocator);

    try counter2.send([]const u8, "increment", allocator);
    try counter2.send([]const u8, "get_count", allocator);

    // Send system messages
    try counter1.sendSystem(.ping);
    try counter2.sendSystem(.ping);

    // Wait for messages to be processed
    std.log.info("Waiting for message processing...", .{});
    std.time.sleep(100 * std.time.ns_per_ms);

    // Get system statistics
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();

    // Test broadcast
    std.log.info("Broadcasting increment to all actors...", .{});
    try system.broadcast([]const u8, "increment");

    // Wait a bit more
    std.time.sleep(50 * std.time.ns_per_ms);

    // Send final get_count to see results
    try counter1.send([]const u8, "get_count", allocator);
    try counter2.send([]const u8, "get_count", allocator);

    // Wait for final messages
    std.time.sleep(50 * std.time.ns_per_ms);

    // Final stats
    const final_stats = system.getStats();
    defer final_stats.deinit(allocator);
    std.log.info("Final stats:", .{});
    final_stats.print();

    // Graceful shutdown
    std.log.info("Shutting down actor system...", .{});
    system.shutdown();

    std.log.info("=== Example Complete ===", .{});
}
