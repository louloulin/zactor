//! Message Serializer Implementation - 消息序列化器实现
//! 提供多种格式的消息序列化和反序列化功能

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

// 序列化格式
pub const SerializationFormat = enum {
    json,
    binary,
    msgpack,
    protobuf,
    custom,
};

// 序列化错误
pub const SerializationError = error{
    UnsupportedFormat,
    SerializationFailed,
    DeserializationFailed,
    InvalidData,
    BufferTooSmall,
    VersionMismatch,
};

// 序列化配置
pub const SerializationConfig = struct {
    format: SerializationFormat = .json,
    compression: bool = false,
    encryption: bool = false,
    version: u32 = 1,
    include_metadata: bool = true,
    pretty_print: bool = false,
    
    pub fn default() SerializationConfig {
        return SerializationConfig{};
    }
    
    pub fn compact() SerializationConfig {
        return SerializationConfig{
            .format = .binary,
            .compression = true,
            .include_metadata = false,
        };
    }
    
    pub fn debug() SerializationConfig {
        return SerializationConfig{
            .format = .json,
            .pretty_print = true,
            .include_metadata = true,
        };
    }
};

// 序列化统计信息
pub const SerializationStats = struct {
    serializations: u64 = 0,
    deserializations: u64 = 0,
    bytes_serialized: u64 = 0,
    bytes_deserialized: u64 = 0,
    compression_ratio: f64 = 1.0,
    avg_serialization_time_ns: u64 = 0,
    avg_deserialization_time_ns: u64 = 0,
    
    pub fn updateSerializationTime(self: *SerializationStats, time_ns: u64) void {
        self.avg_serialization_time_ns = (self.avg_serialization_time_ns * self.serializations + time_ns) / (self.serializations + 1);
        self.serializations += 1;
    }
    
    pub fn updateDeserializationTime(self: *SerializationStats, time_ns: u64) void {
        self.avg_deserialization_time_ns = (self.avg_deserialization_time_ns * self.deserializations + time_ns) / (self.deserializations + 1);
        self.deserializations += 1;
    }
};

// 消息序列化器接口
pub const MessageSerializer = struct {
    const Self = @This();
    
    vtable: *const VTable,
    config: SerializationConfig,
    stats: SerializationStats,
    allocator: Allocator,
    
    pub const VTable = struct {
        serialize: *const fn (self: *MessageSerializer, message: *const Message, buffer: []u8) anyerror!usize,
        deserialize: *const fn (self: *MessageSerializer, data: []const u8, allocator: Allocator) anyerror!*Message,
        estimateSize: *const fn (self: *MessageSerializer, message: *const Message) usize,
        getFormat: *const fn (self: *MessageSerializer) SerializationFormat,
        deinit: *const fn (self: *MessageSerializer) void,
    };
    
    pub fn init(vtable: *const VTable, config: SerializationConfig, allocator: Allocator) Self {
        return Self{
            .vtable = vtable,
            .config = config,
            .stats = SerializationStats{},
            .allocator = allocator,
        };
    }
    
    pub fn serialize(self: *Self, message: *const Message, buffer: []u8) !usize {
        const start_time = std.time.nanoTimestamp();
        const size = try self.vtable.serialize(self, message, buffer);
        const end_time = std.time.nanoTimestamp();
        
        self.stats.updateSerializationTime(@intCast(end_time - start_time));
        self.stats.bytes_serialized += size;
        
        return size;
    }
    
    pub fn serializeAlloc(self: *Self, message: *const Message) ![]u8 {
        const estimated_size = self.vtable.estimateSize(self, message);
        const buffer = try self.allocator.alloc(u8, estimated_size);
        errdefer self.allocator.free(buffer);
        
        const actual_size = try self.serialize(message, buffer);
        
        if (actual_size < estimated_size) {
            return self.allocator.realloc(buffer, actual_size);
        }
        
        return buffer;
    }
    
    pub fn deserialize(self: *Self, data: []const u8) !*Message {
        const start_time = std.time.nanoTimestamp();
        const message = try self.vtable.deserialize(self, data, self.allocator);
        const end_time = std.time.nanoTimestamp();
        
        self.stats.updateDeserializationTime(@intCast(end_time - start_time));
        self.stats.bytes_deserialized += data.len;
        
        return message;
    }
    
    pub fn estimateSize(self: *Self, message: *const Message) usize {
        return self.vtable.estimateSize(self, message);
    }
    
    pub fn getFormat(self: *Self) SerializationFormat {
        return self.vtable.getFormat(self);
    }
    
    pub fn getStats(self: *Self) SerializationStats {
        return self.stats;
    }
    
    pub fn getConfig(self: *Self) SerializationConfig {
        return self.config;
    }
    
    pub fn deinit(self: *Self) void {
        self.vtable.deinit(self);
    }
};

// JSON序列化器实现
pub const JsonMessageSerializer = struct {
    const Self = @This();
    
    serializer: MessageSerializer,
    
    const vtable = MessageSerializer.VTable{
        .serialize = serialize,
        .deserialize = deserialize,
        .estimateSize = estimateSize,
        .getFormat = getFormat,
        .deinit = deinitImpl,
    };
    
    pub fn init(config: SerializationConfig, allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .serializer = MessageSerializer.init(&vtable, config, allocator),
        };
        return self;
    }
    
    pub fn getSerializer(self: *Self) *MessageSerializer {
        return &self.serializer;
    }
    
    fn serialize(serializer: *MessageSerializer, message: *const Message, buffer: []u8) !usize {
        const self = @fieldParentPtr(Self, "serializer", serializer);
        
        // 创建JSON对象
        var json_obj = std.json.ObjectMap.init(self.serializer.allocator);
        defer json_obj.deinit();
        
        // 序列化消息ID
        try json_obj.put("id", std.json.Value{ .integer = @intCast(message.getId()) });
        
        // 序列化时间戳
        try json_obj.put("timestamp", std.json.Value{ .integer = message.getTimestamp() });
        
        // 序列化优先级
        const priority_str = switch (message.getPriority()) {
            .low => "low",
            .normal => "normal",
            .high => "high",
            .critical => "critical",
        };
        try json_obj.put("priority", std.json.Value{ .string = priority_str });
        
        // 序列化消息类型和载荷
        try self.serializeMessageType(&json_obj, message.getType());
        
        // 序列化元数据（如果启用）
        if (self.serializer.config.include_metadata) {
            try self.serializeMetadata(&json_obj, message);
        }
        
        // 转换为JSON字符串
        const json_value = std.json.Value{ .object = json_obj };
        const options = std.json.StringifyOptions{
            .whitespace = if (self.serializer.config.pretty_print) .indent_2 else .minified,
        };
        
        var stream = std.io.fixedBufferStream(buffer);
        try std.json.stringify(json_value, options, stream.writer());
        
        return stream.pos;
    }
    
    fn deserialize(serializer: *MessageSerializer, data: []const u8, allocator: Allocator) !*Message {
        const self = @fieldParentPtr(Self, "serializer", serializer);
        _ = self;
        
        // 解析JSON
        var parser = std.json.Parser.init(allocator, false);
        defer parser.deinit();
        
        var tree = try parser.parse(data);
        defer tree.deinit();
        
        const root = tree.root.object;
        
        // 提取基本字段
        const id = @intCast(root.get("id").?.integer);
        const timestamp = root.get("timestamp").?.integer;
        
        const priority_str = root.get("priority").?.string;
        const priority = if (std.mem.eql(u8, priority_str, "low"))
            MessagePriority.low
        else if (std.mem.eql(u8, priority_str, "normal"))
            MessagePriority.normal
        else if (std.mem.eql(u8, priority_str, "high"))
            MessagePriority.high
        else if (std.mem.eql(u8, priority_str, "critical"))
            MessagePriority.critical
        else
            MessagePriority.normal;
        
        // 反序列化消息类型
        const message_type = try self.deserializeMessageType(&root, allocator);
        
        // 创建消息
        const message = try Message.init(allocator, message_type);
        message.setPriority(priority);
        
        // 设置ID和时间戳（如果需要保持原值）
        // message.setId(id); // 假设有这个方法
        // message.setTimestamp(timestamp); // 假设有这个方法
        _ = id;
        _ = timestamp;
        
        return message;
    }
    
    fn estimateSize(serializer: *MessageSerializer, message: *const Message) usize {
        _ = serializer;
        _ = message;
        // 粗略估算JSON大小
        return 1024; // 基础大小
    }
    
    fn getFormat(serializer: *MessageSerializer) SerializationFormat {
        _ = serializer;
        return .json;
    }
    
    fn deinitImpl(serializer: *MessageSerializer) void {
        const self = @fieldParentPtr(Self, "serializer", serializer);
        self.serializer.allocator.destroy(self);
    }
    
    // 辅助方法
    fn serializeMessageType(self: *Self, json_obj: *std.json.ObjectMap, msg_type: MessageType) !void {
        switch (msg_type) {
            .user => |user_msg| {
                try json_obj.put("type", std.json.Value{ .string = "user" });
                if (user_msg.data) |payload| {
                    try self.serializePayload(json_obj, payload);
                }
            },
            .system => |sys_msg| {
                try json_obj.put("type", std.json.Value{ .string = "system" });
                const sys_type_str = switch (sys_msg) {
                    .start => "start",
                    .stop => "stop",
                    .restart => "restart",
                    .kill => "kill",
                    .watch => "watch",
                    .unwatch => "unwatch",
                    .terminated => "terminated",
                };
                try json_obj.put("system_type", std.json.Value{ .string = sys_type_str });
            },
        }
    }
    
    fn serializePayload(self: *Self, json_obj: *std.json.ObjectMap, payload: MessagePayload) !void {
        _ = self;
        switch (payload) {
            .string => |str| {
                try json_obj.put("payload_type", std.json.Value{ .string = "string" });
                try json_obj.put("payload", std.json.Value{ .string = str });
            },
            .binary => |data| {
                try json_obj.put("payload_type", std.json.Value{ .string = "binary" });
                // Base64编码二进制数据
                const encoder = std.base64.standard.Encoder;
                const encoded_len = encoder.calcSize(data.len);
                const encoded = try self.serializer.allocator.alloc(u8, encoded_len);
                defer self.serializer.allocator.free(encoded);
                _ = encoder.encode(encoded, data);
                try json_obj.put("payload", std.json.Value{ .string = encoded });
            },
            .json => |json_str| {
                try json_obj.put("payload_type", std.json.Value{ .string = "json" });
                // 解析JSON字符串为对象
                var parser = std.json.Parser.init(self.serializer.allocator, false);
                defer parser.deinit();
                var tree = try parser.parse(json_str);
                defer tree.deinit();
                try json_obj.put("payload", tree.root);
            },
            .structured => |data| {
                try json_obj.put("payload_type", std.json.Value{ .string = "structured" });
                try json_obj.put("payload", std.json.Value{ .string = data });
            },
        }
    }
    
    fn serializeMetadata(self: *Self, json_obj: *std.json.ObjectMap, message: *const Message) !void {
        _ = self;
        _ = json_obj;
        _ = message;
        // 实现元数据序列化
        // 如correlation_id, reply_to, timeout等
    }
    
    fn deserializeMessageType(self: *Self, json_obj: *const std.json.ObjectMap, allocator: Allocator) !MessageType {
        const type_str = json_obj.get("type").?.string;
        
        if (std.mem.eql(u8, type_str, "user")) {
            const payload = try self.deserializePayload(json_obj, allocator);
            return MessageType{ .user = UserMessage{ .data = payload } };
        } else if (std.mem.eql(u8, type_str, "system")) {
            const sys_type_str = json_obj.get("system_type").?.string;
            const sys_msg = if (std.mem.eql(u8, sys_type_str, "start"))
                SystemMessage.start
            else if (std.mem.eql(u8, sys_type_str, "stop"))
                SystemMessage.stop
            else if (std.mem.eql(u8, sys_type_str, "restart"))
                SystemMessage.restart
            else if (std.mem.eql(u8, sys_type_str, "kill"))
                SystemMessage.kill
            else if (std.mem.eql(u8, sys_type_str, "watch"))
                SystemMessage.watch
            else if (std.mem.eql(u8, sys_type_str, "unwatch"))
                SystemMessage.unwatch
            else if (std.mem.eql(u8, sys_type_str, "terminated"))
                SystemMessage.terminated
            else
                SystemMessage.start;
            
            return MessageType{ .system = sys_msg };
        }
        
        return error.InvalidData;
    }
    
    fn deserializePayload(self: *Self, json_obj: *const std.json.ObjectMap, allocator: Allocator) !?MessagePayload {
        _ = self;
        const payload_type = json_obj.get("payload_type") orelse return null;
        const payload_data = json_obj.get("payload") orelse return null;
        
        const type_str = payload_type.string;
        
        if (std.mem.eql(u8, type_str, "string")) {
            const str = try allocator.dupe(u8, payload_data.string);
            return MessagePayload{ .string = str };
        } else if (std.mem.eql(u8, type_str, "binary")) {
            // Base64解码
            const decoder = std.base64.standard.Decoder;
            const decoded_len = try decoder.calcSizeForSlice(payload_data.string);
            const decoded = try allocator.alloc(u8, decoded_len);
            try decoder.decode(decoded, payload_data.string);
            return MessagePayload{ .binary = decoded };
        } else if (std.mem.eql(u8, type_str, "json")) {
            const json_str = try std.json.stringifyAlloc(allocator, payload_data, .{});
            return MessagePayload{ .json = json_str };
        } else if (std.mem.eql(u8, type_str, "structured")) {
            const str = try allocator.dupe(u8, payload_data.string);
            return MessagePayload{ .structured = str };
        }
        
        return null;
    }
};

// 二进制序列化器实现
pub const BinaryMessageSerializer = struct {
    const Self = @This();
    
    serializer: MessageSerializer,
    
    const vtable = MessageSerializer.VTable{
        .serialize = serialize,
        .deserialize = deserialize,
        .estimateSize = estimateSize,
        .getFormat = getFormat,
        .deinit = deinitImpl,
    };
    
    pub fn init(config: SerializationConfig, allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .serializer = MessageSerializer.init(&vtable, config, allocator),
        };
        return self;
    }
    
    pub fn getSerializer(self: *Self) *MessageSerializer {
        return &self.serializer;
    }
    
    fn serialize(serializer: *MessageSerializer, message: *const Message, buffer: []u8) !usize {
        _ = serializer;
        _ = message;
        _ = buffer;
        // 实现二进制序列化
        return error.NotImplemented;
    }
    
    fn deserialize(serializer: *MessageSerializer, data: []const u8, allocator: Allocator) !*Message {
        _ = serializer;
        _ = data;
        _ = allocator;
        // 实现二进制反序列化
        return error.NotImplemented;
    }
    
    fn estimateSize(serializer: *MessageSerializer, message: *const Message) usize {
        _ = serializer;
        _ = message;
        return 512; // 二进制格式通常更紧凑
    }
    
    fn getFormat(serializer: *MessageSerializer) SerializationFormat {
        _ = serializer;
        return .binary;
    }
    
    fn deinitImpl(serializer: *MessageSerializer) void {
        const self = @fieldParentPtr(Self, "serializer", serializer);
        self.serializer.allocator.destroy(self);
    }
};

// 序列化器工厂
pub const SerializerFactory = struct {
    pub fn create(format: SerializationFormat, config: SerializationConfig, allocator: Allocator) !*MessageSerializer {
        switch (format) {
            .json => {
                const json_serializer = try JsonMessageSerializer.init(config, allocator);
                return json_serializer.getSerializer();
            },
            .binary => {
                const binary_serializer = try BinaryMessageSerializer.init(config, allocator);
                return binary_serializer.getSerializer();
            },
            else => {
                return SerializationError.UnsupportedFormat;
            },
        }
    }
};

// 便利函数
pub fn createJsonSerializer(allocator: Allocator) !*MessageSerializer {
    const config = SerializationConfig{ .format = .json };
    return SerializerFactory.create(.json, config, allocator);
}

pub fn createBinarySerializer(allocator: Allocator) !*MessageSerializer {
    const config = SerializationConfig{ .format = .binary };
    return SerializerFactory.create(.binary, config, allocator);
}

pub fn createCompactSerializer(allocator: Allocator) !*MessageSerializer {
    const config = SerializationConfig.compact();
    return SerializerFactory.create(.binary, config, allocator);
}

// 测试
test "JsonMessageSerializer" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = SerializationConfig{ .format = .json, .pretty_print = true };
    const json_serializer = try JsonMessageSerializer.init(config, allocator);
    defer json_serializer.getSerializer().deinit();
    
    // 创建测试消息
    const message_type = MessageType{ .user = UserMessage{ .data = MessagePayload{ .string = "test message" } } };
    const message = try Message.init(allocator, message_type);
    defer message.deinit();
    
    // 序列化
    var buffer: [1024]u8 = undefined;
    const size = try json_serializer.getSerializer().serialize(message, &buffer);
    
    try testing.expect(size > 0);
    try testing.expect(size < buffer.len);
    
    // 反序列化
    const deserialized = try json_serializer.getSerializer().deserialize(buffer[0..size]);
    defer deserialized.deinit();
    
    try testing.expect(deserialized.getPriority() == message.getPriority());
}

test "SerializationStats" {
    const testing = std.testing;
    
    var stats = SerializationStats{};
    
    stats.updateSerializationTime(1000);
    stats.updateSerializationTime(2000);
    
    try testing.expect(stats.serializations == 2);
    try testing.expect(stats.avg_serialization_time_ns == 1500);
}

test "SerializerFactory" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = SerializationConfig.default();
    const serializer = try SerializerFactory.create(.json, config, allocator);
    defer serializer.deinit();
    
    try testing.expect(serializer.getFormat() == .json);
}