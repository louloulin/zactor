//! ActorRef Implementation - ActorRef实现
//! 提供Actor的引用和远程通信接口

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;

// 导入相关模块
const Actor = @import("actor.zig").Actor;
const Message = @import("../message/mod.zig").Message;
const SystemMessage = @import("../message/mod.zig").SystemMessage;
const ActorPath = @import("mod.zig").ActorPath;
const ActorError = @import("mod.zig").ActorError;

// ActorRef类型
pub const ActorRefType = enum {
    local,
    remote,
    cluster,
};

// ActorRef接口
pub const ActorRef = struct {
    const Self = @This();

    vtable: *const VTable,
    ref_type: ActorRefType,
    path: ActorPath,
    allocator: Allocator,

    pub const VTable = struct {
        tell: *const fn (self: *ActorRef, message: *Message, sender: ?*ActorRef) anyerror!void,
        ask: *const fn (self: *ActorRef, message: *Message, timeout_ms: u64) anyerror!*Message,
        forward: *const fn (self: *ActorRef, message: *Message, sender: *ActorRef) anyerror!void,
        isLocal: *const fn (self: *ActorRef) bool,
        isTerminated: *const fn (self: *ActorRef) bool,
        getPath: *const fn (self: *ActorRef) ActorPath,
        compareTo: *const fn (self: *ActorRef, other: *ActorRef) bool,
    };

    pub fn init(vtable: *const VTable, ref_type: ActorRefType, path: ActorPath, allocator: Allocator) ActorRef {
        return ActorRef{
            .vtable = vtable,
            .ref_type = ref_type,
            .path = path,
            .allocator = allocator,
        };
    }

    pub fn tell(self: *Self, message: *Message, sender: ?*ActorRef) !void {
        try self.vtable.tell(self, message, sender);
    }

    pub fn ask(self: *Self, message: *Message, timeout_ms: u64) !*Message {
        return self.vtable.ask(self, message, timeout_ms);
    }

    // 便捷方法：发送用户消息
    pub fn send(self: *Self, comptime T: type, data: T, allocator: Allocator) !void {
        _ = allocator;
        // 将数据转换为字符串
        const data_str = switch (T) {
            []const u8 => data,
            else => @panic("Unsupported data type for send"),
        };

        var message = Message.createUser(.custom, data_str);
        try self.tell(&message, null);
    }

    // 便捷方法：发送系统消息
    pub fn sendSystem(self: *Self, system_msg: SystemMessage) !void {
        var message = Message.createSystem(system_msg, null);
        try self.tell(&message, null);
    }

    pub fn forward(self: *Self, message: *Message, sender: *ActorRef) !void {
        try self.vtable.forward(self, message, sender);
    }

    pub fn isLocal(self: *Self) bool {
        return self.vtable.isLocal(self);
    }

    pub fn isTerminated(self: *Self) bool {
        return self.vtable.isTerminated(self);
    }

    pub fn getPath(self: *Self) ActorPath {
        return self.vtable.getPath(self);
    }

    pub fn equals(self: *Self, other: *ActorRef) bool {
        return self.vtable.compareTo(self, other);
    }

    pub fn deinit(self: *Self) void {
        self.path.deinit();
    }

    pub fn getId(self: *const Self) []const u8 {
        // 返回路径的字符串表示，这里简化为返回最后一个段
        // 在实际使用中可能需要分配内存
        if (self.path.segments.len > 0) {
            return self.path.segments[self.path.segments.len - 1];
        } else {
            return "unknown";
        }
    }

    /// 获取底层Actor（仅适用于本地ActorRef）
    pub fn getLocalActor(self: *Self) ?*Actor {
        if (!self.isLocal()) return null;

        const local_ref = @as(*LocalActorRef, @fieldParentPtr("actor_ref", self));
        return local_ref.getActor();
    }
};

// 本地ActorRef实现
pub const LocalActorRef = struct {
    const Self = @This();

    actor_ref: ActorRef,
    actor: *Actor,

    const vtable = ActorRef.VTable{
        .tell = tell,
        .ask = ask,
        .forward = forward,
        .isLocal = isLocal,
        .isTerminated = isTerminated,
        .getPath = getPath,
        .compareTo = compareTo,
    };

    pub fn init(actor: *Actor, path: ActorPath, allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .actor_ref = ActorRef.init(&vtable, .local, path, allocator),
            .actor = actor,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.actor_ref.deinit();
        // 注意：不要在这里释放self，应该由调用者负责
    }

    pub fn getActorRef(self: *Self) *ActorRef {
        return &self.actor_ref;
    }

    pub fn getActor(self: *Self) *Actor {
        return self.actor;
    }

    fn tell(actor_ref: *ActorRef, message: *Message, sender: ?*ActorRef) !void {
        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));

        // 设置发送者信息
        if (sender) |s| {
            if (s.isLocal()) {
                const local_sender = @as(*LocalActorRef, @fieldParentPtr("actor_ref", s));
                try self.actor.send(message, local_sender.actor);
            } else {
                // 远程发送者，需要序列化路径信息
                try self.actor.send(message, null);
            }
        } else {
            try self.actor.send(message, null);
        }
    }

    fn ask(actor_ref: *ActorRef, message: *Message, timeout_ms: u64) !*Message {
        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));

        // 创建临时Actor来接收回复
        const temp_actor = try createTempActor(actor_ref.allocator, timeout_ms);
        defer destroyTempActor(temp_actor, actor_ref.allocator);

        // 发送消息
        try self.actor.send(message, temp_actor);

        // 等待回复
        return waitForReply(temp_actor, timeout_ms);
    }

    fn forward(actor_ref: *ActorRef, message: *Message, sender: *ActorRef) !void {
        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));

        // 保持原始发送者信息
        if (sender.isLocal()) {
            const local_sender = @as(*LocalActorRef, @fieldParentPtr("actor_ref", sender));
            try self.actor.send(message, local_sender.actor);
        } else {
            try self.actor.send(message, null);
        }
    }

    fn isLocal(actor_ref: *ActorRef) bool {
        _ = actor_ref;
        return true;
    }

    fn isTerminated(actor_ref: *ActorRef) bool {
        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));
        return self.actor.isStopped();
    }

    fn getPath(actor_ref: *ActorRef) ActorPath {
        return actor_ref.path;
    }

    fn compareTo(actor_ref: *ActorRef, other: *ActorRef) bool {
        if (!other.isLocal()) return false;

        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));
        const other_local = @as(*LocalActorRef, @fieldParentPtr("actor_ref", other));

        return self.actor == other_local.actor;
    }
};

// 远程ActorRef实现
pub const RemoteActorRef = struct {
    const Self = @This();

    actor_ref: ActorRef,
    remote_address: []const u8,
    serializer: *MessageSerializer,
    transport: *RemoteTransport,

    const vtable = ActorRef.VTable{
        .tell = tell,
        .ask = ask,
        .forward = forward,
        .isLocal = isLocal,
        .isTerminated = isTerminated,
        .getPath = getPath,
        .compareTo = compareTo,
    };

    pub fn init(
        remote_address: []const u8,
        path: ActorPath,
        serializer: *MessageSerializer,
        transport: *RemoteTransport,
        allocator: Allocator,
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .actor_ref = ActorRef.init(&vtable, .remote, path, allocator),
            .remote_address = try allocator.dupe(u8, remote_address),
            .serializer = serializer,
            .transport = transport,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.actor_ref.allocator.free(self.remote_address);
        self.actor_ref.deinit();
        self.actor_ref.allocator.destroy(self);
    }

    pub fn getActorRef(self: *Self) *ActorRef {
        return &self.actor_ref;
    }

    fn tell(actor_ref: *ActorRef, message: *Message, sender: ?*ActorRef) !void {
        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));

        // 序列化消息
        const serialized = try self.serializer.serializeMessage(message, actor_ref.allocator);
        defer actor_ref.allocator.free(serialized);

        // 创建远程消息包
        const remote_message = RemoteMessage{
            .target_path = actor_ref.path,
            .sender_path = if (sender) |s| s.getPath() else null,
            .payload = serialized,
            .message_id = generateMessageId(),
            .timestamp = std.time.milliTimestamp(),
        };

        // 发送到远程节点
        try self.transport.send(self.remote_address, remote_message);
    }

    fn ask(actor_ref: *ActorRef, message: *Message, timeout_ms: u64) !*Message {
        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));

        // 创建回复通道
        const reply_channel = try createReplyChannel(actor_ref.allocator, timeout_ms);
        defer destroyReplyChannel(reply_channel, actor_ref.allocator);

        // 序列化消息
        const serialized = try self.serializer.serializeMessage(message, actor_ref.allocator);
        defer actor_ref.allocator.free(serialized);

        // 创建远程请求消息
        const remote_message = RemoteMessage{
            .target_path = actor_ref.path,
            .sender_path = reply_channel.path,
            .payload = serialized,
            .message_id = generateMessageId(),
            .timestamp = std.time.milliTimestamp(),
            .reply_to = reply_channel.address,
        };

        // 发送请求
        try self.transport.send(self.remote_address, remote_message);

        // 等待回复
        return reply_channel.waitForReply(timeout_ms);
    }

    fn forward(actor_ref: *ActorRef, message: *Message, sender: *ActorRef) !void {
        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));

        // 序列化消息（保持原始发送者信息）
        const serialized = try self.serializer.serializeMessage(message, actor_ref.allocator);
        defer actor_ref.allocator.free(serialized);

        // 创建转发消息
        const remote_message = RemoteMessage{
            .target_path = actor_ref.path,
            .sender_path = sender.getPath(),
            .payload = serialized,
            .message_id = generateMessageId(),
            .timestamp = std.time.milliTimestamp(),
            .forwarded = true,
        };

        // 发送到远程节点
        try self.transport.send(self.remote_address, remote_message);
    }

    fn isLocal(actor_ref: *ActorRef) bool {
        _ = actor_ref;
        return false;
    }

    fn isTerminated(actor_ref: *ActorRef) bool {
        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));
        // 检查远程连接状态
        return !self.transport.isConnected(self.remote_address);
    }

    fn getPath(actor_ref: *ActorRef) ActorPath {
        return actor_ref.path;
    }

    fn compareTo(actor_ref: *ActorRef, other: *ActorRef) bool {
        if (other.isLocal()) return false;

        const self = @as(*Self, @fieldParentPtr("actor_ref", actor_ref));
        const other_remote = @as(*RemoteActorRef, @fieldParentPtr("actor_ref", other));

        return std.mem.eql(u8, self.remote_address, other_remote.remote_address) and
            std.mem.eql(u8, self.actor_ref.path.toString(self.actor_ref.allocator) catch "", other.path.toString(other.allocator) catch "");
    }
};

// 远程消息结构
pub const RemoteMessage = struct {
    target_path: ActorPath,
    sender_path: ?ActorPath,
    payload: []const u8,
    message_id: u64,
    timestamp: i64,
    reply_to: ?[]const u8 = null,
    forwarded: bool = false,
};

// 消息序列化器接口
pub const MessageSerializer = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        deserialize: *const fn (self: *MessageSerializer, data: []const u8, allocator: Allocator) anyerror!*Message,
        serializeMessage: *const fn (self: *MessageSerializer, message: *Message, allocator: Allocator) anyerror![]u8,
    };

    pub fn deserialize(self: *MessageSerializer, data: []const u8, allocator: Allocator) !*Message {
        return self.vtable.deserialize(self, data, allocator);
    }

    pub fn serializeMessage(self: *MessageSerializer, message: *Message, allocator: Allocator) ![]u8 {
        return self.vtable.serializeMessage(self, message, allocator);
    }
};

// 远程传输接口
pub const RemoteTransport = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (self: *RemoteTransport, address: []const u8, message: RemoteMessage) anyerror!void,
        isConnected: *const fn (self: *RemoteTransport, address: []const u8) bool,
        connect: *const fn (self: *RemoteTransport, address: []const u8) anyerror!void,
        disconnect: *const fn (self: *RemoteTransport, address: []const u8) void,
    };

    pub fn send(self: *RemoteTransport, address: []const u8, message: RemoteMessage) !void {
        try self.vtable.send(self, address, message);
    }

    pub fn isConnected(self: *RemoteTransport, address: []const u8) bool {
        return self.vtable.isConnected(self, address);
    }

    pub fn connect(self: *RemoteTransport, address: []const u8) !void {
        try self.vtable.connect(self, address);
    }

    pub fn disconnect(self: *RemoteTransport, address: []const u8) void {
        self.vtable.disconnect(self, address);
    }
};

// 辅助函数
fn createTempActor(allocator: Allocator, timeout_ms: u64) !*Actor {
    _ = allocator;
    _ = timeout_ms;
    // 实现临时Actor创建逻辑
    return error.NotImplemented;
}

fn destroyTempActor(actor: *Actor, allocator: Allocator) void {
    _ = actor;
    _ = allocator;
    // 实现临时Actor销毁逻辑
}

fn waitForReply(actor: *Actor, timeout_ms: u64) !*Message {
    _ = actor;
    _ = timeout_ms;
    // 实现等待回复逻辑
    return error.NotImplemented;
}

fn createReplyChannel(allocator: Allocator, timeout_ms: u64) !*ReplyChannel {
    _ = allocator;
    _ = timeout_ms;
    // 实现回复通道创建逻辑
    return error.NotImplemented;
}

fn destroyReplyChannel(channel: *ReplyChannel, allocator: Allocator) void {
    _ = channel;
    _ = allocator;
    // 实现回复通道销毁逻辑
}

fn generateMessageId() u64 {
    // 生成唯一消息ID
    return @intCast(std.time.nanoTimestamp());
}

// 回复通道结构
const ReplyChannel = struct {
    path: ActorPath,
    address: []const u8,

    fn waitForReply(self: *ReplyChannel, timeout_ms: u64) !*Message {
        _ = self;
        _ = timeout_ms;
        return error.NotImplemented;
    }
};

// 测试
test "ActorRef types" {
    const testing = std.testing;

    try testing.expect(ActorRefType.local != ActorRefType.remote);
    try testing.expect(ActorRefType.remote != ActorRefType.cluster);
}

test "LocalActorRef" {
    const testing = std.testing;
    const allocator = testing.allocator;
    _ = allocator;

    // 需要实际的Actor实例来测试
    // 暂时跳过，等待Actor模块完成
}

test "RemoteMessage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var path = try ActorPath.init(allocator, "/user/test");
    defer path.deinit();

    const message = RemoteMessage{
        .target_path = path,
        .sender_path = null,
        .payload = "test payload",
        .message_id = 12345,
        .timestamp = std.time.milliTimestamp(),
    };

    try testing.expect(message.message_id == 12345);
    try testing.expect(!message.forwarded);
}
