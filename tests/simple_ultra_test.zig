const std = @import("std");
const UltraFastActorSystem = @import("src/ultra_fast_system.zig").UltraFastActorSystem;
const SystemConfig = @import("src/ultra_fast_system.zig").SystemConfig;
const ThroughputActor = @import("ultra_perf_test.zig").ThroughputActor;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === Simple Ultra Test ===", .{});

    // Create minimal system
    const system_config = SystemConfig{
        .worker_threads = 1,
        .io_threads = 1,
    };
    
    var system = try UltraFastActorSystem.init(allocator, system_config);
    defer system.deinit();

    std.log.info("✅ System created", .{});

    // Start the system
    try system.start();
    defer system.stop();

    std.log.info("✅ System started", .{});

    // Spawn one actor
    const actor = ThroughputActor.init("test");
    const actor_ref = try system.spawn(ThroughputActor, actor);

    std.log.info("✅ Actor spawned: {}", .{actor_ref.id});

    // Wait a bit
    std.time.sleep(100 * std.time.ns_per_ms);

    // Send a few messages
    for (0..5) |i| {
        const sent = try actor_ref.sendString("test");
        std.log.info("Message {} sent: {}", .{ i, sent });
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    // Wait for processing
    std.time.sleep(500 * std.time.ns_per_ms);

    // Get stats
    const stats = system.getStats();
    std.log.info("Messages sent: {}", .{stats.messages_sent.load(.monotonic)});
    std.log.info("Messages processed: {}", .{stats.messages_processed.load(.monotonic)});

    std.log.info("✅ === Simple Ultra Test Complete ===", .{});
}
