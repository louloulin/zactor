//! Message Builder Implementation - 消息构建器实现
//! 提供流式API来构建复杂消息

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;

// 导入相关模块
const Message = @import("message.zig").Message;
const MessageType = @import("message.zig").MessageType;
const MessagePriority = @import("message.zig").MessagePriority;
const MessageMetadata = @import("message.zig").MessageMetadata;
const MessagePayload = @import("message.zig").MessagePayload;
const UserMessage = @import("message.zig").UserMessage;
const SystemMessage = @import("message.zig").SystemMessage;

// 消息构建器
pub const MessageBuilder = struct {
    const Self = @This();
    
    allocator: Allocator,
    message_type: ?MessageType,
    priority: MessagePriority,
    headers: HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage),
    payload: ?MessagePayload,
    correlation_id: ?[]const u8,
    reply_to: ?[]const u8,
    timeout_ms: ?u64,
    retry_count: u32,
    
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .message_type = null,
            .priority = .normal,
            .headers = HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .payload = null,
            .correlation_id = null,
            .reply_to = null,
            .timeout_ms = null,
            .retry_count = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // 清理headers
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        
        // 清理字符串字段
        if (self.correlation_id) |id| {
            self.allocator.free(id);
        }
        if (self.reply_to) |reply| {
            self.allocator.free(reply);
        }
    }
    
    // 设置消息类型
    pub fn withUserMessage(self: *Self, data: anytype) !*Self {
        const payload = try self.createUserPayload(data);
        self.message_type = MessageType{ .user = UserMessage{ .data = payload } };
        return self;
    }
    
    pub fn withSystemMessage(self: *Self, msg_type: SystemMessage) !*Self {
        self.message_type = MessageType{ .system = msg_type };
        return self;
    }
    
    pub fn withStringMessage(self: *Self, content: []const u8) !*Self {
        const content_copy = try self.allocator.dupe(u8, content);
        self.payload = MessagePayload{ .string = content_copy };
        return self;
    }
    
    pub fn withBinaryMessage(self: *Self, data: []const u8) !*Self {
        const data_copy = try self.allocator.dupe(u8, data);
        self.payload = MessagePayload{ .binary = data_copy };
        return self;
    }
    
    pub fn withJsonMessage(self: *Self, json_str: []const u8) !*Self {
        const json_copy = try self.allocator.dupe(u8, json_str);
        self.payload = MessagePayload{ .json = json_copy };
        return self;
    }
    
    // 设置优先级
    pub fn withPriority(self: *Self, priority: MessagePriority) *Self {
        self.priority = priority;
        return self;
    }
    
    pub fn withHighPriority(self: *Self) *Self {
        self.priority = .high;
        return self;
    }
    
    pub fn withLowPriority(self: *Self) *Self {
        self.priority = .low;
        return self;
    }
    
    pub fn withCriticalPriority(self: *Self) *Self {
        self.priority = .critical;
        return self;
    }
    
    // 设置头部信息
    pub fn withHeader(self: *Self, key: []const u8, value: []const u8) !*Self {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.headers.put(key_copy, value_copy);
        return self;
    }
    
    pub fn withHeaders(self: *Self, headers: anytype) !*Self {
        const fields = std.meta.fields(@TypeOf(headers));
        inline for (fields) |field| {
            const value = @field(headers, field.name);
            const value_str = switch (@TypeOf(value)) {
                []const u8 => value,
                else => try std.fmt.allocPrint(self.allocator, "{any}", .{value}),
            };
            _ = try self.withHeader(field.name, value_str);
        }
        return self;
    }
    
    // 设置元数据
    pub fn withCorrelationId(self: *Self, id: []const u8) !*Self {
        if (self.correlation_id) |old_id| {
            self.allocator.free(old_id);
        }
        self.correlation_id = try self.allocator.dupe(u8, id);
        return self;
    }
    
    pub fn withReplyTo(self: *Self, reply_to: []const u8) !*Self {
        if (self.reply_to) |old_reply| {
            self.allocator.free(old_reply);
        }
        self.reply_to = try self.allocator.dupe(u8, reply_to);
        return self;
    }
    
    pub fn withTimeout(self: *Self, timeout_ms: u64) *Self {
        self.timeout_ms = timeout_ms;
        return self;
    }
    
    pub fn withRetryCount(self: *Self, count: u32) *Self {
        self.retry_count = count;
        return self;
    }
    
    // 构建消息
    pub fn build(self: *Self) !*Message {
        if (self.message_type == null and self.payload == null) {
            return error.NoMessageContent;
        }
        
        // 创建元数据
        const metadata = MessageMetadata{
            .id = Message.generateId(),
            .timestamp = std.time.milliTimestamp(),
            .priority = self.priority,
            .correlation_id = if (self.correlation_id) |id| try self.allocator.dupe(u8, id) else null,
            .reply_to = if (self.reply_to) |reply| try self.allocator.dupe(u8, reply) else null,
            .timeout_ms = self.timeout_ms,
            .retry_count = self.retry_count,
            .headers = try self.cloneHeaders(),
        };
        
        // 确定最终的消息类型和载荷
        const final_type = self.message_type orelse MessageType{ .user = UserMessage{ .data = self.payload.? } };
        
        // 创建消息
        const message = try Message.initWithMetadata(self.allocator, final_type, metadata);
        
        return message;
    }
    
    // 辅助方法
    fn createUserPayload(self: *Self, data: anytype) !MessagePayload {
        const T = @TypeOf(data);
        
        switch (@typeInfo(T)) {
            .Pointer => |ptr_info| {
                if (ptr_info.child == u8) {
                    // 字符串类型
                    const str_copy = try self.allocator.dupe(u8, data);
                    return MessagePayload{ .string = str_copy };
                }
            },
            .Int, .Float, .Bool => {
                // 基本类型，转换为字符串
                const str = try std.fmt.allocPrint(self.allocator, "{any}", .{data});
                return MessagePayload{ .string = str };
            },
            .Struct, .Union, .Enum => {
                // 复杂类型，序列化为JSON
                const json_str = try std.json.stringifyAlloc(self.allocator, data, .{});
                return MessagePayload{ .json = json_str };
            },
            else => {
                return error.UnsupportedDataType;
            },
        }
    }
    
    fn cloneHeaders(self: *Self) !HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage) {
        var cloned = HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
            try cloned.put(key_copy, value_copy);
        }
        
        return cloned;
    }
};

// 批量消息构建器
pub const BatchMessageBuilder = struct {
    const Self = @This();
    
    allocator: Allocator,
    messages: ArrayList(*Message),
    default_priority: MessagePriority,
    default_headers: HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage),
    
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .messages = ArrayList(*Message).init(allocator),
            .default_priority = .normal,
            .default_headers = HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        // 清理消息
        for (self.messages.items) |msg| {
            msg.deinit();
        }
        self.messages.deinit();
        
        // 清理默认头部
        var iter = self.default_headers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.default_headers.deinit();
    }
    
    pub fn setDefaultPriority(self: *Self, priority: MessagePriority) *Self {
        self.default_priority = priority;
        return self;
    }
    
    pub fn setDefaultHeader(self: *Self, key: []const u8, value: []const u8) !*Self {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.default_headers.put(key_copy, value_copy);
        return self;
    }
    
    pub fn addMessage(self: *Self, data: anytype) !*Self {
        var builder = MessageBuilder.init(self.allocator);
        defer builder.deinit();
        
        // 应用默认设置
        _ = builder.withPriority(self.default_priority);
        
        // 应用默认头部
        var iter = self.default_headers.iterator();
        while (iter.next()) |entry| {
            _ = try builder.withHeader(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        // 设置消息内容
        _ = try builder.withUserMessage(data);
        
        // 构建并添加消息
        const message = try builder.build();
        try self.messages.append(message);
        
        return self;
    }
    
    pub fn addCustomMessage(self: *Self, builder_fn: fn (*MessageBuilder) anyerror!void) !*Self {
        var builder = MessageBuilder.init(self.allocator);
        defer builder.deinit();
        
        // 应用默认设置
        _ = builder.withPriority(self.default_priority);
        
        // 应用默认头部
        var iter = self.default_headers.iterator();
        while (iter.next()) |entry| {
            _ = try builder.withHeader(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        // 应用自定义构建逻辑
        try builder_fn(&builder);
        
        // 构建并添加消息
        const message = try builder.build();
        try self.messages.append(message);
        
        return self;
    }
    
    pub fn build(self: *Self) []const *Message {
        return self.messages.items;
    }
    
    pub fn count(self: *Self) usize {
        return self.messages.items.len;
    }
    
    pub fn clear(self: *Self) void {
        for (self.messages.items) |msg| {
            msg.deinit();
        }
        self.messages.clearAndFree();
    }
};

// 消息模板
pub const MessageTemplate = struct {
    const Self = @This();
    
    name: []const u8,
    priority: MessagePriority,
    headers: HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage),
    timeout_ms: ?u64,
    retry_count: u32,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, name: []const u8) !Self {
        return Self{
            .name = try allocator.dupe(u8, name),
            .priority = .normal,
            .headers = HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .timeout_ms = null,
            .retry_count = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
    }
    
    pub fn createBuilder(self: *Self) !MessageBuilder {
        var builder = MessageBuilder.init(self.allocator);
        
        // 应用模板设置
        _ = builder.withPriority(self.priority);
        
        if (self.timeout_ms) |timeout| {
            _ = builder.withTimeout(timeout);
        }
        
        _ = builder.withRetryCount(self.retry_count);
        
        // 应用模板头部
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            _ = try builder.withHeader(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        return builder;
    }
    
    pub fn buildMessage(self: *Self, data: anytype) !*Message {
        var builder = try self.createBuilder();
        defer builder.deinit();
        
        _ = try builder.withUserMessage(data);
        return builder.build();
    }
};

// 辅助类型
const StringContext = struct {
    pub fn hash(self: @This(), s: []const u8) u64 {
        _ = self;
        return std.hash_map.hashString(s);
    }
    
    pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, a, b);
    }
};

// 便利函数
pub fn message(allocator: Allocator) MessageBuilder {
    return MessageBuilder.init(allocator);
}

pub fn batchMessage(allocator: Allocator) BatchMessageBuilder {
    return BatchMessageBuilder.init(allocator);
}

pub fn template(allocator: Allocator, name: []const u8) !MessageTemplate {
    return MessageTemplate.init(allocator, name);
}

// 测试
test "MessageBuilder basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var builder = MessageBuilder.init(allocator);
    defer builder.deinit();
    
    const msg = try builder
        .withStringMessage("Hello, World!")
        .withPriority(.high)
        .withHeader("sender", "test")
        .withTimeout(5000)
        .build();
    defer msg.deinit();
    
    try testing.expect(msg.getPriority() == .high);
    try testing.expect(msg.getTimeout() == 5000);
}

test "BatchMessageBuilder" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var batch = BatchMessageBuilder.init(allocator);
    defer batch.deinit();
    
    _ = try batch
        .setDefaultPriority(.high)
        .addMessage("Message 1")
        .addMessage("Message 2")
        .addMessage("Message 3");
    
    const messages = batch.build();
    try testing.expect(messages.len == 3);
    
    for (messages) |msg| {
        try testing.expect(msg.getPriority() == .high);
    }
}

test "MessageTemplate" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var tmpl = try MessageTemplate.init(allocator, "test-template");
    defer tmpl.deinit();
    
    tmpl.priority = .critical;
    tmpl.timeout_ms = 10000;
    
    const msg = try tmpl.buildMessage("Template message");
    defer msg.deinit();
    
    try testing.expect(msg.getPriority() == .critical);
    try testing.expect(msg.getTimeout() == 10000);
}