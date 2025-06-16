//! High-Performance Actor Implementation
//! 基于Zig comptime和零成本抽象的Actor实现

const std = @import("std");
const Allocator = std.mem.Allocator;
const AtomicValue = std.atomic.Value;
const Thread = std.Thread;
const mod = @import("mod.zig");
const FastMessage = mod.FastMessage;
const ActorId = mod.ActorId;
const SPSCQueue = mod.SPSCQueue;
const BatchProcessor = mod.BatchProcessor;
const PerformanceStats = mod.PerformanceStats;

// Actor状态
pub const ActorState = enum(u8) {
    created = 0,
    starting = 1,
    running = 2,
    stopping = 3,
    stopped = 4,
    failed = 5,
};

// Actor行为接口 - 使用comptime实现零成本抽象
pub fn ActorBehavior(comptime Context: type) type {
    return struct {
        const Self = @This();

        // 必须实现的方法
        pub fn receive(context: *Context, message: *const FastMessage) !void {
            _ = context;
            _ = message;
            @compileError("ActorBehavior must implement receive method");
        }

        // 可选的生命周期方法
        pub fn preStart(context: *Context) !void {
            _ = context;
            // 默认空实现
        }

        pub fn postStop(context: *Context) !void {
            _ = context;
            // 默认空实现
        }

        pub fn onError(context: *Context, err: anyerror) !void {
            _ = context;
            // 默认重新抛出错误
            return err;
        }
    };
}

// 高性能Actor实现
pub fn Actor(comptime BehaviorType: type, comptime mailbox_capacity: u32) type {
    return struct {
        const Self = @This();
        const MailboxQueue = SPSCQueue(FastMessage, mailbox_capacity);

        // Actor核心数据
        id: ActorId,
        state: AtomicValue(ActorState),
        behavior: BehaviorType,

        // 消息处理
        mailbox: MailboxQueue,
        batch_processor: BatchProcessor,

        // 性能统计
        stats: PerformanceStats,

        // 内存管理
        allocator: Allocator,

        // 运行时数据
        last_activity: AtomicValue(i64),
        message_count: AtomicValue(u64),

        pub fn init(allocator: Allocator, id: ActorId, behavior: BehaviorType) !*Self {
            const actor = try allocator.create(Self);

            actor.* = Self{
                .id = id,
                .state = AtomicValue(ActorState).init(.created),
                .behavior = behavior,
                .mailbox = MailboxQueue.init(),
                .batch_processor = try BatchProcessor.init(allocator, 64),
                .stats = PerformanceStats{},
                .allocator = allocator,
                .last_activity = AtomicValue(i64).init(std.time.milliTimestamp()),
                .message_count = AtomicValue(u64).init(0),
            };

            return actor;
        }

        pub fn deinit(self: *Self) void {
            self.batch_processor.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn start(self: *Self) !void {
            const expected_state = ActorState.created;
            if (self.state.cmpxchgStrong(expected_state, .starting, .acq_rel, .monotonic)) |actual| {
                if (actual != .starting) {
                    return error.InvalidState;
                }
            }

            // 调用preStart钩子
            if (@hasDecl(BehaviorType, "preStart")) {
                try self.behavior.preStart();
            }

            self.state.store(.running, .release);
            self.updateActivity();
        }

        pub fn stop(self: *Self) !void {
            const current_state = self.state.load(.acquire);
            if (current_state == .stopped or current_state == .stopping) {
                return;
            }

            self.state.store(.stopping, .release);

            // 调用postStop钩子
            if (@hasDecl(BehaviorType, "postStop")) {
                try self.behavior.postStop();
            }

            self.state.store(.stopped, .release);
        }

        pub fn send(self: *Self, message: FastMessage) bool {
            if (self.state.load(.acquire) != .running) {
                return false;
            }

            if (self.mailbox.push(message)) {
                self.stats.recordMessageReceived();
                return true;
            }

            return false; // 邮箱满
        }

        // 高性能消息处理循环
        pub fn processMessages(self: *Self) !u32 {
            if (self.state.load(.acquire) != .running) {
                return 0;
            }

            var processed: u32 = 0;
            self.batch_processor.clear();

            // 批量收集消息
            while (processed < 64) { // 最大批量大小
                if (self.mailbox.pop()) |message| {
                    if (self.batch_processor.add(message)) {
                        processed += 1;
                    } else {
                        break; // 批处理器满
                    }
                } else {
                    break; // 没有更多消息
                }
            }

            if (processed == 0) {
                return 0;
            }

            // 批量处理消息
            const batch = self.batch_processor.getBatch();

            for (batch) |*message| {
                const msg_start = std.time.nanoTimestamp();

                // 调用行为处理方法
                if (@hasDecl(BehaviorType, "receive")) {
                    self.behavior.receive(message) catch |err| {
                        // 错误处理
                        if (@hasDecl(BehaviorType, "onError")) {
                            self.behavior.onError(err) catch {
                                self.state.store(.failed, .release);
                                return err;
                            };
                        } else {
                            self.state.store(.failed, .release);
                            return err;
                        }
                    };
                } else {
                    @compileError("BehaviorType must implement receive method");
                }

                const msg_latency = std.time.nanoTimestamp() - msg_start;
                self.stats.recordMessageProcessed(@intCast(msg_latency));
            }

            // 更新统计信息
            self.stats.recordBatch(processed);
            _ = self.message_count.fetchAdd(processed, .monotonic);
            self.updateActivity();

            return processed;
        }

        // 单消息处理（用于低延迟场景）
        pub fn processSingleMessage(self: *Self) !bool {
            if (self.state.load(.acquire) != .running) {
                return false;
            }

            if (self.mailbox.pop()) |message| {
                const start_time = std.time.nanoTimestamp();

                // 处理消息
                if (@hasDecl(BehaviorType, "receive")) {
                    self.behavior.receive(&message) catch |err| {
                        if (@hasDecl(BehaviorType, "onError")) {
                            self.behavior.onError(err) catch {
                                self.state.store(.failed, .release);
                                return err;
                            };
                        } else {
                            self.state.store(.failed, .release);
                            return err;
                        }
                    };
                }

                const latency = std.time.nanoTimestamp() - start_time;
                self.stats.recordMessageProcessed(@intCast(latency));
                _ = self.message_count.fetchAdd(1, .monotonic);
                self.updateActivity();

                return true;
            }

            return false;
        }

        pub fn getState(self: *const Self) ActorState {
            return self.state.load(.acquire);
        }

        pub fn isRunning(self: *const Self) bool {
            return self.getState() == .running;
        }

        pub fn getMessageCount(self: *const Self) u64 {
            return self.message_count.load(.monotonic);
        }

        pub fn getMailboxSize(self: *const Self) u32 {
            return self.mailbox.size();
        }

        pub fn getStats(self: *const Self) PerformanceStats {
            return self.stats;
        }

        pub fn getLastActivity(self: *const Self) i64 {
            return self.last_activity.load(.monotonic);
        }

        fn updateActivity(self: *Self) void {
            self.last_activity.store(std.time.milliTimestamp(), .monotonic);
        }

        // 调试信息
        pub fn getDebugInfo(self: *const Self) DebugInfo {
            return DebugInfo{
                .id = self.id,
                .state = self.getState(),
                .message_count = self.getMessageCount(),
                .mailbox_size = self.getMailboxSize(),
                .last_activity = self.getLastActivity(),
                .avg_latency = self.stats.getAverageLatency(),
            };
        }

        pub const DebugInfo = struct {
            id: ActorId,
            state: ActorState,
            message_count: u64,
            mailbox_size: u32,
            last_activity: i64,
            avg_latency: f64,

            pub fn print(self: *const DebugInfo) void {
                std.log.info("Actor Debug Info:", .{});
                std.log.info("  ID: {}", .{self.id.toU64()});
                std.log.info("  State: {}", .{self.state});
                std.log.info("  Messages: {}", .{self.message_count});
                std.log.info("  Mailbox size: {}", .{self.mailbox_size});
                std.log.info("  Last activity: {}", .{self.last_activity});
                std.log.info("  Avg latency: {d:.2} ns", .{self.avg_latency});
            }
        };
    };
}

// 示例Actor行为实现
pub const CounterBehavior = struct {
    count: u64 = 0,
    name: []const u8,

    pub fn init(name: []const u8) CounterBehavior {
        return CounterBehavior{
            .name = name,
        };
    }

    pub fn receive(self: *CounterBehavior, message: *const FastMessage) !void {
        switch (message.msg_type) {
            .user => {
                const data = message.getData();
                if (std.mem.eql(u8, data, "increment")) {
                    self.count += 1;
                    std.log.debug("Counter '{s}' incremented to {}", .{ self.name, self.count });
                } else if (std.mem.eql(u8, data, "get")) {
                    std.log.info("Counter '{s}' value: {}", .{ self.name, self.count });
                }
            },
            .system => {
                std.log.debug("Counter '{s}' received system message", .{self.name});
            },
            else => {
                std.log.warn("Counter '{s}' received unknown message type", .{self.name});
            },
        }
    }

    pub fn preStart(self: *CounterBehavior) !void {
        std.log.info("Counter '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *CounterBehavior) !void {
        std.log.info("Counter '{s}' stopped with final count: {}", .{ self.name, self.count });
    }
};

// 类型别名
pub const CounterActor = Actor(CounterBehavior, 1024);

// 测试
test "Actor creation and lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const behavior = CounterBehavior.init("test-counter");
    const id = ActorId.init(0, 0, 1);

    var actor = try CounterActor.init(allocator, id, behavior);
    defer actor.deinit();

    // 测试初始状态
    try testing.expect(actor.getState() == .created);
    try testing.expect(actor.getMessageCount() == 0);

    // 测试启动
    try actor.start();
    try testing.expect(actor.getState() == .running);
    try testing.expect(actor.isRunning());

    // 测试停止
    try actor.stop();
    try testing.expect(actor.getState() == .stopped);
    try testing.expect(!actor.isRunning());
}

test "Actor message processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const behavior = CounterBehavior.init("test-counter");
    const id = ActorId.init(0, 0, 1);

    var actor = try CounterActor.init(allocator, id, behavior);
    defer actor.deinit();

    try actor.start();

    // 发送消息
    var message = FastMessage.init(ActorId.init(0, 0, 2), id, .user);
    message.setData("increment");

    try testing.expect(actor.send(message));

    // 处理消息
    const processed = try actor.processMessages();
    try testing.expect(processed == 1);
    try testing.expect(actor.getMessageCount() == 1);
}
