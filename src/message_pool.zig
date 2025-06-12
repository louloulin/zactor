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
        // 增强类型安全检查
        if (self.msg_type != .user_string) {
            std.log.warn("Attempting to get string from non-string message type: {}", .{self.msg_type});
            return "";
        }
        if (self.payload_len > 32) {
            std.log.warn("String payload length {} exceeds buffer size", .{self.payload_len});
            return "";
        }
        return self.payload.string[0..self.payload_len];
    }

    pub fn getInt(self: *const Self) i64 {
        // 增强类型安全检查
        if (self.msg_type != .user_int) {
            std.log.warn("Attempting to get int from non-int message type: {}", .{self.msg_type});
            return 0;
        }
        return self.payload.int_val;
    }

    pub fn getFloat(self: *const Self) f64 {
        // 增强类型安全检查
        if (self.msg_type != .user_float) {
            std.log.warn("Attempting to get float from non-float message type: {}", .{self.msg_type});
            return 0.0;
        }
        return self.payload.float_val;
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
        // 检查消息类型是否有效
        const type_valid = switch (self.msg_type) {
            .user_string => self.payload_len <= 32, // 字符串长度不能超过缓冲区
            .user_int, .user_float => self.payload_len == 0, // 数值类型不使用payload_len
            .system_ping, .system_pong, .system_stop => self.payload_len == 0, // 系统消息不使用payload_len
            .control_shutdown => self.payload_len == 0, // 控制消息不使用payload_len
        };

        // 检查sequence字段是否表示消息正在使用中
        const state_valid = self.sequence > 0; // 0表示空闲，>0表示使用中

        return type_valid and state_valid;
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
            // 完全重置消息到干净状态，确保没有残留数据
            msg.* = FastMessage{
                .msg_type = .user_string,
                .actor_id = 0,
                .sender_id = 0,
                .sequence = 1, // 1表示使用中，0表示空闲
                .payload = .{ .string = [_]u8{0} ** 32 },
                .payload_len = 0,
                ._padding = undefined,
            };
            return msg;
        }
        return null;
    }

    pub fn release(self: *Self, msg: *FastMessage) void {
        // 检查消息是否已经被释放
        if (msg.sequence == 0) {
            std.log.warn("Double release detected, ignoring", .{});
            return;
        }

        // 完全重置消息到安全状态，防止数据污染
        msg.* = FastMessage{
            .msg_type = .user_string,
            .actor_id = 0,
            .sender_id = 0,
            .sequence = 0, // 0表示空闲
            .payload = .{ .string = [_]u8{0} ** 32 },
            .payload_len = 0,
            ._padding = undefined,
        };

        if (!self.free_queue.push(msg)) {
            // This should never happen in a properly sized pool
            std.log.warn("Failed to return message to pool - pool may be full", .{});
        }
    }

    pub fn nextSequence(self: *Self) u64 {
        // 确保sequence永远不为0（0用作空闲状态标记）
        const seq = self.sequence_counter.fetchAdd(1, .monotonic) + 1;
        return if (seq == 0) 1 else seq;
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
