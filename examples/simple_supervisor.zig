const std = @import("std");
const zactor = @import("zactor");

// Simple worker actor for demonstration
const SimpleWorker = struct {
    const Self = @This();
    
    id: u32,
    work_count: u32,
    
    pub fn init(id: u32) Self {
        return Self{
            .id = id,
            .work_count = 0,
        };
    }
    
    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.data) {
            .user => |user_msg| {
                const parsed = try user_msg.get([]const u8, context.allocator);
                defer parsed.deinit();
                const data = parsed.value;
                
                if (std.mem.eql(u8, data, "work")) {
                    self.work_count += 1;
                    std.log.info("Worker {} completed task #{}", .{ self.id, self.work_count });
                } else if (std.mem.eql(u8, data, "status")) {
                    std.log.info("Worker {}: {} tasks completed", .{ self.id, self.work_count });
                }
            },
            .system => |sys_msg| {
                switch (sys_msg) {
                    .start => std.log.info("Worker {} started", .{self.id}),
                    .stop => std.log.info("Worker {} stopped", .{self.id}),
                    .restart => {
                        std.log.info("Worker {} restarted", .{self.id});
                        self.work_count = 0; // Reset on restart
                    },
                    else => {},
                }
            },
            .control => {},
        }
    }
    
    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Worker {} starting up", .{self.id});
    }
    
    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Worker {} shutting down", .{self.id});
    }
    
    pub fn preStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Worker {} preparing to stop", .{self.id});
    }
    
    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.warn("Worker {} restarting due to: {}", .{ self.id, reason });
    }
    
    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Worker {} restarted successfully", .{self.id});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== Simple Supervisor Example ===", .{});
    
    // Initialize ZActor
    zactor.init(.{
        .max_actors = 20,
        .scheduler_threads = 2,
        .enable_work_stealing = true,
    });
    
    // Create actor system
    var system = try zactor.ActorSystem.init("simple-supervisor", allocator);
    defer system.deinit();
    
    // Configure supervision strategy
    system.setSupervisorConfig(.{
        .strategy = .restart,
        .max_restarts = 3,
        .restart_window_seconds = 30,
        .backoff_initial_ms = 100,
        .backoff_max_ms = 1000,
        .backoff_multiplier = 2.0,
    });
    
    try system.start();
    
    // Create some workers
    const worker1 = SimpleWorker.init(1);
    const worker2 = SimpleWorker.init(2);
    const worker3 = SimpleWorker.init(3);
    
    const worker_ref1 = try system.spawn(SimpleWorker, worker1);
    const worker_ref2 = try system.spawn(SimpleWorker, worker2);
    const worker_ref3 = try system.spawn(SimpleWorker, worker3);
    
    std.log.info("Created 3 workers under supervision", .{});
    
    // Send some work
    try worker_ref1.send([]const u8, "work", allocator);
    try worker_ref2.send([]const u8, "work", allocator);
    try worker_ref3.send([]const u8, "work", allocator);
    
    // Wait a bit
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Check status
    try worker_ref1.send([]const u8, "status", allocator);
    try worker_ref2.send([]const u8, "status", allocator);
    try worker_ref3.send([]const u8, "status", allocator);
    
    // Wait a bit more
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Print supervisor stats
    const stats = system.getSupervisorStats();
    stats.print();
    
    // Print system metrics
    std.log.info("\n--- System Metrics ---", .{});
    zactor.metrics.print();
    
    // Graceful shutdown
    std.log.info("\n--- Shutting Down ---", .{});
    system.shutdown();
    
    std.log.info("=== Example Complete ===", .{});
}
