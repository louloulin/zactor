const std = @import("std");
const zactor = @import("src/zactor.zig");

// Very simple test actor
const SimpleActor = struct {
    name: []const u8,
    message_count: u32,

    const Self = @This();

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .message_count = 0,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        self.message_count += 1;

        std.log.info("🎯 SimpleActor '{s}' received message #{} (Type: {})", .{ self.name, self.message_count, message.message_type });

        switch (message.message_type) {
            .user => {
                const user_data = message.data.user;
                const parsed = user_data.get([]const u8, context.allocator) catch |err| {
                    std.log.warn("⚠️ Failed to parse message: {}", .{err});
                    return;
                };
                defer parsed.deinit();

                std.log.info("📝 Message content: '{s}'", .{parsed.value});
            },
            .system => {
                std.log.info("🔧 System message: {}", .{message.data.system});
            },
            .control => {
                std.log.info("🎛️ Control message: {}", .{message.data.control});
            },
        }
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🚀 SimpleActor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🛑 SimpleActor '{s}' stopping (processed {} messages)", .{ self.name, self.message_count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("🔄 SimpleActor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🔄 SimpleActor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🧪 === Simple Message Test ===", .{});

    // Initialize ZActor with minimal configuration
    zactor.init(.{
        .max_actors = 5,
        .mailbox_capacity = 10,
        .scheduler_threads = 1,
        .enable_work_stealing = false,
    });

    // Create actor system
    var system = try zactor.ActorSystem.init("simple-test", allocator);
    defer system.deinit();

    // Start the system
    try system.start();
    std.log.info("✅ Actor system started", .{});

    // Wait for system to stabilize
    std.time.sleep(50 * std.time.ns_per_ms);

    // Spawn simple actor
    std.log.info("🎭 Spawning simple actor...", .{});
    const actor = try system.spawn(SimpleActor, SimpleActor.init("Simple"));
    std.log.info("✅ Spawned actor: {}", .{actor.getId()});

    // Wait for actor to start
    std.time.sleep(50 * std.time.ns_per_ms);

    // Send ONE message and wait
    std.log.info("📤 Sending single message...", .{});
    try actor.send([]const u8, "test", allocator);

    // Wait for processing
    std.log.info("⏳ Waiting for message processing...", .{});
    std.time.sleep(200 * std.time.ns_per_ms);

    // Check stats
    const stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("📊 System stats:", .{});
    stats.print();

    // Graceful shutdown
    std.log.info("🛑 Shutting down...", .{});
    system.shutdown();

    std.log.info("✅ === Test Complete ===", .{});
}
