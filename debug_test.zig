const std = @import("std");
const zactor = @import("src/zactor.zig");

// Debug actor with detailed logging
const DebugActor = struct {
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
        self.count += 1;
        std.log.info("DebugActor {} received message #{} (type: {})", .{ self.id, self.count, message.message_type });
        
        switch (message.message_type) {
            .user => {
                std.log.info("  User message payload: {s}", .{message.data.user.payload});
            },
            .system => {
                std.log.info("  System message: {}", .{message.data.system});
            },
            .control => {
                std.log.info("  Control message: {}", .{message.data.control});
            },
        }
    }
    
    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("DebugActor {} starting", .{self.id});
    }
    
    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("DebugActor {} stopping with count: {}", .{ self.id, self.count });
    }
    
    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("DebugActor {} restarting due to: {}", .{ self.id, reason });
    }
    
    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("DebugActor {} restarted", .{self.id});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== ZActor Debug Test ===", .{});
    
    // Initialize ZActor with debug configuration
    zactor.init(.{
        .max_actors = 5,
        .scheduler_threads = 1,
        .enable_work_stealing = false,
        .mailbox_capacity = 100,
    });
    
    // Create actor system
    var system = try zactor.ActorSystem.init("debug-test", allocator);
    defer system.deinit();
    
    // Start the system
    try system.start();
    std.log.info("Actor system started", .{});
    
    // Wait for system to stabilize
    std.time.sleep(200 * std.time.ns_per_ms);
    
    // Spawn a debug actor
    std.log.info("Spawning debug actor...", .{});
    const actor = try system.spawn(DebugActor, DebugActor.init(1));
    std.log.info("Spawned actor: {}", .{actor.getId()});
    
    // Wait for actor to start
    std.time.sleep(200 * std.time.ns_per_ms);
    
    // Check initial stats
    var stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("Initial stats - Actors: {}, Messages sent: {}, received: {}", .{ stats.total_actors, stats.messages_sent, stats.messages_received });
    
    // Send messages one by one with delays
    std.log.info("Sending first message...", .{});
    try actor.send([]const u8, "First message", allocator);
    std.time.sleep(500 * std.time.ns_per_ms);
    
    stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("After first message - Messages sent: {}, received: {}", .{ stats.messages_sent, stats.messages_received });
    
    std.log.info("Sending second message...", .{});
    try actor.send([]const u8, "Second message", allocator);
    std.time.sleep(500 * std.time.ns_per_ms);
    
    stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("After second message - Messages sent: {}, received: {}", .{ stats.messages_sent, stats.messages_received });
    
    std.log.info("Sending system ping...", .{});
    try actor.sendSystem(.ping);
    std.time.sleep(500 * std.time.ns_per_ms);
    
    stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("After ping - Messages sent: {}, received: {}", .{ stats.messages_sent, stats.messages_received });
    
    // Final stats
    std.log.info("=== Final Stats ===", .{});
    stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();
    
    // Shutdown
    std.log.info("Shutting down...", .{});
    system.shutdown();
    
    std.log.info("=== Debug Test Complete ===", .{});
}
