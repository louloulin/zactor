//! Message Implementation - 消息实现
//! Actor系统中的核心消息类型定义

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// 消息优先级
pub const MessagePriority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    critical = 3,
    system = 4,

    pub fn compare(self: MessagePriority, other: MessagePriority) std.math.Order {
        return std.math.order(@intFromEnum(self), @intFromEnum(other));
    }
};

// 系统消息类型
pub const SystemMessage = enum {
    start,
    stop,
    restart,
    suspend_actor,
    resume_actor,
    shutdown,
    ping,
    pong,
    heartbeat,
    status_request,
    status_response,
    error_notification,
    supervisor_directive,
    child_terminated,
    watch,
    unwatch,
    link,
    unlink,
    exit,
    kill,

    pub fn getPriority(self: SystemMessage) MessagePriority {
        return switch (self) {
            .kill, .shutdown, .exit => .critical,
            .stop, .restart, .supervisor_directive => .high,
            .start, .suspend_actor, .resume_actor, .error_notification => .normal,
            .ping, .pong, .heartbeat, .status_request, .status_response => .low,
            else => .normal,
        };
    }
};

// 用户消息类型
pub const UserMessage = enum {
    custom,
    request,
    response,
    notification,
    command,
    query,
    event,
    data,

    pub fn getPriority(self: UserMessage) MessagePriority {
        return switch (self) {
            .command => .high,
            .request, .response => .normal,
            .notification, .event => .normal,
            .query, .data, .custom => .low,
        };
    }
};

// 消息类型联合
pub const MessageType = union(enum) {
    system: SystemMessage,
    user: UserMessage,

    pub fn getPriority(self: MessageType) MessagePriority {
        return switch (self) {
            .system => |sys| sys.getPriority(),
            .user => |usr| usr.getPriority(),
        };
    }

    pub fn isSystem(self: MessageType) bool {
        return switch (self) {
            .system => true,
            .user => false,
        };
    }

    pub fn isUser(self: MessageType) bool {
        return !self.isSystem();
    }
};

// 消息元数据
pub const MessageMetadata = struct {
    id: u64,
    timestamp: i64,
    sender_id: ?u64,
    receiver_id: ?u64,
    correlation_id: ?u64,
    reply_to: ?u64,
    ttl: ?u64, // Time to live in nanoseconds
    retry_count: u8,
    max_retries: u8,
    priority: MessagePriority,
    trace_id: ?u128,
    span_id: ?u64,

    pub fn init(message_type: MessageType) MessageMetadata {
        return MessageMetadata{
            .id = generateMessageId(),
            .timestamp = @intCast(std.time.nanoTimestamp()),
            .sender_id = null,
            .receiver_id = null,
            .correlation_id = null,
            .reply_to = null,
            .ttl = null,
            .retry_count = 0,
            .max_retries = 3,
            .priority = message_type.getPriority(),
            .trace_id = null,
            .span_id = null,
        };
    }

    pub fn isExpired(self: *const MessageMetadata) bool {
        if (self.ttl) |ttl| {
            const current_time = std.time.nanoTimestamp();
            return (current_time - self.timestamp) > @as(i64, @intCast(ttl));
        }
        return false;
    }

    pub fn canRetry(self: *const MessageMetadata) bool {
        return self.retry_count < self.max_retries;
    }

    pub fn incrementRetry(self: *MessageMetadata) void {
        self.retry_count += 1;
    }

    pub fn setTracing(self: *MessageMetadata, trace_id: u128, span_id: u64) void {
        self.trace_id = trace_id;
        self.span_id = span_id;
    }
};

// 消息负载
pub const MessagePayload = union(enum) {
    none,
    bytes: []const u8, // 需要释放的字节数据
    string: []const u8, // 需要释放的字符串数据
    static_string: []const u8, // 不需要释放的静态字符串
    integer: i64,
    float: f64,
    boolean: bool,
    json: []const u8,
    binary: []const u8,

    pub fn deinit(self: MessagePayload, allocator: Allocator) void {
        switch (self) {
            .bytes, .string, .json, .binary => |data| {
                allocator.free(data);
            },
            .static_string => {
                // 不释放静态字符串
            },
            else => {},
        }
    }

    pub fn clone(self: MessagePayload, allocator: Allocator) !MessagePayload {
        return switch (self) {
            .none => .none,
            .bytes => |data| .{ .bytes = try allocator.dupe(u8, data) },
            .string => |data| .{ .string = try allocator.dupe(u8, data) },
            .static_string => |data| .{ .static_string = data }, // 静态字符串不需要复制
            .integer => |val| .{ .integer = val },
            .float => |val| .{ .float = val },
            .boolean => |val| .{ .boolean = val },
            .json => |data| .{ .json = try allocator.dupe(u8, data) },
            .binary => |data| .{ .binary = try allocator.dupe(u8, data) },
        };
    }

    pub fn getSize(self: MessagePayload) usize {
        return switch (self) {
            .none => 0,
            .bytes, .string, .static_string, .json, .binary => |data| data.len,
            .integer => @sizeOf(i64),
            .float => @sizeOf(f64),
            .boolean => @sizeOf(bool),
        };
    }
};

// 主消息结构
pub const Message = struct {
    message_type: MessageType,
    metadata: MessageMetadata,
    payload: MessagePayload,

    pub fn init(allocator: Allocator, message_type: MessageType, data: ?[]const u8) !Message {
        const payload = if (data) |d|
            MessagePayload{ .bytes = try allocator.dupe(u8, d) }
        else
            MessagePayload.none;

        return Message{
            .message_type = message_type,
            .metadata = MessageMetadata.init(message_type),
            .payload = payload,
        };
    }

    pub fn createSystem(system_type: SystemMessage, data: ?[]const u8) Message {
        // 对于系统消息，我们不复制数据，因为通常是静态字符串
        const payload = if (data) |d|
            MessagePayload{ .static_string = d } // 使用static_string，不会被释放
        else
            MessagePayload.none;

        return Message{
            .message_type = .{ .system = system_type },
            .metadata = MessageMetadata.init(.{ .system = system_type }),
            .payload = payload,
        };
    }

    pub fn createUser(user_type: UserMessage, data: ?[]const u8) Message {
        // 对于用户消息，也使用static_string避免释放问题
        const payload = if (data) |d|
            MessagePayload{ .static_string = d }
        else
            MessagePayload.none;

        return Message{
            .message_type = .{ .user = user_type },
            .metadata = MessageMetadata.init(.{ .user = user_type }),
            .payload = payload,
        };
    }

    pub fn createWithPayload(message_type: MessageType, payload: MessagePayload) Message {
        return Message{
            .message_type = message_type,
            .metadata = MessageMetadata.init(message_type),
            .payload = payload,
        };
    }

    pub fn deinit(self: Message, allocator: Allocator) void {
        self.payload.deinit(allocator);
    }

    pub fn clone(self: Message, allocator: Allocator) !Message {
        return Message{
            .message_type = self.message_type,
            .metadata = self.metadata,
            .payload = try self.payload.clone(allocator),
        };
    }

    // 消息属性访问
    pub fn getId(self: *const Message) u64 {
        return self.metadata.id;
    }

    pub fn getTimestamp(self: *const Message) i64 {
        return self.metadata.timestamp;
    }

    pub fn getPriority(self: *const Message) MessagePriority {
        return self.metadata.priority;
    }

    pub fn setSender(self: *Message, sender_id: u64) void {
        self.metadata.sender_id = sender_id;
    }

    pub fn setReceiver(self: *Message, receiver_id: u64) void {
        self.metadata.receiver_id = receiver_id;
    }

    pub fn setCorrelationId(self: *Message, correlation_id: u64) void {
        self.metadata.correlation_id = correlation_id;
    }

    pub fn setReplyTo(self: *Message, reply_to: u64) void {
        self.metadata.reply_to = reply_to;
    }

    pub fn setTTL(self: *Message, ttl_ns: u64) void {
        self.metadata.ttl = ttl_ns;
    }

    pub fn setPriority(self: *Message, priority: MessagePriority) void {
        self.metadata.priority = priority;
    }

    pub fn setMaxRetries(self: *Message, max_retries: u8) void {
        self.metadata.max_retries = max_retries;
    }

    // 消息状态检查
    pub fn isExpired(self: *const Message) bool {
        return self.metadata.isExpired();
    }

    pub fn canRetry(self: *const Message) bool {
        return self.metadata.canRetry();
    }

    pub fn incrementRetry(self: *Message) void {
        self.metadata.incrementRetry();
    }

    pub fn isSystem(self: *const Message) bool {
        return self.message_type.isSystem();
    }

    pub fn isUser(self: *const Message) bool {
        return self.message_type.isUser();
    }

    // 负载访问
    pub fn getPayloadSize(self: *const Message) usize {
        return self.payload.getSize();
    }

    pub fn getPayloadAsBytes(self: *const Message) ?[]const u8 {
        return switch (self.payload) {
            .bytes, .string, .static_string, .json, .binary => |data| data,
            else => null,
        };
    }

    pub fn getPayloadAsString(self: *const Message) ?[]const u8 {
        return switch (self.payload) {
            .string => |data| data,
            else => null,
        };
    }

    pub fn getPayloadAsInteger(self: *const Message) ?i64 {
        return switch (self.payload) {
            .integer => |val| val,
            else => null,
        };
    }

    pub fn getPayloadAsFloat(self: *const Message) ?f64 {
        return switch (self.payload) {
            .float => |val| val,
            else => null,
        };
    }

    pub fn getPayloadAsBoolean(self: *const Message) ?bool {
        return switch (self.payload) {
            .boolean => |val| val,
            else => null,
        };
    }

    // 消息比较（用于优先级队列）
    pub fn compare(self: *const Message, other: *const Message) std.math.Order {
        // 首先按优先级比较
        const priority_order = self.metadata.priority.compare(other.metadata.priority);
        if (priority_order != .eq) {
            return priority_order;
        }

        // 优先级相同时按时间戳比较（较早的消息优先）
        return std.math.order(self.metadata.timestamp, other.metadata.timestamp);
    }

    // 消息序列化支持
    pub fn serialize(self: *const Message, allocator: Allocator) ![]u8 {
        // 简单的序列化实现 - 在实际应用中可能需要更复杂的格式
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        // 写入消息类型
        try buffer.writer().writeIntLittle(u32, @intFromEnum(self.message_type));

        // 写入元数据
        try buffer.writer().writeIntLittle(u64, self.metadata.id);
        try buffer.writer().writeIntLittle(i64, self.metadata.timestamp);
        try buffer.writer().writeIntLittle(u8, @intFromEnum(self.metadata.priority));

        // 写入负载
        const payload_data = self.getPayloadAsBytes() orelse &[_]u8{};
        try buffer.writer().writeIntLittle(u32, @intCast(payload_data.len));
        try buffer.appendSlice(payload_data);

        return buffer.toOwnedSlice();
    }

    pub fn deserialize(allocator: Allocator, data: []const u8) !Message {
        if (data.len < 4 + 8 + 8 + 1 + 4) {
            return error.InvalidData;
        }

        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // 读取消息类型
        const msg_type_int = try reader.readIntLittle(u32);
        _ = msg_type_int; // TODO: 实现消息类型反序列化

        // 读取元数据
        const id = try reader.readIntLittle(u64);
        const timestamp = try reader.readIntLittle(i64);
        const priority_int = try reader.readIntLittle(u8);
        const priority = @as(MessagePriority, @enumFromInt(priority_int));

        // 读取负载
        const payload_len = try reader.readIntLittle(u32);
        const remaining_data = data[stream.pos..];

        if (remaining_data.len < payload_len) {
            return error.InvalidData;
        }

        const payload_data = try allocator.dupe(u8, remaining_data[0..payload_len]);

        var message = Message{
            .message_type = .{ .user = .custom }, // TODO: 从序列化数据恢复
            .metadata = MessageMetadata.init(.{ .user = .custom }),
            .payload = .{ .bytes = payload_data },
        };

        message.metadata.id = id;
        message.metadata.timestamp = timestamp;
        message.metadata.priority = priority;

        return message;
    }

    // 调试和日志支持
    pub fn format(self: Message, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("Message{{id={}, type={}, priority={}, size={}}}", .{
            self.metadata.id,
            self.message_type,
            self.metadata.priority,
            self.payload.getSize(),
        });
    }
};

// 消息ID生成器
var message_id_counter = std.atomic.Value(u64).init(0);

fn generateMessageId() u64 {
    return message_id_counter.fetchAdd(1, .monotonic);
}

// 测试
test "Message basic operations" {
    _ = testing.allocator;

    // 测试系统消息
    const sys_msg = Message.createSystem(.stop, null);
    try testing.expect(sys_msg.isSystem());
    try testing.expect(!sys_msg.isUser());
    try testing.expect(sys_msg.getPriority() == .high);

    // 测试用户消息
    const user_msg = Message.createUser(.request, "test data");
    try testing.expect(!user_msg.isSystem());
    try testing.expect(user_msg.isUser());
    try testing.expect(user_msg.getPriority() == .normal);

    // 测试负载访问
    const payload_bytes = user_msg.getPayloadAsBytes();
    try testing.expect(payload_bytes != null);
    try testing.expect(std.mem.eql(u8, payload_bytes.?, "test data"));
}

test "Message metadata operations" {
    var msg = Message.createSystem(.ping, null);

    // 测试设置元数据
    msg.setSender(123);
    msg.setReceiver(456);
    msg.setCorrelationId(789);
    msg.setPriority(.high);

    try testing.expect(msg.metadata.sender_id == 123);
    try testing.expect(msg.metadata.receiver_id == 456);
    try testing.expect(msg.metadata.correlation_id == 789);
    try testing.expect(msg.getPriority() == .high);
}

test "Message TTL and retry" {
    var msg = Message.createSystem(.heartbeat, null);

    // 测试TTL
    msg.setTTL(1000000); // 1ms
    try testing.expect(!msg.isExpired()); // 应该还没过期

    // 测试重试
    try testing.expect(msg.canRetry());
    msg.incrementRetry();
    try testing.expect(msg.metadata.retry_count == 1);
}

test "Message serialization" {
    const allocator = testing.allocator;

    const original = Message.createUser(.request, "test payload");

    // 序列化
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    // 反序列化
    const deserialized = try Message.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    // 验证
    try testing.expect(deserialized.metadata.id == original.metadata.id);
    try testing.expect(deserialized.getPriority() == original.getPriority());
}
