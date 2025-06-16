const std = @import("std");
const UltraFastActorSystem = @import("src/ultra_fast_system.zig").UltraFastActorSystem;
const SystemConfig = @import("src/ultra_fast_system.zig").SystemConfig;
const BatchMessage = @import("src/ultra_fast_system.zig").BatchMessage;
const FastMessage = @import("src/message_pool.zig").FastMessage;
const CounterActor = @import("src/fast_actor.zig").CounterActor;

// Ultra-high-performance test actor optimized for maximum throughput
pub const ThroughputActor = struct {
    const Self = @This();

    name: []const u8,
    message_count: std.atomic.Value(u64),
    start_time: i128,
    last_report_time: i128,
    last_report_count: u64,

    pub fn init(name: []const u8) Self {
        const now = std.time.nanoTimestamp();
        return Self{
            .name = name,
            .message_count = std.atomic.Value(u64).init(0),
            .start_time = now,
            .last_report_time = now,
            .last_report_count = 0,
        };
    }

    pub fn receive(self: *Self, msg: *FastMessage) bool {
        const count = self.message_count.fetchAdd(1, .monotonic) + 1;

        // Report progress every 100k messages
        if (count % 100000 == 0) {
            const now = std.time.nanoTimestamp();
            const elapsed_ms = @divTrunc(now - self.last_report_time, 1000000);
            const messages_in_window = count - self.last_report_count;

            if (elapsed_ms > 0) {
                const rate = @divTrunc(messages_in_window * 1000, @as(u64, @intCast(elapsed_ms)));
                std.log.info("Actor '{s}' processed {}k messages (rate: {} msg/s)", .{ self.name, count / 1000, rate });
            }

            self.last_report_time = now;
            self.last_report_count = count;
        }

        // Minimal processing to maximize throughput
        switch (msg.msg_type) {
            .user_string => {
                // Just access the string to ensure it's processed
                _ = msg.getString();
            },
            .user_int => {
                // Just access the int to ensure it's processed
                _ = msg.getInt();
            },
            .system_ping => {
                // Handle ping
            },
            else => {},
        }

        return true;
    }

    pub fn preStart(self: *Self) void {
        std.log.info("🚀 ThroughputActor '{s}' starting", .{self.name});
        self.start_time = std.time.nanoTimestamp();
        self.last_report_time = self.start_time;
    }

    pub fn preStop(self: *Self) void {
        const final_count = self.message_count.load(.monotonic);
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(now - self.start_time, 1000000);

        if (elapsed_ms > 0) {
            const rate = @divTrunc(final_count * 1000, @as(u64, @intCast(elapsed_ms)));
            std.log.info("🏁 ThroughputActor '{s}' final: {} messages in {}ms (rate: {} msg/s)", .{ self.name, final_count, elapsed_ms, rate });
        }
    }

    pub fn postStop(self: *Self) void {
        std.log.info("🛑 ThroughputActor '{s}' stopped", .{self.name});
    }

    pub fn getCount(self: *Self) u64 {
        return self.message_count.load(.monotonic);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === ULTRA PERFORMANCE TEST - TARGET: 1M MSG/S ===", .{});

    // Test configurations for progressive scaling
    const test_configs = [_]struct {
        actors: u32,
        messages_per_actor: u32,
        worker_threads: u32,
        use_batch: bool,
        name: []const u8,
    }{
        .{ .actors = 1, .messages_per_actor = 100000, .worker_threads = 1, .use_batch = false, .name = "Single Actor 100k" },
        .{ .actors = 1, .messages_per_actor = 500000, .worker_threads = 2, .use_batch = true, .name = "Single Actor 500k Batch" },
        .{ .actors = 4, .messages_per_actor = 250000, .worker_threads = 4, .use_batch = true, .name = "4 Actors 1M Total" },
        .{ .actors = 8, .messages_per_actor = 250000, .worker_threads = 8, .use_batch = true, .name = "8 Actors 2M Total" },
        .{ .actors = 16, .messages_per_actor = 125000, .worker_threads = 16, .use_batch = true, .name = "16 Actors 2M Total" },
    };

    for (test_configs) |config| {
        std.log.info("\n🧪 Testing: {s}", .{config.name});
        std.log.info("   {} actors × {} messages = {} total", .{ config.actors, config.messages_per_actor, config.actors * config.messages_per_actor });

        // Create ultra-fast system
        const system_config = SystemConfig{
            .worker_threads = config.worker_threads,
            .io_threads = 1,
        };

        var system = try UltraFastActorSystem.init(allocator, system_config);
        defer system.deinit();

        // Start the system
        try system.start();
        defer system.stop();

        // Spawn actors
        var actors = std.ArrayList(@import("src/ultra_fast_system.zig").ActorRef).init(allocator);
        defer actors.deinit();

        for (0..config.actors) |i| {
            const actor_name = try std.fmt.allocPrint(allocator, "Perf-{}", .{i});
            defer allocator.free(actor_name);

            const actor = ThroughputActor.init(actor_name);
            const actor_ref = try system.spawn(ThroughputActor, actor);
            try actors.append(actor_ref);
        }

        // Wait for actors to start
        std.time.sleep(50 * std.time.ns_per_ms);

        const total_messages = config.messages_per_actor * config.actors;
        std.log.info("📤 Sending {} total messages...", .{total_messages});

        const test_start = std.time.nanoTimestamp();

        if (config.use_batch) {
            // Use batch sending for maximum throughput
            try sendMessagesBatch(actors.items, config.messages_per_actor);
        } else {
            // Use individual message sending
            try sendMessagesIndividual(actors.items, config.messages_per_actor);
        }

        const send_end = std.time.nanoTimestamp();
        const send_time_ms = @divTrunc(send_end - test_start, 1000000);
        const send_rate = if (send_time_ms > 0) @divTrunc(total_messages * 1000, @as(u64, @intCast(send_time_ms))) else 0;

        std.log.info("📤 Sending completed in {}ms (rate: {} msg/s)", .{ send_time_ms, send_rate });

        // Wait for processing to complete
        std.time.sleep(2000 * std.time.ns_per_ms);

        // Send ping to get final stats
        for (actors.items) |actor| {
            _ = try actor.sendPing();
        }
        std.time.sleep(100 * std.time.ns_per_ms);

        const test_end = std.time.nanoTimestamp();
        const total_time_ms = @divTrunc(test_end - test_start, 1000000);

        // Get system statistics
        const stats = system.getStats();
        system.printStats();

        std.log.info("📊 {s} Results:", .{config.name});
        std.log.info("  Total time: {}ms", .{total_time_ms});
        std.log.info("  Messages sent: {}", .{stats.messages_sent.load(.monotonic)});
        std.log.info("  Messages processed: {}", .{stats.messages_processed.load(.monotonic)});
        std.log.info("  Overall throughput: {d:.0} msg/s", .{stats.throughput});

        // Check if we hit the 1M msg/s target
        if (stats.throughput >= 1000000) {
            std.log.info("🎯 TARGET ACHIEVED! Throughput: {d:.0} msg/s", .{stats.throughput});
        } else {
            std.log.info("📈 Progress: {d:.1}% of 1M msg/s target", .{stats.throughput / 10000});
        }

        // Brief pause between tests
        std.time.sleep(500 * std.time.ns_per_ms);
    }

    std.log.info("\n✅ === ULTRA PERFORMANCE TEST COMPLETE ===", .{});
}

fn sendMessagesIndividual(actors: []@import("src/ultra_fast_system.zig").ActorRef, messages_per_actor: u32) !void {
    for (actors) |actor| {
        for (0..messages_per_actor) |i| {
            // Alternate between string and int messages for variety
            if (i % 2 == 0) {
                _ = try actor.sendString("test");
            } else {
                _ = try actor.sendInt(@as(i64, @intCast(i)));
            }
        }
    }
}

fn sendMessagesBatch(actors: []@import("src/ultra_fast_system.zig").ActorRef, messages_per_actor: u32) !void {
    const BATCH_SIZE = 1000;

    for (actors) |actor| {
        var remaining = messages_per_actor;
        var counter: u32 = 0;

        while (remaining > 0) {
            const batch_size = @min(remaining, BATCH_SIZE);
            const batch_messages = try std.heap.page_allocator.alloc(BatchMessage, batch_size);
            defer std.heap.page_allocator.free(batch_messages);

            for (batch_messages, 0..) |*msg, i| {
                if ((counter + @as(u32, @intCast(i))) % 2 == 0) {
                    msg.* = BatchMessage{
                        .msg_type = .user_string,
                        .data = .{ .string = "test" },
                    };
                } else {
                    msg.* = BatchMessage{
                        .msg_type = .user_int,
                        .data = .{ .int_val = @intCast(counter + @as(u32, @intCast(i))) },
                    };
                }
            }

            _ = try actor.sendBatch(batch_messages);
            remaining -= batch_size;
            counter += batch_size;
        }
    }
}
