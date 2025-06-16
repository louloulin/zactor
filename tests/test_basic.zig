const std = @import("std");
const zactor = @import("src/zactor.zig");

// Simple test actor
const TestActor = struct {
    const Self = @This();

    name: []const u8,
    count: u32,

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .count = 0,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        switch (message.message_type) {
            .user => {
                self.count += 1;
                std.log.info("TestActor '{s}' received message #{}: {s}", .{ self.name, self.count, message.data.user.payload });
            },
            .system => {
                switch (message.data.system) {
                    .ping => {
                        std.log.info("TestActor '{s}' received ping", .{self.name});
                    },
                    else => {},
                }
            },
            .control => {},
        }
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("TestActor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("TestActor '{s}' stopping with count: {}", .{ self.name, self.count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("TestActor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("TestActor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZActor Basic Test ===", .{});

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .scheduler_threads = 2,
        .enable_work_stealing = true,
    });

    // Create actor system
    var system = try zactor.ActorSystem.init("test-system", allocator);
    defer system.deinit();

    // Start the system
    try system.start();
    std.log.info("Actor system started", .{});

    // Spawn test actor
    const test_actor = try system.spawn(TestActor, TestActor.init("TestActor-1"));
    std.log.info("Spawned actor: {}", .{test_actor.getId()});

    // Send some messages
    try test_actor.send([]const u8, "Hello, ZActor!", allocator);
    try test_actor.send([]const u8, "This is a test message", allocator);
    try test_actor.sendSystem(.ping);

    // Wait for messages to be processed
    std.log.info("Waiting for message processing...", .{});
    std.time.sleep(100 * std.time.ns_per_ms);

    // Get system statistics
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();

    // Shutdown
    std.log.info("Shutting down...", .{});
    system.shutdown();

    std.log.info("=== Test Complete ===", .{});
}
