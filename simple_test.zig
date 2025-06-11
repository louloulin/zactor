const std = @import("std");
const zactor = @import("src/zactor.zig");

// Simple test actor
const SimpleActor = struct {
    const Self = @This();
    
    id: u32,
    count: u32,
    
    pub fn init(id: u32) Self {
        return Self{
            .id = id,
            .count = 0,
        };
    }
    
    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        switch (message.message_type) {
            .user => {
                self.count += 1;
                std.log.info("Actor {} received message #{}", .{ self.id, self.count });
            },
            .system => {
                switch (message.data.system) {
                    .ping => {
                        std.log.info("Actor {} received ping", .{self.id});
                    },
                    else => {},
                }
            },
            .control => {},
        }
    }
    
    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Actor {} starting", .{self.id});
    }
    
    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Actor {} stopping with count: {}", .{ self.id, self.count });
    }
    
    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("Actor {} restarting due to: {}", .{ self.id, reason });
    }
    
    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Actor {} restarted", .{self.id});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== ZActor Simple Test ===", .{});
    
    // Initialize ZActor with minimal configuration
    zactor.init(.{
        .max_actors = 5,
        .scheduler_threads = 1, // Single thread to avoid concurrency issues
        .enable_work_stealing = false, // Disable work stealing
        .mailbox_capacity = 100,
    });
    
    // Create actor system
    var system = try zactor.ActorSystem.init("simple-test", allocator);
    defer system.deinit();
    
    // Start the system
    try system.start();
    std.log.info("Actor system started", .{});
    
    // Wait for system to stabilize
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Spawn a single test actor
    std.log.info("Spawning actor...", .{});
    const actor = try system.spawn(SimpleActor, SimpleActor.init(1));
    std.log.info("Spawned actor: {}", .{actor.getId()});
    
    // Wait for actor to start
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Send some messages
    std.log.info("Sending messages...", .{});
    try actor.send([]const u8, "Hello", allocator);
    try actor.send([]const u8, "World", allocator);
    try actor.sendSystem(.ping);
    
    // Wait for messages to be processed
    std.log.info("Waiting for message processing...", .{});
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Get system statistics
    const stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("=== System Stats ===", .{});
    std.log.info("Messages sent: {}", .{stats.messages_sent});
    std.log.info("Messages received: {}", .{stats.messages_received});
    std.log.info("Total actors: {}", .{stats.total_actors});
    
    // Shutdown
    std.log.info("Shutting down...", .{});
    system.shutdown();
    
    std.log.info("=== Test Complete ===", .{});
}
