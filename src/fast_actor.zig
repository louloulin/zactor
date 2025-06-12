const std = @import("std");
const Allocator = std.mem.Allocator;
const FastMessage = @import("message_pool.zig").FastMessage;
const MessageBatch = @import("message_pool.zig").MessageBatch;
const FastMailbox = @import("fast_mailbox.zig").FastMailbox;

// Ultra-high-performance actor with zero-allocation message processing
pub const FastActor = struct {
    const Self = @This();
    const MAX_BATCH_SIZE = 1024;

    // Core actor data
    id: u32,
    mailbox: FastMailbox,
    behavior: *anyopaque,
    vtable: *const ActorVTable,

    // Performance optimizations
    message_buffer: [MAX_BATCH_SIZE]*FastMessage,
    processed_count: std.atomic.Value(u64),
    last_process_time: std.atomic.Value(i128),

    // Actor state
    state: ActorState,
    allocator: Allocator,

    pub fn init(
        id: u32,
        behavior: *anyopaque,
        vtable: *const ActorVTable,
        allocator: Allocator,
    ) Self {
        return Self{
            .id = id,
            .mailbox = FastMailbox.init(),
            .behavior = behavior,
            .vtable = vtable,
            .message_buffer = undefined,
            .processed_count = std.atomic.Value(u64).init(0),
            .last_process_time = std.atomic.Value(i128).init(std.time.nanoTimestamp()),
            .state = .created,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mailbox.deinit();
    }

    // High-performance batch message processing
    pub fn processBatch(self: *Self, batch: *MessageBatch) u64 {
        _ = batch;
        if (self.state != .running) return 0;

        // Receive messages in batch
        const received = self.mailbox.receiveBatchDirect(self.message_buffer[0..]);
        if (received == 0) return 0;

        // Process all messages in the batch
        var processed: u64 = 0;
        for (self.message_buffer[0..received]) |msg| {
            if (self.processMessage(msg)) {
                processed += 1;
            }
        }

        // Update statistics
        _ = self.processed_count.fetchAdd(processed, .monotonic);
        self.last_process_time.store(std.time.nanoTimestamp(), .monotonic);

        return processed;
    }

    // Process a single message (optimized for speed)
    fn processMessage(self: *Self, msg: *FastMessage) bool {
        switch (msg.msg_type) {
            .user_string, .user_int, .user_float => {
                return self.vtable.receive(self.behavior, msg);
            },
            .system_ping => {
                // Handle ping immediately
                return true;
            },
            .system_pong => {
                // Handle pong immediately
                return true;
            },
            .system_stop => {
                self.state = .stopping;
                return true;
            },
            .control_shutdown => {
                self.state = .stopped;
                return true;
            },
        }
    }

    // Send message to this actor
    pub fn send(self: *Self, msg: *FastMessage) bool {
        return self.mailbox.send(msg);
    }

    // Send batch of messages
    pub fn sendBatch(self: *Self, batch: *const MessageBatch) u32 {
        return self.mailbox.sendBatch(batch);
    }

    // Actor lifecycle
    pub fn start(self: *Self) void {
        self.state = .running;
        self.vtable.preStart(self.behavior);
    }

    pub fn stop(self: *Self) void {
        self.state = .stopping;
        self.vtable.preStop(self.behavior);
        self.state = .stopped;
        self.vtable.postStop(self.behavior);
    }

    // Performance monitoring
    pub fn getStats(self: *Self) ActorStats {
        const mailbox_stats = self.mailbox.getStats();
        return ActorStats{
            .id = self.id,
            .state = self.state,
            .messages_processed = self.processed_count.load(.monotonic),
            .last_process_time = self.last_process_time.load(.monotonic),
            .mailbox_size = mailbox_stats.current_size,
            .messages_dropped = mailbox_stats.messages_dropped,
        };
    }

    pub fn resetStats(self: *Self) void {
        self.processed_count.store(0, .monotonic);
        self.mailbox.resetStats();
    }
};

pub const ActorState = enum {
    created,
    running,
    stopping,
    stopped,
    failed,
};

pub const ActorStats = struct {
    id: u32,
    state: ActorState,
    messages_processed: u64,
    last_process_time: i128,
    mailbox_size: u32,
    messages_dropped: u64,

    pub fn getProcessingRate(self: *const ActorStats, window_ms: u64) f64 {
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(now - self.last_process_time, 1000000);

        if (elapsed_ms == 0 or elapsed_ms > window_ms) return 0.0;

        return @as(f64, @floatFromInt(self.messages_processed * 1000)) / @as(f64, @floatFromInt(elapsed_ms));
    }
};

// Virtual table for actor behaviors
pub const ActorVTable = struct {
    receive: *const fn (behavior: *anyopaque, msg: *FastMessage) bool,
    preStart: *const fn (behavior: *anyopaque) void,
    preStop: *const fn (behavior: *anyopaque) void,
    postStop: *const fn (behavior: *anyopaque) void,
};

// High-performance actor behavior trait
pub fn FastActorBehavior(comptime T: type) type {
    return struct {
        pub fn getVTable() ActorVTable {
            return ActorVTable{
                .receive = receive,
                .preStart = preStart,
                .preStop = preStop,
                .postStop = postStop,
            };
        }

        fn receive(behavior: *anyopaque, msg: *FastMessage) bool {
            const self: *T = @ptrCast(@alignCast(behavior));
            return self.receive(msg);
        }

        fn preStart(behavior: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(behavior));
            if (@hasDecl(T, "preStart")) {
                self.preStart();
            }
        }

        fn preStop(behavior: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(behavior));
            if (@hasDecl(T, "preStop")) {
                self.preStop();
            }
        }

        fn postStop(behavior: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(behavior));
            if (@hasDecl(T, "postStop")) {
                self.postStop();
            }
        }
    };
}

// Example high-performance actor
pub const CounterActor = struct {
    const Self = @This();

    count: std.atomic.Value(u64),
    name: []const u8,

    pub fn init(name: []const u8) Self {
        return Self{
            .count = std.atomic.Value(u64).init(0),
            .name = name,
        };
    }

    pub fn receive(self: *Self, msg: *FastMessage) bool {
        switch (msg.msg_type) {
            .user_int => {
                const value = msg.getInt();
                _ = self.count.fetchAdd(@intCast(value), .monotonic);
                return true;
            },
            .user_string => {
                // Count string length
                const str = msg.getString();
                _ = self.count.fetchAdd(str.len, .monotonic);
                return true;
            },
            else => return true,
        }
    }

    pub fn preStart(self: *Self) void {
        std.log.info("CounterActor '{s}' starting", .{self.name});
    }

    pub fn preStop(self: *Self) void {
        const final_count = self.count.load(.monotonic);
        std.log.info("CounterActor '{s}' stopping (count: {})", .{ self.name, final_count });
    }

    pub fn postStop(self: *Self) void {
        std.log.info("CounterActor '{s}' stopped", .{self.name});
    }

    pub fn getCount(self: *Self) u64 {
        return self.count.load(.monotonic);
    }
};

test "fast actor creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var counter = CounterActor.init("test");
    const vtable = FastActorBehavior(CounterActor).getVTable();

    var actor = FastActor.init(1, &counter, &vtable, allocator);
    defer actor.deinit();

    try testing.expect(actor.id == 1);
    try testing.expect(actor.state == .created);
}

test "fast actor message processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = @import("message_pool.zig").MessagePool.init(allocator) catch return;
    defer pool.deinit();

    var counter = CounterActor.init("test");
    const vtable = FastActorBehavior(CounterActor).getVTable();

    var actor = FastActor.init(1, &counter, &vtable, allocator);
    defer actor.deinit();

    actor.start();

    // Send some messages
    for (0..5) |i| {
        if (pool.acquire()) |msg| {
            msg.* = FastMessage.createUserInt(1, 0, i, @intCast(i + 1));
            _ = actor.send(msg);
        }
    }

    // Process messages
    var batch = MessageBatch.init();
    const processed = actor.processBatch(&batch);
    try testing.expect(processed == 5);

    // Check counter value (1+2+3+4+5 = 15)
    try testing.expect(counter.getCount() == 15);

    actor.stop();
}
