//! Fast Mailbox Implementation - 快速邮箱实现
//! 基于无锁队列的超高性能邮箱

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Message = @import("../message/mod.zig").Message;
const MailboxConfig = @import("mod.zig").MailboxConfig;
const MailboxStats = @import("mod.zig").MailboxStats;
const MailboxInterface = @import("mod.zig").MailboxInterface;
const LockFreeQueue = @import("../../utils/lockfree_queue.zig").LockFreeQueue;

// 快速邮箱实现 - 使用无锁队列
pub const FastMailbox = struct {
    const Self = @This();

    // 无锁队列用于最大吞吐量
    queue: LockFreeQueue(Message),

    // 统计信息
    stats: ?MailboxStats,
    config: MailboxConfig,
    allocator: Allocator,

    // 虚函数表
    pub const vtable = MailboxInterface.VTable{
        .send = send,
        .receive = receive,
        .isEmpty = isEmpty,
        .size = size,
        .capacity = getCapacity,
        .clear = clearVTable,
        .deinit = deinit,
        .destroy = destroy,
        .getStats = getStats,
    };

    pub fn init(allocator: Allocator, config: MailboxConfig) !Self {
        return Self{
            .queue = LockFreeQueue(Message).init(),
            .stats = if (config.enable_statistics) MailboxStats.init() else null,
            .config = config,
            .allocator = allocator,
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
        return self.config.capacity;
    }

    fn clearVTable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self.clear();
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinitImpl();
    }

    fn destroy(ptr: *anyopaque, allocator: Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinitImpl();
        allocator.destroy(self);
    }

    fn getStats(ptr: *anyopaque) ?*MailboxStats {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return if (self.stats) |*stats| stats else null;
    }

    // 实际实现方法
    pub fn sendMessage(self: *Self, message: Message) !void {
        if (self.queue.push(message)) {
            if (self.stats) |*stats| {
                stats.incrementSent();
                const current_size = self.sizeImpl();
                stats.updatePeakQueueSize(current_size);
            }
        } else {
            if (self.stats) |*stats| {
                stats.incrementDropped();
            }
            return error.MailboxFull;
        }
    }

    pub fn receiveMessage(self: *Self) ?Message {
        if (self.queue.pop()) |message| {
            if (self.stats) |*stats| {
                stats.incrementReceived();
            }
            return message;
        }
        return null;
    }

    pub fn isEmptyImpl(self: *const Self) bool {
        return self.queue.isEmpty();
    }

    pub fn sizeImpl(self: *const Self) u32 {
        return self.queue.size();
    }

    pub fn deinitImpl(self: *Self) void {
        // 清理剩余消息
        while (self.receiveMessage()) |message| {
            message.deinit(self.allocator);
        }
    }

    // 批量操作支持 - 针对高吞吐量优化
    pub fn sendBatch(self: *Self, messages: []const Message) !u32 {
        var sent_count: u32 = 0;

        if (self.config.enable_batching) {
            // 批量发送优化
            for (messages) |message| {
                if (self.queue.push(message)) {
                    sent_count += 1;
                } else {
                    break;
                }
            }

            if (self.stats) |*stats| {
                var i: u32 = 0;
                while (i < sent_count) : (i += 1) {
                    stats.incrementSent();
                }
                const current_size = self.sizeImpl();
                stats.updatePeakQueueSize(current_size);
            }
        } else {
            // 逐个发送
            for (messages) |message| {
                self.sendMessage(message) catch break;
                sent_count += 1;
            }
        }

        return sent_count;
    }

    pub fn receiveBatch(self: *Self, buffer: []Message) u32 {
        var received_count: u32 = 0;

        if (self.config.enable_batching) {
            // 批量接收优化
            for (buffer) |*slot| {
                if (self.queue.pop()) |message| {
                    slot.* = message;
                    received_count += 1;
                } else {
                    break;
                }
            }

            if (self.stats) |*stats| {
                var i: u32 = 0;
                while (i < received_count) : (i += 1) {
                    stats.incrementReceived();
                }
            }
        } else {
            // 逐个接收
            for (buffer) |*slot| {
                if (self.receiveMessage()) |message| {
                    slot.* = message;
                    received_count += 1;
                } else {
                    break;
                }
            }
        }

        return received_count;
    }

    // 高级功能
    pub fn tryReceiveWithTimeout(self: *Self, timeout_ns: u64) ?Message {
        const start_time = std.time.nanoTimestamp();

        while (std.time.nanoTimestamp() - start_time < timeout_ns) {
            if (self.receiveMessage()) |message| {
                return message;
            }
            // 短暂让出CPU
            std.Thread.yield() catch {};
        }

        return null;
    }

    pub fn peek(self: *const Self) ?Message {
        return self.queue.peek();
    }

    pub fn clear(self: *Self) u32 {
        var cleared_count: u32 = 0;
        while (self.receiveMessage()) |message| {
            message.deinit(self.allocator);
            cleared_count += 1;
        }
        return cleared_count;
    }
};

// 测试
test "FastMailbox basic operations" {
    const allocator = testing.allocator;
    const config = MailboxConfig{
        .capacity = 1000,
        .enable_statistics = true,
        .enable_batching = true,
    };

    var mailbox = try FastMailbox.init(allocator, config);
    defer mailbox.deinitImpl();

    // 测试空邮箱
    try testing.expect(mailbox.isEmptyImpl());
    try testing.expect(mailbox.receiveMessage() == null);

    // 测试发送和接收
    const message = Message.createSystem(.stop, null);
    try mailbox.sendMessage(message);

    try testing.expect(!mailbox.isEmptyImpl());

    const received = mailbox.receiveMessage();
    try testing.expect(received != null);
    try testing.expect(mailbox.isEmptyImpl());
}

test "FastMailbox batch operations" {
    const allocator = testing.allocator;
    const config = MailboxConfig{
        .capacity = 1000,
        .enable_statistics = true,
        .enable_batching = true,
        .batch_size = 10,
    };

    var mailbox = try FastMailbox.init(allocator, config);
    defer mailbox.deinitImpl();

    // 准备批量消息
    var messages: [5]Message = undefined;
    for (&messages) |*msg| {
        msg.* = Message.createSystem(.stop, null);
    }

    // 批量发送
    const sent_count = try mailbox.sendBatch(&messages);
    try testing.expect(sent_count == 5);

    // 批量接收
    var received_messages: [5]Message = undefined;
    const received_count = mailbox.receiveBatch(&received_messages);
    try testing.expect(received_count == 5);

    try testing.expect(mailbox.isEmptyImpl());
}
