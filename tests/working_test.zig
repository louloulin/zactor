const std = @import("std");
const zactor = @import("src/zactor.zig");

// Very simple actor for testing
const WorkingActor = struct {
    const Self = @This();
    
    id: u32,
    
    pub fn init(id: u32) Self {
        return Self{ .id = id };
    }
    
    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("WorkingActor {} received message: {}", .{ self.id, message.message_type });
    }
    
    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("WorkingActor {} starting", .{self.id});
    }
    
    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("WorkingActor {} stopping", .{self.id});
    }
    
    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("WorkingActor {} restarting due to: {}", .{ self.id, reason });
    }
    
    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("WorkingActor {} restarted", .{self.id});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== Working Actor Test ===", .{});
    
    // Initialize ZActor with minimal configuration
    zactor.init(.{
        .max_actors = 2,
        .scheduler_threads = 1,
        .enable_work_stealing = false,
        .mailbox_capacity = 10,
    });
    
    // Create actor system
    var system = try zactor.ActorSystem.init("working-test", allocator);
    defer system.deinit();
    
    try system.start();
    std.log.info("System started", .{});
    
    // Wait for system to stabilize
    std.time.sleep(200 * std.time.ns_per_ms);
    
    // Spawn actor
    const actor = try system.spawn(WorkingActor, WorkingActor.init(1));
    std.log.info("Actor spawned: {}", .{actor.getId()});
    
    // Wait for actor to start and be processed
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Check initial stats
    var stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("Before sending - Messages sent: {}, received: {}", .{ stats.messages_sent, stats.messages_received });
    
    // Send a message
    std.log.info("Sending message...", .{});
    try actor.send([]const u8, "Hello", allocator);
    
    // Wait for processing
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Check stats again
    stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("After sending - Messages sent: {}, received: {}", .{ stats.messages_sent, stats.messages_received });
    
    // Send system message
    std.log.info("Sending ping...", .{});
    try actor.sendSystem(.ping);
    
    // Wait for processing
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Final stats
    stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("Final - Messages sent: {}, received: {}", .{ stats.messages_sent, stats.messages_received });
    
    // Shutdown
    std.log.info("Shutting down...", .{});
    system.shutdown();
    
    std.log.info("=== Test Complete ===", .{});
}
