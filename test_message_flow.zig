const std = @import("std");
const zactor = @import("src/zactor.zig");

// Simple test actor that logs everything
const TestActor = struct {
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
        
        std.log.info("🎯 Actor '{s}' received message #{} (ID: {}, Type: {})", .{ 
            self.name, 
            self.message_count,
            message.id,
            message.message_type
        });

        switch (message.message_type) {
            .user => {
                const user_data = message.data.user;
                std.log.info("💬 Actor '{s}' processing user message (payload size: {})", .{self.name, user_data.payload.len});
                
                const parsed = user_data.get([]const u8, context.allocator) catch |err| {
                    std.log.warn("⚠️ Actor '{s}' failed to parse message: {}", .{self.name, err});
                    return;
                };
                defer parsed.deinit();
                
                const msg_content = parsed.value;
                std.log.info("📝 Actor '{s}' message content: '{s}'", .{self.name, msg_content});
            },
            .system => {
                std.log.info("🔧 Actor '{s}' processing system message: {}", .{self.name, message.data.system});
            },
            .control => {
                std.log.info("🎛️ Actor '{s}' processing control message: {}", .{self.name, message.data.control});
            },
        }
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🚀 Actor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🛑 Actor '{s}' stopping (processed {} messages)", .{self.name, self.message_count});
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("🔄 Actor '{s}' restarting due to: {}", .{self.name, reason});
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🔄 Actor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🧪 === Message Flow Test ===", .{});

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .mailbox_capacity = 100,
        .scheduler_threads = 1, // Use single thread for easier debugging
        .enable_work_stealing = false,
    });

    // Create actor system
    var system = try zactor.ActorSystem.init("message-flow-test", allocator);
    defer system.deinit();

    // Start the system
    try system.start();
    std.log.info("✅ Actor system started", .{});

    // Give worker threads time to start
    std.time.sleep(50 * std.time.ns_per_ms);

    // Spawn test actor
    std.log.info("🎭 Spawning test actor...", .{});
    const actor = try system.spawn(TestActor, TestActor.init("TestActor"));
    std.log.info("✅ Spawned actor: {}", .{actor.getId()});

    // Wait for actor to start
    std.time.sleep(50 * std.time.ns_per_ms);

    // Check mailbox before sending messages
    std.log.info("📬 Checking mailbox before sending messages...", .{});
    std.log.info("📬 Mailbox empty: {}", .{actor.mailbox.isEmpty()});
    std.log.info("📬 Mailbox size: {}", .{actor.mailbox.size()});

    // Send test messages one by one with verification
    std.log.info("📤 Sending test message 1...", .{});
    try actor.send([]const u8, "hello", allocator);
    
    std.log.info("📬 Mailbox after message 1 - empty: {}, size: {}", .{actor.mailbox.isEmpty(), actor.mailbox.size()});
    
    // Wait for processing
    std.time.sleep(100 * std.time.ns_per_ms);
    
    std.log.info("📤 Sending test message 2...", .{});
    try actor.send([]const u8, "world", allocator);
    
    std.log.info("📬 Mailbox after message 2 - empty: {}, size: {}", .{actor.mailbox.isEmpty(), actor.mailbox.size()});
    
    // Wait for processing
    std.time.sleep(100 * std.time.ns_per_ms);

    std.log.info("📤 Sending system message...", .{});
    try actor.sendSystem(.ping);
    
    std.log.info("📬 Mailbox after system message - empty: {}, size: {}", .{actor.mailbox.isEmpty(), actor.mailbox.size()});
    
    // Wait for processing
    std.time.sleep(100 * std.time.ns_per_ms);

    // Check final stats
    const stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("📊 Final system stats:", .{});
    stats.print();

    // Graceful shutdown
    std.log.info("🛑 Shutting down system...", .{});
    system.shutdown();

    std.log.info("✅ === Test Complete ===", .{});
}
