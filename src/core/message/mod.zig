//! Message Module - 消息模块
//! 定义Actor系统中的消息类型和接口

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// 重新导出核心消息组件
pub const Message = @import("message.zig").Message;
pub const MessageType = @import("message.zig").MessageType;
pub const MessagePriority = @import("message.zig").MessagePriority;
pub const MessageMetadata = @import("message.zig").MessageMetadata;
pub const MessagePayload = @import("message.zig").MessagePayload;
pub const UserMessage = @import("message.zig").UserMessage;
pub const SystemMessage = @import("message.zig").SystemMessage;
pub const MessageError = @import("message.zig").MessageError;
pub const MessageConfig = @import("message.zig").MessageConfig;

// 重新导出消息构建器
pub const MessageBuilder = @import("builder.zig").MessageBuilder;
pub const BatchMessageBuilder = @import("builder.zig").BatchMessageBuilder;
pub const MessageTemplate = @import("builder.zig").MessageTemplate;
pub const BuilderError = @import("builder.zig").BuilderError;

// 重新导出消息池
pub const MessagePool = @import("pool.zig").MessagePool;
pub const MessagePoolConfig = @import("pool.zig").MessagePoolConfig;
pub const MessagePoolStats = @import("pool.zig").MessagePoolStats;
pub const PooledMessage = @import("pool.zig").PooledMessage;
pub const ThreadLocalMessagePool = @import("pool.zig").ThreadLocalMessagePool;
pub const MessagePoolManager = @import("pool.zig").MessagePoolManager;
pub const PoolError = @import("pool.zig").PoolError;

// 重新导出消息序列化器
pub const MessageSerializer = @import("serializer.zig").MessageSerializer;
pub const JsonMessageSerializer = @import("serializer.zig").JsonMessageSerializer;
pub const BinaryMessageSerializer = @import("serializer.zig").BinaryMessageSerializer;
pub const SerializerFactory = @import("serializer.zig").SerializerFactory;
pub const SerializationFormat = @import("serializer.zig").SerializationFormat;
pub const SerializationConfig = @import("serializer.zig").SerializationConfig;
pub const SerializationStats = @import("serializer.zig").SerializationStats;
pub const SerializationError = @import("serializer.zig").SerializationError;

// 便利函数
pub const createJsonSerializer = @import("serializer.zig").createJsonSerializer;
pub const createBinarySerializer = @import("serializer.zig").createBinarySerializer;
pub const createCompactSerializer = @import("serializer.zig").createCompactSerializer;

// 消息统计信息
pub const MessageStats = struct {
    total_created: std.atomic.Atomic(u64),
    total_sent: std.atomic.Atomic(u64),
    total_received: std.atomic.Atomic(u64),
    total_dropped: std.atomic.Atomic(u64),
    system_messages: std.atomic.Atomic(u64),
    user_messages: std.atomic.Atomic(u64),
    high_priority_messages: std.atomic.Atomic(u64),
    
    pub fn init() MessageStats {
        return MessageStats{
            .total_created = std.atomic.Atomic(u64).init(0),
            .total_sent = std.atomic.Atomic(u64).init(0),
            .total_received = std.atomic.Atomic(u64).init(0),
            .total_dropped = std.atomic.Atomic(u64).init(0),
            .system_messages = std.atomic.Atomic(u64).init(0),
            .user_messages = std.atomic.Atomic(u64).init(0),
            .high_priority_messages = std.atomic.Atomic(u64).init(0),
        };
    }
    
    pub fn incrementCreated(self: *MessageStats) void {
        _ = self.total_created.fetchAdd(1, .Monotonic);
    }
    
    pub fn incrementSent(self: *MessageStats) void {
        _ = self.total_sent.fetchAdd(1, .Monotonic);
    }
    
    pub fn incrementReceived(self: *MessageStats) void {
        _ = self.total_received.fetchAdd(1, .Monotonic);
    }
    
    pub fn incrementDropped(self: *MessageStats) void {
        _ = self.total_dropped.fetchAdd(1, .Monotonic);
    }
    
    pub fn incrementSystemMessage(self: *MessageStats) void {
        _ = self.system_messages.fetchAdd(1, .Monotonic);
    }
    
    pub fn incrementUserMessage(self: *MessageStats) void {
        _ = self.user_messages.fetchAdd(1, .Monotonic);
    }
    
    pub fn incrementHighPriorityMessage(self: *MessageStats) void {
        _ = self.high_priority_messages.fetchAdd(1, .Monotonic);
    }
    
    pub fn getTotalCreated(self: *const MessageStats) u64 {
        return self.total_created.load(.Monotonic);
    }
    
    pub fn getTotalSent(self: *const MessageStats) u64 {
        return self.total_sent.load(.Monotonic);
    }
    
    pub fn getTotalReceived(self: *const MessageStats) u64 {
        return self.total_received.load(.Monotonic);
    }
    
    pub fn getTotalDropped(self: *const MessageStats) u64 {
        return self.total_dropped.load(.Monotonic);
    }
    
    pub fn getSystemMessages(self: *const MessageStats) u64 {
        return self.system_messages.load(.Monotonic);
    }
    
    pub fn getUserMessages(self: *const MessageStats) u64 {
        return self.user_messages.load(.Monotonic);
    }
    
    pub fn getHighPriorityMessages(self: *const MessageStats) u64 {
        return self.high_priority_messages.load(.Monotonic);
    }
    
    pub fn getSuccessRate(self: *const MessageStats) f64 {
        const sent = self.getTotalSent();
        const received = self.getTotalReceived();
        if (sent == 0) return 0.0;
        return @as(f64, @floatFromInt(received)) / @as(f64, @floatFromInt(sent));
    }
    
    pub fn getDropRate(self: *const MessageStats) f64 {
        const created = self.getTotalCreated();
        const dropped = self.getTotalDropped();
        if (created == 0) return 0.0;
        return @as(f64, @floatFromInt(dropped)) / @as(f64, @floatFromInt(created));
    }
};

// 消息配置
pub const MessageConfig = struct {
    // 消息池配置
    enable_message_pool: bool = true,
    pool_initial_size: u32 = 1000,
    pool_max_size: u32 = 10000,
    pool_growth_factor: f32 = 1.5,
    
    // 序列化配置
    enable_compression: bool = false,
    compression_threshold: u32 = 1024, // 字节
    
    // 统计配置
    enable_statistics: bool = true,
    
    // 优先级配置
    enable_priority_queue: bool = false,
    max_priority_levels: u8 = 5,
    
    // 批处理配置
    enable_batching: bool = true,
    max_batch_size: u32 = 100,
    
    // 超时配置
    default_timeout_ms: u32 = 5000,
    enable_message_timeout: bool = false,
    
    // 调试配置
    enable_message_tracing: bool = false,
    trace_buffer_size: u32 = 1000,
};

// 消息工厂
pub const MessageFactory = struct {
    config: MessageConfig,
    stats: ?*MessageStats,
    pool: ?*MessagePool,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, config: MessageConfig) !MessageFactory {
        var stats: ?*MessageStats = null;
        if (config.enable_statistics) {
            stats = try allocator.create(MessageStats);
            stats.?.* = MessageStats.init();
        }
        
        var pool: ?*MessagePool = null;
        if (config.enable_message_pool) {
            pool = try allocator.create(MessagePool);
            pool.?.* = try MessagePool.init(allocator, config.pool_initial_size);
        }
        
        return MessageFactory{
            .config = config,
            .stats = stats,
            .pool = pool,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MessageFactory) void {
        if (self.pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
        
        if (self.stats) |stats| {
            self.allocator.destroy(stats);
        }
    }
    
    pub fn createMessage(self: *MessageFactory, message_type: MessageType, data: ?[]const u8) !Message {
        var message: Message = undefined;
        
        if (self.pool) |pool| {
            if (pool.allocate()) |pooled_message| {
                message = pooled_message.*;
            } else {
                message = try Message.init(self.allocator, message_type, data);
            }
        } else {
            message = try Message.init(self.allocator, message_type, data);
        }
        
        if (self.stats) |stats| {
            stats.incrementCreated();
            switch (message_type) {
                .system => stats.incrementSystemMessage(),
                .user => stats.incrementUserMessage(),
            }
        }
        
        return message;
    }
    
    pub fn createSystemMessage(self: *MessageFactory, system_type: SystemMessage, data: ?[]const u8) !Message {
        return self.createMessage(.{ .system = system_type }, data);
    }
    
    pub fn createUserMessage(self: *MessageFactory, user_type: UserMessage, data: ?[]const u8) !Message {
        return self.createMessage(.{ .user = user_type }, data);
    }
    
    pub fn createBatch(self: *MessageFactory, messages: []const MessageType, data_array: []const ?[]const u8) ![]Message {
        if (messages.len != data_array.len) {
            return error.MismatchedArrayLengths;
        }
        
        const batch = try self.allocator.alloc(Message, messages.len);
        errdefer self.allocator.free(batch);
        
        for (messages, data_array, 0..) |msg_type, data, i| {
            batch[i] = try self.createMessage(msg_type, data);
        }
        
        return batch;
    }
    
    pub fn destroyMessage(self: *MessageFactory, message: *Message) void {
        if (self.pool) |pool| {
            pool.deallocate(message);
        } else {
            message.deinit(self.allocator);
        }
    }
    
    pub fn destroyBatch(self: *MessageFactory, batch: []Message) void {
        for (batch) |*message| {
            self.destroyMessage(message);
        }
        self.allocator.free(batch);
    }
    
    pub fn getStats(self: *const MessageFactory) ?*const MessageStats {
        return self.stats;
    }
    
    pub fn resetStats(self: *MessageFactory) void {
        if (self.stats) |stats| {
            stats.* = MessageStats.init();
        }
    }
};

// 消息路由器
pub const MessageRouter = struct {
    routes: std.HashMap(MessageType, []const u8, MessageTypeContext, std.hash_map.default_max_load_percentage),
    default_route: ?[]const u8,
    allocator: Allocator,
    
    const MessageTypeContext = struct {
        pub fn hash(self: @This(), key: MessageType) u64 {
            _ = self;
            return std.hash_map.hashString(@tagName(key));
        }
        
        pub fn eql(self: @This(), a: MessageType, b: MessageType) bool {
            _ = self;
            return std.meta.eql(a, b);
        }
    };
    
    pub fn init(allocator: Allocator) MessageRouter {
        return MessageRouter{
            .routes = std.HashMap(MessageType, []const u8, MessageTypeContext, std.hash_map.default_max_load_percentage).init(allocator),
            .default_route = null,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MessageRouter) void {
        self.routes.deinit();
    }
    
    pub fn addRoute(self: *MessageRouter, message_type: MessageType, actor_path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, actor_path);
        try self.routes.put(message_type, owned_path);
    }
    
    pub fn removeRoute(self: *MessageRouter, message_type: MessageType) void {
        if (self.routes.fetchRemove(message_type)) |entry| {
            self.allocator.free(entry.value);
        }
    }
    
    pub fn setDefaultRoute(self: *MessageRouter, actor_path: []const u8) !void {
        if (self.default_route) |old_route| {
            self.allocator.free(old_route);
        }
        self.default_route = try self.allocator.dupe(u8, actor_path);
    }
    
    pub fn route(self: *const MessageRouter, message_type: MessageType) ?[]const u8 {
        return self.routes.get(message_type) orelse self.default_route;
    }
};

// 测试
test "MessageStats basic operations" {
    var stats = MessageStats.init();
    
    try testing.expect(stats.getTotalCreated() == 0);
    
    stats.incrementCreated();
    stats.incrementSent();
    stats.incrementReceived();
    
    try testing.expect(stats.getTotalCreated() == 1);
    try testing.expect(stats.getTotalSent() == 1);
    try testing.expect(stats.getTotalReceived() == 1);
    try testing.expect(stats.getSuccessRate() == 1.0);
}

test "MessageFactory basic operations" {
    const allocator = testing.allocator;
    const config = MessageConfig{};
    
    var factory = try MessageFactory.init(allocator, config);
    defer factory.deinit();
    
    const message = try factory.createSystemMessage(.stop, null);
    defer factory.destroyMessage(@constCast(&message));
    
    const stats = factory.getStats();
    try testing.expect(stats != null);
    try testing.expect(stats.?.getTotalCreated() == 1);
}

test "MessageRouter basic operations" {
    const allocator = testing.allocator;
    
    var router = MessageRouter.init(allocator);
    defer router.deinit();
    
    try router.addRoute(.{ .system = .stop }, "system_actor");
    try router.setDefaultRoute("default_actor");
    
    const route1 = router.route(.{ .system = .stop });
    try testing.expect(route1 != null);
    try testing.expect(std.mem.eql(u8, route1.?, "system_actor"));
    
    const route2 = router.route(.{ .system = .start });
    try testing.expect(route2 != null);
    try testing.expect(std.mem.eql(u8, route2.?, "default_actor"));
}