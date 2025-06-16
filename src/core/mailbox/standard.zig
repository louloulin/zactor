//! Standard Mailbox Implementation - 标准邮箱实现
//! 基于环形缓冲区和原子操作的高性能邮箱

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Message = @import("../message/mod.zig").Message;
const MailboxConfig = @import("mod.zig").MailboxConfig;
const MailboxStats = @import("mod.zig").MailboxStats;
const MailboxInterface = @import("mod.zig").MailboxInterface;

// 标准邮箱实现 - 使用环形缓冲区和原子操作
pub const StandardMailbox = struct {
    const Self = @This();
    
    messages: []Message,
    head: std.atomic.Value(u32), // 读取位置
    tail: std.atomic.Value(u32), // 写入位置
    capacity: u32,
    allocator: Allocator,
    stats: ?MailboxStats,
    config: MailboxConfig,
    
    // 虚函数表
    pub const vtable = MailboxInterface.VTable{
        .send = send,
        .receive = receive,
        .isEmpty = isEmpty,
        .size = size,
        .capacity = getCapacity,
        .deinit = deinit,
        .getStats = getStats,
    };
    
    pub fn init(allocator: Allocator, config: MailboxConfig) !Self {
        const capacity = if (config.capacity > 0) config.capacity else 32768;
        
        // 确保容量是2的幂
        const actual_capacity = std.math.ceilPowerOfTwo(u32, capacity) catch capacity;
        
        const messages = try allocator.alloc(Message, actual_capacity);
        
        // 初始化所有消息槽以避免未定义行为
        for (messages) |*msg| {
            msg.* = undefined;
        }
        
        return Self{
            .messages = messages,
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
            .capacity = actual_capacity,
            .allocator = allocator,
            .stats = if (config.enable_statistics) MailboxStats.init() else null,
            .config = config,
        };
    }
    
    // 虚函数实现
    fn send(ptr: *anyopaque, message: Message) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.sendMessage(message);
    }
    
    fn receive(ptr: *anyopaque) ?Message {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receiveMessage();
    }
    
    fn isEmpty(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.isEmptyImpl();
    }
    
    fn size(ptr: *anyopaque) u32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.sizeImpl();
    }
    
    fn getCapacity(ptr: *anyopaque) u32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.capacity;
    }
    
    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinitImpl();
    }
    
    fn getStats(ptr: *anyopaque) ?*MailboxStats {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return if (self.stats) |*stats| stats else null;
    }
    
    // 实际实现方法
    pub fn sendMessage(self: *Self, message: Message) !void {
        const tail = self.tail.load(.acquire);
        const head = self.head.load(.acquire);
        const next_tail = (tail + 1) % self.capacity;
        
        // 检查邮箱是否已满
        if (next_tail == head) {
            if (self.stats) |*stats| {
                stats.incrementDropped();
            }
            return error.MailboxFull;
        }
        
        // 存储消息
        self.messages[tail] = message;
        
        // 更新尾指针
        self.tail.store(next_tail, .release);
        
        // 更新统计信息
        if (self.stats) |*stats| {
            stats.incrementSent();
            const current_size = self.sizeImpl();
            stats.updatePeakQueueSize(current_size);
        }
    }
    
    pub fn receiveMessage(self: *Self) ?Message {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        
        // 检查邮箱是否为空
        if (head == tail) {
            return null;
        }
        
        // 获取消息
        const message = self.messages[head];
        
        // 更新头指针
        const next_head = (head + 1) % self.capacity;
        self.head.store(next_head, .release);
        
        // 更新统计信息
        if (self.stats) |*stats| {
            stats.incrementReceived();
        }
        
        return message;
    }
    
    pub fn isEmptyImpl(self: *const Self) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return head == tail;
    }
    
    pub fn sizeImpl(self: *const Self) u32 {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        
        if (tail >= head) {
            return tail - head;
        } else {
            return self.capacity - head + tail;
        }
    }
    
    pub fn deinitImpl(self: *Self) void {
        // 清理剩余消息
        while (self.receiveMessage()) |message| {
            message.deinit(self.allocator);
        }
        
        // 释放消息数组
        self.allocator.free(self.messages);
    }
    
    // 批量操作支持
    pub fn sendBatch(self: *Self, messages: []const Message) !u32 {
        var sent_count: u32 = 0;
        for (messages) |message| {
            self.sendMessage(message) catch break;
            sent_count += 1;
        }
        return sent_count;
    }
    
    pub fn receiveBatch(self: *Self, buffer: []Message) u32 {
        var received_count: u32 = 0;
        for (buffer) |*slot| {
            if (self.receiveMessage()) |message| {
                slot.* = message;
                received_count += 1;
            } else {
                break;
            }
        }
        return received_count;
    }
};

// 测试
test "StandardMailbox basic operations" {
    const allocator = testing.allocator;
    const config = MailboxConfig{
        .capacity = 16,
        .enable_statistics = true,
    };
    
    var mailbox = try StandardMailbox.init(allocator, config);
    defer mailbox.deinitImpl();
    
    // 测试空邮箱
    try testing.expect(mailbox.isEmptyImpl());
    try testing.expect(mailbox.sizeImpl() == 0);
    try testing.expect(mailbox.receiveMessage() == null);
    
    // 测试发送和接收
    const message = Message.createSystem(.stop, null);
    try mailbox.sendMessage(message);
    
    try testing.expect(!mailbox.isEmptyImpl());
    try testing.expect(mailbox.sizeImpl() == 1);
    
    const received = mailbox.receiveMessage();
    try testing.expect(received != null);
    try testing.expect(mailbox.isEmptyImpl());
}

test "StandardMailbox capacity limit" {
    const allocator = testing.allocator;
    const config = MailboxConfig{
        .capacity = 4,
        .enable_statistics = true,
    };
    
    var mailbox = try StandardMailbox.init(allocator, config);
    defer mailbox.deinitImpl();
    
    // 填满邮箱
    const message = Message.createSystem(.stop, null);
    
    // 应该能发送 capacity-1 条消息
    var i: u32 = 0;
    while (i < mailbox.capacity - 1) : (i += 1) {
        try mailbox.sendMessage(message);
    }
    
    // 下一条消息应该失败
    try testing.expectError(error.MailboxFull, mailbox.sendMessage(message));
}