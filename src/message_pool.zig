const std = @import("std");
const Allocator = std.mem.Allocator;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;

// Zero-copy message with pre-allocated pools
pub const FastMessage = struct {
    const Self = @This();

    // Message types optimized for performance
    pub const Type = enum(u8) {
        user_string,
        user_int,
        user_float,
        system_ping,
        system_pong,
        system_stop,
        control_shutdown,
    };

    // Compact message structure - 64 bytes total
    msg_type: Type,
    actor_id: u32,
    sender_id: u32,
    sequence: u64,

    // Union for different payload types - zero allocation
    payload: union {
        string: [32]u8, // Inline string storage
        int_val: i64,
        float_val: f64,
        none: void,
    },

    payload_len: u8, // For string payloads
    _padding: [7]u8 = undefined, // Align to 64 bytes

    pub fn createUserString(actor_id: u32, sender_id: u32, sequence: u64, data: []const u8) Self {
        var msg = Self{
            .msg_type = .user_string,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .string = undefined },
            .payload_len = @min(data.len, 32),
            ._padding = undefined,
        };

        @memcpy(msg.payload.string[0..msg.payload_len], data[0..msg.payload_len]);
        return msg;
    }

    pub fn createUserInt(actor_id: u32, sender_id: u32, sequence: u64, value: i64) Self {
        return Self{
            .msg_type = .user_int,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .int_val = value },
            .payload_len = 0,
            ._padding = undefined,
        };
    }

    pub fn createSystemPing(actor_id: u32, sender_id: u32, sequence: u64) Self {
        return Self{
            .msg_type = .system_ping,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .none = {} },
            .payload_len = 0,
            ._padding = undefined,
        };
    }

    pub fn getString(self: *const Self) []const u8 {
        if (self.msg_type == .user_string) {
            return self.payload.string[0..self.payload_len];
        }
        return "";
    }

    pub fn getInt(self: *const Self) i64 {
        if (self.msg_type == .user_int) {
            return self.payload.int_val;
        }
        return 0;
    }
};

// High-performance message pool with lock-free allocation
pub const MessagePool = struct {
    const Self = @This();
    const POOL_SIZE = 65535; // 64K-1 pre-allocated messages (queue capacity - 1)

    messages: []FastMessage,
    free_queue: LockFreeQueue(*FastMessage),
    allocator: Allocator,
    sequence_counter: std.atomic.Value(u64),

    pub fn init(allocator: Allocator) !Self {
        // Pre-allocate all messages
        const messages = try allocator.alloc(FastMessage, POOL_SIZE);
        var free_queue = LockFreeQueue(*FastMessage).init();

        // Add all messages to free queue
        for (messages) |*msg| {
            if (!free_queue.push(msg)) {
                return error.PoolInitFailed;
            }
        }

        return Self{
            .messages = messages,
            .free_queue = free_queue,
            .allocator = allocator,
            .sequence_counter = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.messages);
    }

    pub fn acquire(self: *Self) ?*FastMessage {
        return self.free_queue.pop();
    }

    pub fn release(self: *Self, msg: *FastMessage) void {
        // Reset message for reuse - manually clear fields
        msg.msg_type = .user_string;
        msg.actor_id = 0;
        msg.sender_id = 0;
        msg.sequence = 0;
        msg.payload = .{ .none = {} };
        msg.payload_len = 0;

        if (!self.free_queue.push(msg)) {
            // This should never happen in a properly sized pool
            std.log.warn("Failed to return message to pool - pool may be full", .{});
        }
    }

    pub fn nextSequence(self: *Self) u64 {
        return self.sequence_counter.fetchAdd(1, .monotonic);
    }

    pub fn getStats(self: *Self) PoolStats {
        return PoolStats{
            .total_messages = POOL_SIZE,
            .available_messages = self.free_queue.size(),
            .used_messages = POOL_SIZE - self.free_queue.size(),
        };
    }
};

pub const PoolStats = struct {
    total_messages: u32,
    available_messages: u32,
    used_messages: u32,
};

// Batch message operations for maximum throughput
pub const MessageBatch = struct {
    const Self = @This();
    const MAX_BATCH_SIZE = 1024;

    messages: [MAX_BATCH_SIZE]*FastMessage,
    count: u32,

    pub fn init() Self {
        return Self{
            .messages = undefined,
            .count = 0,
        };
    }

    pub fn add(self: *Self, msg: *FastMessage) bool {
        if (self.count >= MAX_BATCH_SIZE) return false;

        self.messages[self.count] = msg;
        self.count += 1;
        return true;
    }

    pub fn clear(self: *Self) void {
        self.count = 0;
    }

    pub fn getMessages(self: *const Self) []const *FastMessage {
        return self.messages[0..self.count];
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.count == 0;
    }

    pub fn isFull(self: *const Self) bool {
        return self.count >= MAX_BATCH_SIZE;
    }
};

test "fast message creation" {
    const testing = std.testing;

    const msg = FastMessage.createUserString(1, 2, 100, "hello");
    try testing.expect(msg.msg_type == .user_string);
    try testing.expect(msg.actor_id == 1);
    try testing.expect(msg.sender_id == 2);
    try testing.expect(msg.sequence == 100);
    try testing.expectEqualStrings("hello", msg.getString());
}

test "message pool operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try MessagePool.init(allocator);
    defer pool.deinit();

    // Test acquire/release
    const msg1 = pool.acquire();
    try testing.expect(msg1 != null);

    const msg2 = pool.acquire();
    try testing.expect(msg2 != null);
    try testing.expect(msg1 != msg2);

    pool.release(msg1.?);
    pool.release(msg2.?);

    // Test stats
    const stats = pool.getStats();
    try testing.expect(stats.total_messages > 0);
}

test "message batch operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try MessagePool.init(allocator);
    defer pool.deinit();

    var batch = MessageBatch.init();
    try testing.expect(batch.isEmpty());

    // Add messages to batch
    for (0..10) |_| {
        if (pool.acquire()) |msg| {
            try testing.expect(batch.add(msg));
        }
    }

    try testing.expect(batch.count == 10);

    // Release all messages
    for (batch.getMessages()) |msg| {
        pool.release(msg);
    }
}
