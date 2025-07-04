//! Actor Implementation - Actor实现
//! 提供基础的Actor功能和生命周期管理

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const AtomicValue = std.atomic.Value;

// 导入相关模块
const Message = @import("../message/mod.zig").Message;
const MailboxInterface = @import("../mailbox/mod.zig").MailboxInterface;
const StandardMailbox = @import("../mailbox/standard.zig").StandardMailbox;
const ActorError = @import("mod.zig").ActorError;
const ActorStatus = @import("mod.zig").ActorStatus;
const ActorConfig = @import("mod.zig").ActorConfig;
const ActorStats = @import("mod.zig").ActorStats;
const Task = @import("../scheduler/mod.zig").Task;
const TaskPriority = @import("../scheduler/mod.zig").TaskPriority;

// Actor上下文
pub const ActorContext = struct {
    const Self = @This();

    actor: *Actor,
    sender: ?*Actor = null,
    message: ?*Message = null,
    allocator: Allocator,

    pub fn init(actor: *Actor, allocator: Allocator) ActorContext {
        return ActorContext{
            .actor = actor,
            .allocator = allocator,
        };
    }

    pub fn getActor(self: *Self) *Actor {
        return self.actor;
    }

    pub fn getSender(self: *Self) ?*Actor {
        return self.sender;
    }

    pub fn getCurrentMessage(self: *Self) ?*Message {
        return self.message;
    }

    pub fn tell(self: *Self, target: *Actor, message: *Message) !void {
        try target.send(message, self.actor);
    }

    pub fn reply(self: *Self, message: *Message) !void {
        if (self.sender) |sender| {
            try self.tell(sender, message);
        }
    }

    // 便捷方法：创建并发送用户消息
    pub fn sendUser(self: *Self, target: *Actor, comptime T: type, data: T) !void {
        const msg = try Message.createUser(self.allocator, data);
        try self.tell(target, msg);
    }

    // 便捷方法：回复用户消息
    pub fn replyUser(self: *Self, comptime T: type, data: T) !void {
        const msg = try Message.createUser(self.allocator, data);
        try self.reply(msg);
    }

    pub fn become(self: *Self, behavior: *ActorBehavior) void {
        self.actor.setBehavior(behavior);
    }

    pub fn stop(self: *Self) void {
        self.actor.stop();
    }

    pub fn getStats(self: *Self) ActorStats {
        return self.actor.getStats();
    }
};

// Actor行为接口
pub const ActorBehavior = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        receive: *const fn (self: *ActorBehavior, context: *ActorContext, message: *Message) anyerror!void,
        preStart: *const fn (self: *ActorBehavior, context: *ActorContext) anyerror!void,
        postStop: *const fn (self: *ActorBehavior, context: *ActorContext) anyerror!void,
        preRestart: *const fn (self: *ActorBehavior, context: *ActorContext, reason: anyerror) anyerror!void,
        postRestart: *const fn (self: *ActorBehavior, context: *ActorContext, reason: anyerror) anyerror!void,
        supervisorStrategy: *const fn (self: *ActorBehavior) SupervisionStrategy,
    };

    pub const SupervisionStrategy = enum {
        stop,
        restart_actor,
        resume_actor,
        escalate,
    };

    pub fn receive(self: *ActorBehavior, context: *ActorContext, message: *Message) !void {
        try self.vtable.receive(self, context, message);
    }

    pub fn preStart(self: *ActorBehavior, context: *ActorContext) !void {
        try self.vtable.preStart(self, context);
    }

    pub fn postStop(self: *ActorBehavior, context: *ActorContext) !void {
        try self.vtable.postStop(self, context);
    }

    pub fn preRestart(self: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        try self.vtable.preRestart(self, context, reason);
    }

    pub fn postRestart(self: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        try self.vtable.postRestart(self, context, reason);
    }

    pub fn supervisorStrategy(self: *ActorBehavior) SupervisionStrategy {
        return self.vtable.supervisorStrategy(self);
    }
};

// 默认Actor行为实现
pub const DefaultBehavior = struct {
    const Self = @This();

    behavior: ActorBehavior,

    const vtable = ActorBehavior.VTable{
        .receive = receive,
        .preStart = preStart,
        .postStop = postStop,
        .preRestart = preRestart,
        .postRestart = postRestart,
        .supervisorStrategy = supervisorStrategy,
    };

    pub fn init() Self {
        return Self{
            .behavior = ActorBehavior{
                .vtable = &vtable,
            },
        };
    }

    fn receive(behavior: *ActorBehavior, context: *ActorContext, message: *Message) !void {
        _ = behavior;
        _ = context;
        _ = message;
        // 默认实现：忽略所有消息
    }

    fn preStart(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
        // 默认实现：什么都不做
    }

    fn postStop(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
        // 默认实现：什么都不做
    }

    fn preRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        _ = reason;
        // 默认实现：什么都不做
    }

    fn postRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        _ = reason;
        // 默认实现：什么都不做
    }

    fn supervisorStrategy(behavior: *ActorBehavior) ActorBehavior.SupervisionStrategy {
        _ = behavior;
        return .restart_actor;
    }
};

// Actor实现
pub const Actor = struct {
    const Self = @This();

    // Actor标识
    id: u64,

    // Actor状态
    status: AtomicValue(ActorStatus),
    behavior: ?*ActorBehavior,
    context: ActorContext,
    mailbox: *MailboxInterface,
    config: ActorConfig,
    stats: ActorStats,

    // 生命周期管理
    created_at: i64,
    started_at: i64,
    stopped_at: i64,
    restart_count: u32,
    last_restart_time: i64,

    // 同步原语
    mutex: Thread.Mutex,
    condition: Thread.Condition,

    // 内存管理
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: ActorConfig, mailbox: *MailboxInterface) !*Self {
        const actor = try allocator.create(Self);
        const now = std.time.milliTimestamp();

        actor.* = Self{
            .id = generateActorId(),
            .status = AtomicValue(ActorStatus).init(.created),
            .behavior = null,
            .context = undefined, // 将在下面初始化
            .mailbox = mailbox,
            .config = config,
            .stats = ActorStats{},
            .created_at = now,
            .started_at = 0,
            .stopped_at = 0,
            .restart_count = 0,
            .last_restart_time = 0,
            .mutex = Thread.Mutex{},
            .condition = Thread.Condition{},
            .allocator = allocator,
        };

        actor.context = ActorContext.init(actor, allocator);
        return actor;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // 释放behavior
        if (self.behavior) |behavior| {
            self.allocator.destroy(behavior);
        }

        // 释放邮箱 - 先释放底层mailbox，再释放interface
        const standard_mailbox: *StandardMailbox = @ptrCast(@alignCast(self.mailbox.ptr));
        standard_mailbox.deinitImpl();
        self.allocator.destroy(standard_mailbox);
        self.allocator.destroy(self.mailbox);

        // 注意：不要在这里释放Actor本身，应该由创建者负责释放
    }

    pub fn setBehavior(self: *Self, behavior: *ActorBehavior) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.behavior = behavior;
    }

    pub fn start(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_status = self.status.load(.acquire);
        if (current_status != .created and current_status != .stopped) {
            return ActorError.InvalidActorState;
        }

        self.status.store(.starting, .release);
        self.started_at = std.time.milliTimestamp();

        // 调用preStart钩子
        if (self.behavior) |behavior| {
            behavior.preStart(&self.context) catch |err| {
                self.status.store(.failed, .release);
                return err;
            };
        }

        self.status.store(.running, .release);
        self.condition.broadcast();
    }

    pub fn stop(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_status = self.status.load(.acquire);
        if (current_status == .stopped or current_status == .stopping) {
            return;
        }

        self.status.store(.stopping, .release);

        // 调用postStop钩子
        if (self.behavior) |behavior| {
            behavior.postStop(&self.context) catch {};
        }

        self.status.store(.stopped, .release);
        self.stopped_at = std.time.milliTimestamp();
        self.condition.broadcast();
    }

    pub fn restart(self: *Self, reason: anyerror) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();

        // 检查重启限制
        if (self.restart_count >= self.config.max_restarts) {
            const window_elapsed = now - self.last_restart_time;
            if (window_elapsed < self.config.restart_window_ms) {
                return ActorError.SupervisionFailed;
            }
            // 重置重启计数器
            self.restart_count = 0;
        }

        self.status.store(.restarting, .release);

        // 调用preRestart钩子
        if (self.behavior) |behavior| {
            behavior.preRestart(&self.context, reason) catch {};
        }

        // 清空邮箱
        self.mailbox.*.clear();

        // 重置统计信息
        self.stats.reset();

        // 调用postRestart钩子
        if (self.behavior) |behavior| {
            behavior.postRestart(&self.context, reason) catch {};
        }

        self.restart_count += 1;
        self.last_restart_time = now;
        self.stats.recordRestart();

        self.status.store(.running, .release);
        self.condition.broadcast();
    }

    pub fn send(self: *Self, message: *Message, sender: ?*Actor) !void {
        const current_status = self.status.load(.acquire);
        if (current_status != .running and current_status != .starting and current_status != .created) {
            return ActorError.ActorTerminated;
        }

        // 设置发送者信息
        if (sender) |s| {
            message.setSender(s.id);
        }

        // 发送到邮箱
        self.mailbox.*.send(message.*) catch {
            self.stats.recordFailure();
            return ActorError.MessageDeliveryFailed;
        };

        self.stats.recordMessage(0); // 处理时间将在实际处理时更新
    }

    pub fn receive(self: *Self) !?*Message {
        return self.mailbox.*.receive();
    }

    pub fn processMessage(self: *Self, message: *Message) !void {
        const start_time = std.time.nanoTimestamp();

        // 设置上下文
        self.context.message = message;
        if (message.getSender()) |sender| {
            self.context.sender = sender;
        }

        // 处理消息
        if (self.behavior) |behavior| {
            behavior.receive(&self.context, message) catch |err| {
                self.stats.recordFailure();

                // 根据监督策略处理错误
                const strategy = behavior.supervisorStrategy();
                switch (strategy) {
                    .stop => self.stop(),
                    .restart_actor => try self.restart(err),
                    .resume_actor => {}, // 继续处理
                    .escalate => return err,
                }
                return;
            };
        }

        // 更新统计信息
        const processing_time = std.time.nanoTimestamp() - start_time;
        self.stats.recordMessage(@intCast(processing_time));

        // 清理上下文
        self.context.message = null;
        self.context.sender = null;
    }

    /// 创建消息处理任务
    pub fn createMessageProcessingTask(self: *Self, allocator: Allocator) !*Task {
        const task_impl = try allocator.create(MessageProcessingTask);
        task_impl.* = MessageProcessingTask{
            .task = Task.init(&MessageProcessingTask.vtable, .normal),
            .actor = self,
            .allocator = allocator,
        };
        return &task_impl.task;
    }

    /// 消息处理任务实现
    const MessageProcessingTask = struct {
        const TaskSelf = @This();

        task: Task,
        actor: *Actor,
        allocator: Allocator,

        const vtable = Task.VTable{
            .execute = execute,
            .deinit = deinitTask,
            .getName = getName,
        };

        fn execute(task: *Task) !void {
            const self = @as(*TaskSelf, @fieldParentPtr("task", task));

            // 处理一批消息（避免单个任务处理时间过长）
            var processed: u32 = 0;
            const max_batch_size = 10;

            while (processed < max_batch_size and self.actor.isRunning()) {
                if (self.actor.mailbox.*.receive()) |message| {
                    var msg = message;
                    self.actor.processMessage(&msg) catch |err| {
                        std.log.warn("Actor {} message processing failed: {}", .{ self.actor.id, err });
                    };
                    processed += 1;
                } else {
                    // 没有更多消息，退出
                    break;
                }
            }
        }

        fn deinitTask(task: *Task) void {
            const self = @as(*TaskSelf, @fieldParentPtr("task", task));
            self.allocator.destroy(self);
        }

        fn getName(task: *Task) []const u8 {
            _ = task;
            return "ActorMessageProcessing";
        }
    };

    pub fn getStatus(self: *const Self) ActorStatus {
        return self.status.load(.acquire);
    }

    pub fn isRunning(self: *const Self) bool {
        return self.getStatus() == .running;
    }

    pub fn isStopped(self: *const Self) bool {
        const status = self.getStatus();
        return status == .stopped or status == .failed;
    }

    pub fn getStats(self: *const Self) ActorStats {
        return self.stats;
    }

    pub fn getUptime(self: *const Self) i64 {
        if (self.started_at == 0) return 0;

        const end_time = if (self.stopped_at != 0) self.stopped_at else std.time.milliTimestamp();
        return end_time - self.started_at;
    }

    pub fn waitForStatus(self: *Self, target_status: ActorStatus, timeout_ms: u64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

        while (self.status.load(.acquire) != target_status) {
            const now = std.time.milliTimestamp();
            if (now >= deadline) {
                return false; // 超时
            }

            const remaining_ms = @as(u64, @intCast(deadline - now));
            self.condition.timedWait(&self.mutex, remaining_ms * std.time.ns_per_ms) catch {
                return false; // 超时或错误
            };
        }

        return true;
    }

    // 调试和监控方法
    pub fn getDebugInfo(self: *const Self) DebugInfo {
        return DebugInfo{
            .status = self.getStatus(),
            .uptime_ms = self.getUptime(),
            .restart_count = self.restart_count,
            .mailbox_size = self.mailbox.*.size(),
            .stats = self.stats,
        };
    }

    pub const DebugInfo = struct {
        status: ActorStatus,
        uptime_ms: i64,
        restart_count: u32,
        mailbox_size: u32,
        stats: ActorStats,

        pub fn format(self: DebugInfo, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;

            try writer.print(
                "Actor{{ status: {}, uptime: {}ms, restarts: {}, mailbox: {}, " ++
                    "messages: {}/{}, avg_time: {}ns }}",
                .{
                    self.status,
                    self.uptime_ms,
                    self.restart_count,
                    self.mailbox_size,
                    self.stats.messages_processed,
                    self.stats.messages_failed,
                    self.stats.processing_time_avg_ns,
                },
            );
        }
    };
};

// Actor ID 生成器
var actor_id_counter = std.atomic.Value(u64).init(0);

fn generateActorId() u64 {
    return actor_id_counter.fetchAdd(1, .monotonic);
}

// 测试
test "Actor creation" {
    const testing = std.testing;
    _ = testing;

    // 这里需要实际的Mailbox实现来进行测试
    // 暂时跳过，等待Mailbox模块完成
}

test "Actor behavior" {
    const testing = std.testing;

    var default_behavior = DefaultBehavior.init();
    try testing.expect(default_behavior.behavior.supervisorStrategy() == .restart_actor);
}

test "ActorContext" {
    const testing = std.testing;
    _ = testing;

    // 创建一个模拟的Actor用于测试
    // 暂时跳过，等待完整的Actor系统实现
}
