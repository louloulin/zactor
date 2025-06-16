const std = @import("std");
const zactor = @import("zactor");

// Simple benchmark actor that just counts messages
const BenchmarkActor = struct {
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
                if (std.mem.eql(u8, message.data.user.payload, "\"increment\"")) {
                    self.count += 1;
                }
            },
            .system => {},
            .control => {},
        }
        _ = context;
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("BenchmarkActor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("BenchmarkActor '{s}' stopping with count: {}", .{ self.name, self.count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("BenchmarkActor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("BenchmarkActor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZActor Performance Benchmark ===", .{});

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .scheduler_threads = 2,
        .enable_work_stealing = true,
    });

    // Create actor system
    var system = try zactor.ActorSystem.init("benchmark-system", allocator);
    defer system.deinit();

    // Start the system
    try system.start();

    // Spawn a single actor
    const actor_ref = try system.spawn(BenchmarkActor, BenchmarkActor.init("Benchmark"));

    std.log.info("Spawned BenchmarkActor {}", .{actor_ref.getId()});

    // Measure message sending throughput
    const start_time = std.time.nanoTimestamp();
    const num_messages = 1000;

    // Send messages
    for (0..num_messages) |i| {
        try actor_ref.send([]const u8, "increment", allocator);
        _ = i;
    }

    const send_end_time = std.time.nanoTimestamp();
    const send_duration_ns = send_end_time - start_time;

    std.log.info("All {} messages sent in {d:.2} ms", .{ num_messages, @as(f64, @floatFromInt(send_duration_ns)) / 1_000_000.0 });

    // Wait for processing
    std.log.info("Waiting for message processing...", .{});
    std.time.sleep(1000 * std.time.ns_per_ms); // 1 second

    // Calculate throughput
    const total_duration_ns = std.time.nanoTimestamp() - start_time;
    const throughput = @as(f64, @floatFromInt(num_messages)) / (@as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0);

    std.log.info("Throughput: {d:.0} messages/second", .{throughput});

    // Get final statistics
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();

    std.log.info("Benchmark completed!", .{});

    // Shutdown
    system.shutdown();
    std.log.info("=== Benchmark Complete ===", .{});
}