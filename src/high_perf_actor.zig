const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

// Import all high-performance components
const FastMessage = @import("message_pool.zig").FastMessage;
const MessagePool = @import("message_pool.zig").MessagePool;
const MessageBatch = @import("message_pool.zig").MessageBatch;
const FastMailbox = @import("fast_mailbox.zig").FastMailbox;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;
const MPSCQueue = @import("lockfree_queue.zig").MPSCQueue;

// 高性能Actor实现
pub const HighPerfActor = struct {
    const Self = @This();
    const MAX_BATCH_SIZE = 1024;
    const PROCESSING_QUANTUM_US = 100; // 100微秒处理量子

    // Actor核心数据
    id: u32,
    name: []const u8,
    mailbox: FastMailbox,
    behavior: *anyopaque,
    vtable: *const ActorVTable,

    // 性能优化数据
    message_buffer: [MAX_BATCH_SIZE]*FastMessage,
    batch_processor: MessageBatch,

    // 统计和监控
    stats: ActorStats,
    last_process_time: std.atomic.Value(i128),
    processing_state: std.atomic.Value(ProcessingState),

    // 内存管理
    allocator: Allocator,
    message_pool: *MessagePool,

    pub fn init(
        id: u32,
        name: []const u8,
        behavior: *anyopaque,
        vtable: *const ActorVTable,
        message_pool: *MessagePool,
        allocator: Allocator,
    ) Self {
        return Self{
            .id = id,
            .name = name,
            .mailbox = FastMailbox.init(),
            .behavior = behavior,
            .vtable = vtable,
            .message_buffer = undefined,
            .batch_processor = MessageBatch.init(),
            .stats = ActorStats.init(),
            .last_process_time = std.atomic.Value(i128).init(std.time.nanoTimestamp()),
            .processing_state = std.atomic.Value(ProcessingState).init(.idle),
            .allocator = allocator,
            .message_pool = message_pool,
        };
    }

    pub fn deinit(self: *Self) void {
        // 清理剩余消息
        while (self.mailbox.receive()) |msg| {
            self.message_pool.release(msg);
        }
        self.mailbox.deinit();
    }

    // 高性能批量消息处理
    pub fn processBatch(self: *Self) u64 {
        const start_time = std.time.nanoTimestamp();

        // 设置处理状态
        self.processing_state.store(.processing, .monotonic);
        defer self.processing_state.store(.idle, .monotonic);

        // 批量接收消息
        const received = self.mailbox.receiveBatchDirect(self.message_buffer[0..]);
        if (received == 0) {
            return 0;
        }

        var processed: u64 = 0;
        const quantum_start = start_time;

        // 处理消息，但限制处理时间量子
        for (self.message_buffer[0..received]) |msg| {
            // 检查是否超过处理量子
            const current_time = std.time.nanoTimestamp();
            const elapsed_us = @divTrunc(current_time - quantum_start, 1000);

            if (elapsed_us > PROCESSING_QUANTUM_US and processed > 0) {
                // 超过量子时间，将剩余消息放回mailbox
                self.returnUnprocessedMessages(self.message_buffer[processed..received]);
                break;
            }

            if (self.processMessage(msg)) {
                processed += 1;
                self.message_pool.release(msg);
            } else {
                // 处理失败，释放消息
                self.message_pool.release(msg);
            }
        }

        // 更新统计
        _ = self.stats.messages_processed.fetchAdd(processed, .monotonic);
        _ = self.stats.batch_operations.fetchAdd(1, .monotonic);
        self.last_process_time.store(std.time.nanoTimestamp(), .monotonic);

        return processed;
    }

    // 处理单个消息（内联优化）
    inline fn processMessage(self: *Self, msg: *FastMessage) bool {
        // 验证消息
        if (!msg.validate()) {
            _ = self.stats.invalid_messages.fetchAdd(1, .monotonic);
            return false;
        }

        // 调用用户定义的处理逻辑
        return self.vtable.receive(self.behavior, msg);
    }

    // 将未处理的消息放回mailbox
    fn returnUnprocessedMessages(self: *Self, messages: []*FastMessage) void {
        // 创建批量消息
        var batch = MessageBatch.init();
        for (messages) |msg| {
            if (!batch.add(msg)) {
                // 批量满了，发送当前批量
                _ = self.mailbox.sendBatch(&batch);
                batch.clear();
                _ = batch.add(msg);
            }
        }

        // 发送剩余消息
        if (batch.count > 0) {
            _ = self.mailbox.sendBatch(&batch);
        }
    }

    // 发送消息到此Actor
    pub fn send(self: *Self, msg: *FastMessage) bool {
        const sent = self.mailbox.send(msg);
        if (sent) {
            _ = self.stats.messages_received.fetchAdd(1, .monotonic);
        } else {
            _ = self.stats.messages_dropped.fetchAdd(1, .monotonic);
        }
        return sent;
    }

    // 批量发送消息
    pub fn sendBatch(self: *Self, batch: *const MessageBatch) u32 {
        const sent = self.mailbox.sendBatch(batch);
        _ = self.stats.messages_received.fetchAdd(sent, .monotonic);
        _ = self.stats.messages_dropped.fetchAdd(batch.count - sent, .monotonic);
        return sent;
    }

    // Actor生命周期管理
    pub fn start(self: *Self) void {
        self.processing_state.store(.running, .monotonic);
        self.vtable.preStart(self.behavior);
        _ = self.stats.lifecycle_events.fetchAdd(1, .monotonic);
    }

    pub fn stop(self: *Self) void {
        self.processing_state.store(.stopping, .monotonic);
        self.vtable.preStop(self.behavior);
        self.processing_state.store(.stopped, .monotonic);
        self.vtable.postStop(self.behavior);
        _ = self.stats.lifecycle_events.fetchAdd(1, .monotonic);
    }

    pub fn restart(self: *Self, reason: anyerror) void {
        self.processing_state.store(.restarting, .monotonic);
        self.vtable.preRestart(self.behavior, reason);
        self.vtable.postRestart(self.behavior);
        self.processing_state.store(.running, .monotonic);
        _ = self.stats.lifecycle_events.fetchAdd(1, .monotonic);
    }

    // 性能监控
    pub fn getStats(self: *Self) ActorStats {
        var stats = self.stats;

        // 添加mailbox统计
        const mailbox_stats = self.mailbox.getStats();
        stats.mailbox_size = mailbox_stats.current_size;
        stats.mailbox_capacity = mailbox_stats.capacity;

        // 计算处理速率
        const now = std.time.nanoTimestamp();
        const last_time = self.last_process_time.load(.monotonic);
        const elapsed_ms = @divTrunc(now - last_time, 1000000);

        if (elapsed_ms > 0) {
            const processed = stats.messages_processed.load(.monotonic);
            stats.processing_rate = @divTrunc(processed * 1000, @as(u64, @intCast(elapsed_ms)));
        }

        stats.current_state = self.processing_state.load(.monotonic);

        return stats;
    }

    pub fn resetStats(self: *Self) void {
        self.stats = ActorStats.init();
        self.mailbox.resetStats();
    }

    // 健康检查
    pub fn isHealthy(self: *Self) bool {
        const state = self.processing_state.load(.monotonic);
        const mailbox_stats = self.mailbox.getStats();

        return switch (state) {
            .running, .idle => mailbox_stats.getDropRate() < 0.01, // 丢失率小于1%
            .processing => true,
            else => false,
        };
    }

    // 获取负载指标
    pub fn getLoadMetrics(self: *Self) LoadMetrics {
        const mailbox_stats = self.mailbox.getStats();
        const utilization = @as(f64, @floatFromInt(mailbox_stats.current_size)) /
            @as(f64, @floatFromInt(mailbox_stats.capacity));

        return LoadMetrics{
            .mailbox_utilization = utilization,
            .processing_rate = self.getStats().processing_rate,
            .drop_rate = mailbox_stats.getDropRate(),
            .is_processing = self.processing_state.load(.monotonic) == .processing,
        };
    }
};

// Actor处理状态 - 使用u8以支持原子操作
pub const ProcessingState = enum(u8) {
    idle = 0,
    running = 1,
    processing = 2,
    stopping = 3,
    stopped = 4,
    restarting = 5,
    failed = 6,
};

// Actor统计信息
pub const ActorStats = struct {
    messages_received: std.atomic.Value(u64),
    messages_processed: std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),
    invalid_messages: std.atomic.Value(u64),
    batch_operations: std.atomic.Value(u64),
    lifecycle_events: std.atomic.Value(u64),

    // 运行时统计
    processing_rate: u64,
    mailbox_size: u32,
    mailbox_capacity: u32,
    current_state: ProcessingState,

    pub fn init() ActorStats {
        return ActorStats{
            .messages_received = std.atomic.Value(u64).init(0),
            .messages_processed = std.atomic.Value(u64).init(0),
            .messages_dropped = std.atomic.Value(u64).init(0),
            .invalid_messages = std.atomic.Value(u64).init(0),
            .batch_operations = std.atomic.Value(u64).init(0),
            .lifecycle_events = std.atomic.Value(u64).init(0),
            .processing_rate = 0,
            .mailbox_size = 0,
            .mailbox_capacity = 0,
            .current_state = .idle,
        };
    }
};

// 负载指标
pub const LoadMetrics = struct {
    mailbox_utilization: f64,
    processing_rate: u64,
    drop_rate: f64,
    is_processing: bool,
};

// Actor行为虚函数表
pub const ActorVTable = struct {
    receive: *const fn (behavior: *anyopaque, msg: *FastMessage) bool,
    preStart: *const fn (behavior: *anyopaque) void,
    preStop: *const fn (behavior: *anyopaque) void,
    postStop: *const fn (behavior: *anyopaque) void,
    preRestart: *const fn (behavior: *anyopaque, reason: anyerror) void,
    postRestart: *const fn (behavior: *anyopaque) void,
};

// 高性能Actor行为特征
pub fn HighPerfActorBehavior(comptime T: type) type {
    return struct {
        pub fn getVTable() ActorVTable {
            return ActorVTable{
                .receive = receive,
                .preStart = preStart,
                .preStop = preStop,
                .postStop = postStop,
                .preRestart = preRestart,
                .postRestart = postRestart,
            };
        }

        fn receive(behavior: *anyopaque, msg: *FastMessage) bool {
            const self: *T = @ptrCast(@alignCast(behavior));
            return self.receive(msg);
        }

        fn preStart(behavior: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(behavior));
            if (@hasDecl(T, "preStart")) {
                self.preStart();
            }
        }

        fn preStop(behavior: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(behavior));
            if (@hasDecl(T, "preStop")) {
                self.preStop();
            }
        }

        fn postStop(behavior: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(behavior));
            if (@hasDecl(T, "postStop")) {
                self.postStop();
            }
        }

        fn preRestart(behavior: *anyopaque, reason: anyerror) void {
            const self: *T = @ptrCast(@alignCast(behavior));
            if (@hasDecl(T, "preRestart")) {
                self.preRestart(reason);
            }
        }

        fn postRestart(behavior: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(behavior));
            if (@hasDecl(T, "postRestart")) {
                self.postRestart();
            }
        }
    };
}
