//! 类型特化消息系统
//! 根据消息大小和类型进行优化的高性能消息传递

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 消息大小分类
pub const MessageSizeClass = enum {
    tiny, // <= 8 bytes
    small, // <= 64 bytes
    medium, // <= 1KB
    large, // <= 64KB
    huge, // > 64KB

    pub fn classify(size: usize) MessageSizeClass {
        if (size <= 8) return .tiny;
        if (size <= 64) return .small;
        if (size <= 1024) return .medium;
        if (size <= 65536) return .large;
        return .huge;
    }
};

/// 微型消息（内联存储）
pub const TinyMessage = struct {
    data: u64, // 8字节内联数据
    type_id: u32,
    sender_id: u32,

    pub fn init(type_id: u32, sender_id: u32, data: u64) TinyMessage {
        return TinyMessage{
            .data = data,
            .type_id = type_id,
            .sender_id = sender_id,
        };
    }

    pub fn fromBytes(bytes: []const u8) TinyMessage {
        var data: u64 = 0;
        const copy_len = @min(bytes.len, 8);
        @memcpy(@as([*]u8, @ptrCast(&data))[0..copy_len], bytes[0..copy_len]);
        return TinyMessage{
            .data = data,
            .type_id = 0,
            .sender_id = 0,
        };
    }

    pub fn toBytes(self: *const TinyMessage) [8]u8 {
        return @as([8]u8, @bitCast(self.data));
    }

    pub fn getSize(self: *const TinyMessage) usize {
        _ = self;
        return 8;
    }
};

/// 小型消息（栈分配）
pub const SmallMessage = struct {
    data: [64]u8,
    size: u8,
    type_id: u32,
    sender_id: u32,

    pub fn init(type_id: u32, sender_id: u32, payload: []const u8) SmallMessage {
        var msg = SmallMessage{
            .data = [_]u8{0} ** 64,
            .size = @as(u8, @intCast(@min(payload.len, 64))),
            .type_id = type_id,
            .sender_id = sender_id,
        };
        @memcpy(msg.data[0..msg.size], payload[0..msg.size]);
        return msg;
    }

    pub fn getPayload(self: *const SmallMessage) []const u8 {
        return self.data[0..self.size];
    }

    pub fn getSize(self: *const SmallMessage) usize {
        return self.size;
    }
};

/// 中型消息（池分配）
pub const MediumMessage = struct {
    data: []u8,
    type_id: u32,
    sender_id: u32,
    pool_index: u32, // 用于池回收

    pub fn init(type_id: u32, sender_id: u32, data: []u8, pool_index: u32) MediumMessage {
        return MediumMessage{
            .data = data,
            .type_id = type_id,
            .sender_id = sender_id,
            .pool_index = pool_index,
        };
    }

    pub fn getPayload(self: *const MediumMessage) []const u8 {
        return self.data;
    }

    pub fn getSize(self: *const MediumMessage) usize {
        return self.data.len;
    }
};

/// 大型消息（堆分配）
pub const LargeMessage = struct {
    data: []u8,
    type_id: u32,
    sender_id: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, type_id: u32, sender_id: u32, payload: []const u8) !LargeMessage {
        const data = try allocator.dupe(u8, payload);
        return LargeMessage{
            .data = data,
            .type_id = type_id,
            .sender_id = sender_id,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LargeMessage) void {
        self.allocator.free(self.data);
    }

    pub fn getPayload(self: *const LargeMessage) []const u8 {
        return self.data;
    }

    pub fn getSize(self: *const LargeMessage) usize {
        return self.data.len;
    }
};

/// 类型特化消息联合体
pub const TypedMessage = union(MessageSizeClass) {
    tiny: TinyMessage,
    small: SmallMessage,
    medium: MediumMessage,
    large: LargeMessage,
    huge: LargeMessage, // 超大消息也使用堆分配

    pub fn create(allocator: Allocator, type_id: u32, sender_id: u32, payload: []const u8, pool: ?*MessagePool) !TypedMessage {
        const size_class = MessageSizeClass.classify(payload.len);

        switch (size_class) {
            .tiny => {
                const tiny_msg = TinyMessage.fromBytes(payload);
                return TypedMessage{ .tiny = TinyMessage.init(type_id, sender_id, tiny_msg.data) };
            },
            .small => {
                return TypedMessage{ .small = SmallMessage.init(type_id, sender_id, payload) };
            },
            .medium => {
                if (pool) |p| {
                    if (p.acquire()) |buffer| {
                        const copy_len = @min(payload.len, buffer.len);
                        @memcpy(buffer[0..copy_len], payload[0..copy_len]);
                        return TypedMessage{ .medium = MediumMessage.init(type_id, sender_id, buffer[0..copy_len], 0) };
                    }
                }
                // 池分配失败，回退到堆分配
                const large_msg = try LargeMessage.init(allocator, type_id, sender_id, payload);
                return TypedMessage{ .large = large_msg };
            },
            .large, .huge => {
                const large_msg = try LargeMessage.init(allocator, type_id, sender_id, payload);
                if (size_class == .huge) {
                    return TypedMessage{ .huge = large_msg };
                } else {
                    return TypedMessage{ .large = large_msg };
                }
            },
        }
    }

    pub fn deinit(self: *TypedMessage) void {
        switch (self.*) {
            .tiny, .small => {}, // 无需释放
            .medium => |*msg| {
                // 应该归还到池中，这里简化处理
                _ = msg;
            },
            .large, .huge => |*msg| {
                msg.deinit();
            },
        }
    }

    pub fn getPayload(self: *const TypedMessage) []const u8 {
        switch (self.*) {
            .tiny => |*msg| return &msg.toBytes(),
            .small => |*msg| return msg.getPayload(),
            .medium => |*msg| return msg.getPayload(),
            .large, .huge => |*msg| return msg.getPayload(),
        }
    }

    pub fn getSize(self: *const TypedMessage) usize {
        switch (self.*) {
            .tiny => |*msg| return msg.getSize(),
            .small => |*msg| return msg.getSize(),
            .medium => |*msg| return msg.getSize(),
            .large, .huge => |*msg| return msg.getSize(),
        }
    }

    pub fn getTypeId(self: *const TypedMessage) u32 {
        switch (self.*) {
            .tiny => |*msg| return msg.type_id,
            .small => |*msg| return msg.type_id,
            .medium => |*msg| return msg.type_id,
            .large, .huge => |*msg| return msg.type_id,
        }
    }

    pub fn getSenderId(self: *const TypedMessage) u32 {
        switch (self.*) {
            .tiny => |*msg| return msg.sender_id,
            .small => |*msg| return msg.sender_id,
            .medium => |*msg| return msg.sender_id,
            .large, .huge => |*msg| return msg.sender_id,
        }
    }

    pub fn getSizeClass(self: *const TypedMessage) MessageSizeClass {
        return self.*;
    }
};

/// 消息池（用于中型消息）
pub const MessagePool = struct {
    const Self = @This();

    /// 简单的空闲列表节点
    const FreeNode = struct {
        buffer: []u8,
        next: ?*FreeNode,
    };

    buffers: [][]u8,
    free_list: std.atomic.Value(?*FreeNode),
    allocator: Allocator,
    buffer_size: usize,
    nodes: []FreeNode,

    pub fn init(allocator: Allocator, buffer_size: usize, num_buffers: usize) !*Self {
        const self = try allocator.create(Self);
        const buffers = try allocator.alloc([]u8, num_buffers);
        const nodes = try allocator.alloc(FreeNode, num_buffers);

        for (buffers, 0..) |*buffer, i| {
            buffer.* = try allocator.alloc(u8, buffer_size);
            nodes[i] = FreeNode{
                .buffer = buffer.*,
                .next = if (i + 1 < num_buffers) &nodes[i + 1] else null,
            };
        }

        self.* = Self{
            .buffers = buffers,
            .free_list = std.atomic.Value(?*FreeNode).init(if (num_buffers > 0) &nodes[0] else null),
            .allocator = allocator,
            .buffer_size = buffer_size,
            .nodes = nodes,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // 释放所有缓冲区
        for (self.buffers) |buffer| {
            self.allocator.free(buffer);
        }
        self.allocator.free(self.buffers);
        self.allocator.free(self.nodes);
        self.allocator.destroy(self);
    }

    pub fn acquire(self: *Self) ?[]u8 {
        while (true) {
            const current_head = self.free_list.load(.acquire);
            if (current_head == null) {
                return null;
            }

            const next = current_head.?.next;
            if (self.free_list.cmpxchgWeak(current_head, next, .release, .acquire) == null) {
                return current_head.?.buffer;
            }
        }
    }

    pub fn release(self: *Self, buffer: []u8) void {
        // 找到对应的节点
        for (self.nodes) |*node| {
            if (node.buffer.ptr == buffer.ptr and node.buffer.len == buffer.len) {
                while (true) {
                    const current_head = self.free_list.load(.acquire);
                    node.next = current_head;
                    if (self.free_list.cmpxchgWeak(current_head, node, .release, .acquire) == null) {
                        break;
                    }
                }
                return;
            }
        }
    }
};

// 测试
test "MessageSizeClass classification" {
    const testing = std.testing;

    try testing.expect(MessageSizeClass.classify(4) == .tiny);
    try testing.expect(MessageSizeClass.classify(32) == .small);
    try testing.expect(MessageSizeClass.classify(512) == .medium);
    try testing.expect(MessageSizeClass.classify(32768) == .large);
    try testing.expect(MessageSizeClass.classify(131072) == .huge);
}

test "TinyMessage operations" {
    const testing = std.testing;

    const msg = TinyMessage.init(1, 123, 0x1234567890ABCDEF);
    try testing.expect(msg.type_id == 1);
    try testing.expect(msg.sender_id == 123);
    try testing.expect(msg.data == 0x1234567890ABCDEF);

    const bytes = msg.toBytes();
    try testing.expect(bytes.len == 8);
}

test "TypedMessage creation and operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // 测试小型消息
    const small_payload = "Hello";
    var small_msg = try TypedMessage.create(allocator, 1, 123, small_payload, null);
    defer small_msg.deinit();

    try testing.expect(small_msg.getSizeClass() == .small);
    try testing.expect(small_msg.getTypeId() == 1);
    try testing.expect(small_msg.getSenderId() == 123);
    try testing.expect(std.mem.eql(u8, small_msg.getPayload(), small_payload));
}
