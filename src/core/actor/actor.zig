//! Actor Implementation - Actor实现
//! 提供基础的Actor功能和生命周期管理

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic.Atomic;

// 导入相关模块
const Message = @import("../message/mod.zig").Message;
const Mailbox = @import("../mailbox/mod.zig").MailboxInterface;
const ActorError = @import("mod.zig").ActorError;
const ActorStatus = @import("mod.zig").ActorStatus;
const ActorConfig = @import("mod.zig").ActorConfig;
const ActorStats = @import("mod.zig").ActorStats;

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
    
    pub fn self(self: *Self) *Actor {
        return self.actor;
    }
    
    pub fn getSender(self: *Self) ?*Actor {
        return self.sender;
    }
    
    pub fn getCurrentMessage(self: *Self) ?*Message {
        return self.message;
    }
    
    pub fn tell(self: *Self, target: *Actor, message: anytype) !void {
        const msg = try Message.create(self.allocator, message);
        try target.send(msg, self.actor);
    }
    
    pub fn reply(self: *Self, message: anytype) !void {
        if (self.sender) |sender| {
            try self.tell(sender, message);
        }
    }
    
    pub fn become(self: *Self, behavior: ActorBehavior) void {
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
        restart,
        resume,
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
        return .restart;
    }
};

// Actor实现
pub const Actor = struct {
    const Self = @This();
    
    // Actor状态
    status: Atomic(ActorStatus),
    behavior: ?*ActorBehavior,
    context: ActorContext,
    mailbox: *Mailbox,
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
    
    pub fn init(allocator: Allocator, config: ActorConfig, mailbox: *Mailbox) !*Self {
        const actor = try allocator.create(Self);
        const now = std.time.milliTimestamp();
        
        actor.* = Self{
            .status = Atomic(ActorStatus).init(.created),
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
        self.allocator.destroy(self);
    }
    
    pub fn setBehavior(self: *Self, behavior: *ActorBehavior) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.behavior = behavior;
    }
    
    pub fn start(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const current_status = self.status.load(.Acquire);
        if (current_status != .created and current_status != .stopped) {
            return ActorError.InvalidActorState;
        }
        
        self.status.store(.starting, .Release);
        self.started_at = std.time.milliTimestamp();
        
        // 调用preStart钩子
        if (self.behavior) |behavior| {
            behavior.preStart(&self.context) catch |err| {
                self.status.store(.failed, .Release);
                return err;
            };
        }
        
        self.status.store(.running, .Release);
        self.condition.broadcast();
    }
    
    pub fn stop(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const current_status = self.status.load(.Acquire);
        if (current_status == .stopped or current_status == .stopping) {
            return;
        }
        
        self.status.store(.stopping, .Release);
        
        // 调用postStop钩子
        if (self.behavior) |behavior| {
            behavior.postStop(&self.context) catch {};
        }
        
        self.status.store(.stopped, .Release);
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
        
        self.status.store(.restarting, .Release);
        
        // 调用preRestart钩子
        if (self.behavior) |behavior| {
            behavior.preRestart(&self.context, reason) catch {};
        }
        
        // 清空邮箱
        self.mailbox.clear();
        
        // 重置统计信息
        self.stats.reset();
        
        // 调用postRestart钩子
        if (self.behavior) |behavior| {
            behavior.postRestart(&self.context, reason) catch {};
        }
        
        self.restart_count += 1;
        self.last_restart_time = now;
        self.stats.recordRestart();
        
        self.status.store(.running, .Release);
        self.condition.broadcast();
    }
    
    pub fn send(self: *Self, message: *Message, sender: ?*Actor) !void {
        const current_status = self.status.load(.Acquire);
        if (current_status != .running and current_status != .starting) {
            return ActorError.ActorTerminated;
        }
        
        // 设置发送者信息
        if (sender) |s| {
            message.setSender(s);
        }
        
        // 发送到邮箱
        if (!self.mailbox.send(message)) {
            self.stats.recordFailure();
            return ActorError.MessageDeliveryFailed;
        }
        
        self.stats.recordMessage(0); // 处理时间将在实际处理时更新
    }
    
    pub fn receive(self: *Self) !?*Message {
        return self.mailbox.receive();
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
                    .restart => try self.restart(err),
                    .resume => {}, // 继续处理
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
    
    pub fn getStatus(self: *const Self) ActorStatus {
        return self.status.load(.Acquire);
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
        
        while (self.status.load(.Acquire) != target_status) {
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
            .mailbox_size = self.mailbox.size(),
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

// 测试
test "Actor lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // 这里需要实际的Mailbox实现来进行测试
    // 暂时跳过，等待Mailbox模块完成
}

test "Actor behavior" {
    const testing = std.testing;
    
    var default_behavior = DefaultBehavior.init();
    try testing.expect(default_behavior.behavior.supervisorStrategy() == .restart);
}

test "ActorContext" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // 创建一个模拟的Actor用于测试
    // 暂时跳过，等待完整的Actor系统实现
}