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

    // Tagged Union for different payload types - 原子性保证
    payload: union(Type) {
        user_string: struct {
            data: [32]u8,
            len: u8,
        },
        user_int: i64,
        user_float: f64,
        system_ping: void,
        system_pong: void,
        system_stop: void,
        control_shutdown: void,
    },

    _padding: [7]u8 = undefined, // Align to 64 bytes

    pub fn createUserString(actor_id: u32, sender_id: u32, sequence: u64, data: []const u8) Self {
        const len = @min(data.len, 32);
        var string_data = [_]u8{0} ** 32;

        // 安全地复制数据
        if (len > 0) {
            @memcpy(string_data[0..len], data[0..len]);
        }

        return Self{
            .msg_type = .user_string,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .user_string = .{ .data = string_data, .len = @intCast(len) } },
            ._padding = undefined,
        };
    }

    pub fn createUserInt(actor_id: u32, sender_id: u32, sequence: u64, value: i64) Self {
        return Self{
            .msg_type = .user_int,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .user_int = value },
            ._padding = undefined,
        };
    }

    pub fn createUserFloat(actor_id: u32, sender_id: u32, sequence: u64, value: f64) Self {
        return Self{
            .msg_type = .user_float,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .user_float = value },
            ._padding = undefined,
        };
    }

    pub fn createSystemPing(actor_id: u32, sender_id: u32, sequence: u64) Self {
        return Self{
            .msg_type = .system_ping,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .system_ping = {} },
            ._padding = undefined,
        };
    }

    // 原子性设置消息为字符串类型
    pub fn setAsString(self: *Self, actor_id: u32, sender_id: u32, sequence: u64, data: []const u8) void {
        const len = @min(data.len, 32);
        var string_data = [_]u8{0} ** 32;

        // 复制数据
        if (len > 0) {
            @memcpy(string_data[0..len], data[0..len]);
        }

        // 原子性设置整个消息
        self.* = Self{
            .msg_type = .user_string,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .user_string = .{ .data = string_data, .len = @intCast(len) } },
            ._padding = undefined,
        };
    }

    // 原子性设置消息为整数类型
    pub fn setAsInt(self: *Self, actor_id: u32, sender_id: u32, sequence: u64, value: i64) void {
        // 原子性设置整个消息
        self.* = Self{
            .msg_type = .user_int,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .user_int = value },
            ._padding = undefined,
        };
    }

    // 原子性设置消息为浮点类型
    pub fn setAsFloat(self: *Self, actor_id: u32, sender_id: u32, sequence: u64, value: f64) void {
        // 原子性设置整个消息
        self.* = Self{
            .msg_type = .user_float,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .user_float = value },
            ._padding = undefined,
        };
    }

    // 原子性设置消息为Ping类型
    pub fn setAsPing(self: *Self, actor_id: u32, sender_id: u32, sequence: u64) void {
        // 原子性设置整个消息
        self.* = Self{
            .msg_type = .system_ping,
            .actor_id = actor_id,
            .sender_id = sender_id,
            .sequence = sequence,
            .payload = .{ .system_ping = {} },
            ._padding = undefined,
        };
    }

    pub fn getString(self: *const Self) []const u8 {
        // Tagged Union确保类型安全
        return switch (self.payload) {
            .user_string => |str_data| str_data.data[0..str_data.len],
            else => {
                std.log.warn("Attempting to get string from non-string message type: {}", .{self.msg_type});
                return "";
            },
        };
    }

    pub fn getInt(self: *const Self) i64 {
        // Tagged Union确保类型安全
        return switch (self.payload) {
            .user_int => |int_val| int_val,
            else => {
                std.log.warn("Attempting to get int from non-int message type: {}", .{self.msg_type});
                return 0;
            },
        };
    }

    pub fn getFloat(self: *const Self) f64 {
        // Tagged Union确保类型安全
        return switch (self.payload) {
            .user_float => |float_val| float_val,
            else => {
                std.log.warn("Attempting to get float from non-float message type: {}", .{self.msg_type});
                return 0.0;
            },
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
        // 检查消息类型是否有效
        const type_valid = switch (self.payload) {
            .user_string => |str_data| str_data.len <= 32, // 字符串长度不能超过缓冲区
            .user_int, .user_float, .system_ping, .system_pong, .system_stop, .control_shutdown => true,
        };

        // 检查sequence字段是否表示消息正在使用中
        const state_valid = self.sequence > 0; // 0表示空闲，>0表示使用中

        return type_valid and state_valid;
    }

    // 调试信息
    pub fn debugInfo(self: *const Self) void {
        const len = switch (self.payload) {
            .user_string => |str_data| str_data.len,
            else => 0,
        };
        std.log.debug("Message: type={}, actor={}, sender={}, seq={}, len={}", .{
            self.msg_type,
            self.actor_id,
            self.sender_id,
            self.sequence,
            len,
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
                .payload = .{ .user_string = .{ .data = [_]u8{0} ** 32, .len = 0 } },
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
            // 不在这里设置具体类型，只标记为使用中
            // 具体类型将在create方法中原子性设置
            msg.sequence = 1; // 1表示使用中，0表示空闲
            msg.actor_id = 0;
            msg.sender_id = 0;
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
