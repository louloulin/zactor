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

    pub fn createUserFloat(actor_id: u32, sender_id: u32, sequence: u64, value: f64) Self {
        return Self{
            .msg_type = .user_float,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .float_val = value },
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
        return switch (self.msg_type) {
            .user_string => self.payload.string[0..self.payload_len],
            else => "", // 安全地处理非字符串类型
        };
    }

    pub fn getInt(self: *const Self) i64 {
        return switch (self.msg_type) {
            .user_int => self.payload.int_val,
            else => 0, // 安全地处理非整数类型
        };
    }

    pub fn getFloat(self: *const Self) f64 {
        return switch (self.msg_type) {
            .user_float => self.payload.float_val,
            else => 0.0, // 安全地处理非浮点类型
        };
    }

    // 类型安全检查
    pub fn isString(self: *const Self) bool {
        return self.msg_type == .user_string;
    }

    pub fn isInt(self: *const Self) bool {
        return self.msg_type == .user_int;
    }

    pub fn isFloat(self: *const Self) bool {
        return self.msg_type == .user_float;
    }

    pub fn isSystem(self: *const Self) bool {
        return switch (self.msg_type) {
            .system_ping, .system_pong, .system_stop => true,
            else => false,
        };
    }

    // 消息完整性验证
    pub fn validate(self: *const Self) bool {
        return switch (self.msg_type) {
            .user_string => self.payload_len <= 32, // 字符串长度不能超过缓冲区
            .user_int, .user_float => self.payload_len == 0, // 数值类型不使用payload_len
            .system_ping, .system_pong, .system_stop => self.payload_len == 0, // 系统消息不使用payload_len
            .control_shutdown => self.payload_len == 0, // 控制消息不使用payload_len
        };
    }

    // 调试信息
    pub fn debugInfo(self: *const Self) void {
        std.log.debug("Message: type={}, actor={}, sender={}, seq={}, len={}", .{
            self.msg_type,
            self.actor_id,
            self.sender_id,
            self.sequence,
            self.payload_len,
        });
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

        // 初始化所有消息到有效状态
        for (messages) |*msg| {
            // 初始化为有效的默认状态
            msg.* = FastMessage{
                .msg_type = .user_string,
                .actor_id = 0,
                .sender_id = 0,
                .sequence = 0,
                .payload = .{ .string = [_]u8{0} ** 32 },
                .payload_len = 0,
                ._padding = undefined,
            };

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
        if (self.free_queue.pop()) |msg| {
            // 验证获取的消息是否处于有效状态
            if (!msg.validate()) {
                std.log.warn("Acquired invalid message, resetting...", .{});
                self.resetMessage(msg);
            }
            return msg;
        }
        return null;
    }

    // 内部方法：重置消息到安全状态
    fn resetMessage(self: *Self, msg: *FastMessage) void {
        _ = self;
        msg.* = FastMessage{
            .msg_type = .user_string,
            .actor_id = 0,
            .sender_id = 0,
            .sequence = 0,
            .payload = .{ .string = [_]u8{0} ** 32 },
            .payload_len = 0,
            ._padding = undefined,
        };
    }

    pub fn release(self: *Self, msg: *FastMessage) void {
        // 验证消息在释放前的状态
        if (!msg.validate()) {
            std.log.warn("Releasing invalid message: type={}, len={}", .{ msg.msg_type, msg.payload_len });
        }

        // 重置消息到安全状态
        self.resetMessage(msg);

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
