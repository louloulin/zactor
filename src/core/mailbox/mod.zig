//! Mailbox module - 邮箱模块
//! 提供抽象的邮箱接口，支持动态配置不同类型的邮箱实现

const std = @import("std");
const Allocator = std.mem.Allocator;
const Message = @import("../message/mod.zig").Message;

// Mailbox类型枚举
pub const MailboxType = enum {
    standard, // 标准邮箱 (ring buffer)
    fast, // 快速邮箱 (lock-free)
    high_perf, // 高性能邮箱
    ultra_fast, // 超高速邮箱
};

// Mailbox配置
pub const MailboxConfig = struct {
    mailbox_type: MailboxType = .standard,
    capacity: u32 = 32768,
    enable_batching: bool = false,
    batch_size: u32 = 100,
    enable_statistics: bool = true,
    enable_backpressure: bool = true,

    pub fn default() MailboxConfig {
        return MailboxConfig{};
    }
};

// Mailbox统计信息
pub const MailboxStats = struct {
    messages_sent: std.atomic.Value(u64),
    messages_received: std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),
    peak_queue_size: std.atomic.Value(u32),

    pub fn init() MailboxStats {
        return MailboxStats{
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_received = std.atomic.Value(u64).init(0),
            .messages_dropped = std.atomic.Value(u64).init(0),
            .peak_queue_size = std.atomic.Value(u32).init(0),
        };
    }

    pub fn incrementSent(self: *MailboxStats) void {
        _ = self.messages_sent.fetchAdd(1, .monotonic);
    }

    pub fn incrementReceived(self: *MailboxStats) void {
        _ = self.messages_received.fetchAdd(1, .monotonic);
    }

    pub fn incrementDropped(self: *MailboxStats) void {
        _ = self.messages_dropped.fetchAdd(1, .monotonic);
    }

    pub fn updatePeakQueueSize(self: *MailboxStats, size: u32) void {
        const current_peak = self.peak_queue_size.load(.monotonic);
        if (size > current_peak) {
            self.peak_queue_size.store(size, .monotonic);
        }
    }
};

// Mailbox接口 - 所有邮箱实现都必须实现这个接口
pub const MailboxInterface = struct {
    const Self = @This();

    // 虚函数表
    vtable: *const VTable,
    ptr: *anyopaque,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, message: *Message) anyerror!void,
        receive: *const fn (ptr: *anyopaque) ?*Message,
        isEmpty: *const fn (ptr: *anyopaque) bool,
        size: *const fn (ptr: *anyopaque) u32,
        capacity: *const fn (ptr: *anyopaque) u32,
        deinit: *const fn (ptr: *anyopaque) void,
        getStats: *const fn (ptr: *anyopaque) ?*MailboxStats,
    };

    pub fn send(self: Self, message: *Message) !void {
        return self.vtable.send(self.ptr, message);
    }

    pub fn receive(self: Self) ?*Message {
        return self.vtable.receive(self.ptr);
    }

    pub fn isEmpty(self: Self) bool {
        return self.vtable.isEmpty(self.ptr);
    }

    pub fn size(self: Self) u32 {
        return self.vtable.size(self.ptr);
    }

    pub fn capacity(self: Self) u32 {
        return self.vtable.capacity(self.ptr);
    }

    pub fn deinit(self: Self) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getStats(self: Self) ?*MailboxStats {
        return self.vtable.getStats(self.ptr);
    }
};

// Mailbox工厂 - 根据配置创建不同类型的邮箱
pub const MailboxFactory = struct {
    pub fn create(config: MailboxConfig, allocator: Allocator) !MailboxInterface {
        switch (config.mailbox_type) {
            .standard => {
                const mailbox = try allocator.create(StandardMailbox);
                mailbox.* = try StandardMailbox.init(allocator, config);
                return MailboxInterface{
                    .vtable = &StandardMailbox.vtable,
                    .ptr = mailbox,
                };
            },
            .fast => {
                const mailbox = try allocator.create(FastMailbox);
                mailbox.* = try FastMailbox.init(allocator, config);
                return MailboxInterface{
                    .vtable = &FastMailbox.vtable,
                    .ptr = mailbox,
                };
            },
            .high_perf => {
                const mailbox = try allocator.create(HighPerfMailbox);
                mailbox.* = try HighPerfMailbox.init(allocator, config);
                return MailboxInterface{
                    .vtable = &HighPerfMailbox.vtable,
                    .ptr = mailbox,
                };
            },
            .ultra_fast => {
                const mailbox = try allocator.create(UltraFastMailbox);
                mailbox.* = try UltraFastMailbox.init(allocator, config);
                return MailboxInterface{
                    .vtable = &UltraFastMailbox.vtable,
                    .ptr = mailbox,
                };
            },
        }
    }
};

// 为了向后兼容，重新导出Mailbox类型
pub const Mailbox = MailboxInterface;

// 导出具体实现
pub const StandardMailbox = @import("standard.zig").StandardMailbox;
pub const FastMailbox = @import("fast.zig").FastMailbox;
pub const HighPerfMailbox = @import("high_perf.zig").HighPerfMailbox;
pub const UltraFastMailbox = @import("ultra_fast.zig").UltraFastMailbox;
