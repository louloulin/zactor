const std = @import("std");
const zactor = @import("zactor");

// Message types for ping-pong
const PingMessage = struct {
    count: u32,
    sender_id: zactor.ActorId,
};

const PongMessage = struct {
    count: u32,
    sender_id: zactor.ActorId,
};

// Ping actor that initiates the ping-pong game
const PingActor = struct {
    const Self = @This();
    
    name: []const u8,
    pong_partner: ?zactor.ActorRef,
    ping_count: u32,
    max_pings: u32,
    
    pub fn init(name: []const u8, max_pings: u32) Self {
        return Self{
            .name = name,
            .pong_partner = null,
            .ping_count = 0,
            .max_pings = max_pings,
        };
    }
    
    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.Actor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                // Try to deserialize as different message types
                if (self.tryHandlePongMessage(message, context)) {
                    // Handled as pong message
                } else if (self.tryHandlePartnerMessage(message, context)) {
                    // Handled as partner assignment
                } else {
                    std.log.warn("PingActor '{}' received unknown message", .{self.name});
                }
            },
            .system => {
                switch (message.data.system) {
                    .start => {
                        std.log.info("PingActor '{}' received start signal", .{self.name});
                        if (self.pong_partner) |partner| {
                            try self.sendPing(partner, context);
                        }
                    },
                    else => {},
                }
            },
            .control => {},
        }
    }
    
    fn tryHandlePongMessage(self: *Self, message: zactor.Message, context: *zactor.Actor.ActorContext) bool {
        // Simple string-based message parsing for demo
        if (std.mem.startsWith(u8, message.data.user.payload, "\"pong:")) {
            // Extract count from message like "pong:5"
            const colon_pos = std.mem.indexOf(u8, message.data.user.payload, ":") orelse return false;
            const end_quote = std.mem.lastIndexOf(u8, message.data.user.payload, "\"") orelse return false;
            
            if (colon_pos + 1 >= end_quote) return false;
            
            const count_str = message.data.user.payload[colon_pos + 1 .. end_quote];
            const count = std.fmt.parseInt(u32, count_str, 10) catch return false;
            
            std.log.info("PingActor '{}' received pong #{}", .{ self.name, count });
            
            if (count < self.max_pings) {
                if (self.pong_partner) |partner| {
                    self.sendPing(partner, context) catch |err| {
                        std.log.err("Failed to send ping: {}", .{err});
                    };
                }
            } else {
                std.log.info("PingActor '{}' finished ping-pong game after {} rounds", .{ self.name, count });
            }
            return true;
        }
        return false;
    }
    
    fn tryHandlePartnerMessage(self: *Self, message: zactor.Message, context: *zactor.Actor.ActorContext) bool {
        if (std.mem.startsWith(u8, message.data.user.payload, "\"partner:")) {
            // Extract actor ID from message like "partner:123"
            const colon_pos = std.mem.indexOf(u8, message.data.user.payload, ":") orelse return false;
            const end_quote = std.mem.lastIndexOf(u8, message.data.user.payload, "\"") orelse return false;
            
            if (colon_pos + 1 >= end_quote) return false;
            
            const id_str = message.data.user.payload[colon_pos + 1 .. end_quote];
            const partner_id = std.fmt.parseInt(zactor.ActorId, id_str, 10) catch return false;
            
            // Look up the partner actor
            if (context.system.findActor(partner_id)) |partner| {
                self.pong_partner = partner;
                std.log.info("PingActor '{}' set partner to actor {}", .{ self.name, partner_id });
                
                // Start the ping-pong game
                self.sendPing(partner, context) catch |err| {
                    std.log.err("Failed to send initial ping: {}", .{err});
                };
            }
            return true;
        }
        return false;
    }
    
    fn sendPing(self: *Self, partner: zactor.ActorRef, context: *zactor.Actor.ActorContext) !void {
        self.ping_count += 1;
        const ping_msg = try std.fmt.allocPrint(context.allocator, "ping:{}", .{self.ping_count});
        defer context.allocator.free(ping_msg);
        
        std.log.info("PingActor '{}' sending ping #{}", .{ self.name, self.ping_count });
        try partner.send([]const u8, ping_msg, context.allocator);
    }
    
    pub fn preStart(self: *Self, context: *zactor.Actor.ActorContext) !void {
        _ = context;
        std.log.info("PingActor '{}' starting", .{self.name});
    }
    
    pub fn postStop(self: *Self, context: *zactor.Actor.ActorContext) !void {
        _ = context;
        std.log.info("PingActor '{}' stopping after {} pings", .{ self.name, self.ping_count });
    }
    
    pub fn preRestart(self: *Self, context: *zactor.Actor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("PingActor '{}' restarting due to: {}", .{ self.name, reason });
    }
    
    pub fn postRestart(self: *Self, context: *zactor.Actor.ActorContext) !void {
        _ = context;
        std.log.info("PingActor '{}' restarted", .{self.name});
    }
};

// Pong actor that responds to pings
const PongActor = struct {
    const Self = @This();
    
    name: []const u8,
    pong_count: u32,
    
    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .pong_count = 0,
        };
    }
    
    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.Actor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                if (self.tryHandlePingMessage(message, context)) {
                    // Handled as ping message
                } else {
                    std.log.warn("PongActor '{}' received unknown message", .{self.name});
                }
            },
            .system => {},
            .control => {},
        }
    }
    
    fn tryHandlePingMessage(self: *Self, message: zactor.Message, context: *zactor.Actor.ActorContext) bool {
        if (std.mem.startsWith(u8, message.data.user.payload, "\"ping:")) {
            // Extract count from message like "ping:5"
            const colon_pos = std.mem.indexOf(u8, message.data.user.payload, ":") orelse return false;
            const end_quote = std.mem.lastIndexOf(u8, message.data.user.payload, "\"") orelse return false;
            
            if (colon_pos + 1 >= end_quote) return false;
            
            const count_str = message.data.user.payload[colon_pos + 1 .. end_quote];
            const count = std.fmt.parseInt(u32, count_str, 10) catch return false;
            
            std.log.info("PongActor '{}' received ping #{}", .{ self.name, count });
            
            // Send pong back to sender
            if (message.sender) |sender_id| {
                if (context.system.findActor(sender_id)) |sender| {
                    self.sendPong(sender, count, context) catch |err| {
                        std.log.err("Failed to send pong: {}", .{err});
                    };
                }
            }
            return true;
        }
        return false;
    }
    
    fn sendPong(self: *Self, sender: zactor.ActorRef, count: u32, context: *zactor.Actor.ActorContext) !void {
        self.pong_count += 1;
        const pong_msg = try std.fmt.allocPrint(context.allocator, "pong:{}", .{count});
        defer context.allocator.free(pong_msg);
        
        std.log.info("PongActor '{}' sending pong #{}", .{ self.name, count });
        try sender.send([]const u8, pong_msg, context.allocator);
    }
    
    pub fn preStart(self: *Self, context: *zactor.Actor.ActorContext) !void {
        _ = context;
        std.log.info("PongActor '{}' starting", .{self.name});
    }
    
    pub fn postStop(self: *Self, context: *zactor.Actor.ActorContext) !void {
        _ = context;
        std.log.info("PongActor '{}' stopping after {} pongs", .{ self.name, self.pong_count });
    }
    
    pub fn preRestart(self: *Self, context: *zactor.Actor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("PongActor '{}' restarting due to: {}", .{ self.name, reason });
    }
    
    pub fn postRestart(self: *Self, context: *zactor.Actor.ActorContext) !void {
        _ = context;
        std.log.info("PongActor '{}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .scheduler_threads = 2,
        .enable_work_stealing = true,
    });
    
    std.log.info("=== ZActor Ping-Pong Example ===");
    
    // Create actor system
    var system = try zactor.ActorSystem.init("ping-pong-system", allocator);
    defer system.deinit();
    
    // Start the system
    try system.start();
    
    // Spawn actors
    const ping_actor = try system.spawn(PingActor, PingActor.init("Ping", 5));
    const pong_actor = try system.spawn(PongActor, PongActor.init("Pong"));
    
    std.log.info("Spawned PingActor {} and PongActor {}", .{ ping_actor.getId(), pong_actor.getId() });
    
    // Set up the partnership
    const partner_msg = try std.fmt.allocPrint(allocator, "partner:{}", .{pong_actor.getId()});
    defer allocator.free(partner_msg);
    
    try ping_actor.send([]const u8, partner_msg, allocator);
    
    // Wait for the ping-pong game to complete
    std.log.info("Starting ping-pong game...");
    std.time.sleep(1000 * std.time.ns_per_ms); // 1 second
    
    // Get final statistics
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();
    
    std.log.info("Ping-pong game completed!");
    
    // Shutdown
    system.shutdown();
    std.log.info("=== Example Complete ===");
}
