//! ActorContext Implementation - Actor上下文实现
//! 提供Actor运行时上下文和环境管理

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;

// 导入相关模块
const Actor = @import("actor.zig").Actor;
const ActorRef = @import("actor_ref.zig").ActorRef;
const LocalActorRef = @import("actor_ref.zig").LocalActorRef;
const Message = @import("../message/mod.zig").Message;
const ActorPath = @import("mod.zig").ActorPath;
const ActorError = @import("mod.zig").ActorError;
const ActorConfig = @import("mod.zig").ActorConfig;
const ActorStats = @import("mod.zig").ActorStats;

// Actor上下文
pub const ActorContext = struct {
    const Self = @This();
    
    // 核心属性
    self_ref: *ActorRef,
    sender: ?*ActorRef,
    parent: ?*ActorRef,
    children: ArrayList(*ActorRef),
    system: *ActorSystem,
    allocator: Allocator,
    
    // 配置和状态
    config: ActorConfig,
    stats: ActorStats,
    
    // 监控和调试
    watchers: ArrayList(*ActorRef),
    stash: ArrayList(*Message),
    
    // 同步原语
    mutex: std.Thread.Mutex,
    
    pub fn init(
        self_ref: *ActorRef,
        parent: ?*ActorRef,
        system: *ActorSystem,
        config: ActorConfig,
        allocator: Allocator,
    ) !Self {
        return Self{
            .self_ref = self_ref,
            .sender = null,
            .parent = parent,
            .children = ArrayList(*ActorRef).init(allocator),
            .system = system,
            .allocator = allocator,
            .config = config,
            .stats = ActorStats.init(),
            .watchers = ArrayList(*ActorRef).init(allocator),
            .stash = ArrayList(*Message).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 清理子Actor
        for (self.children.items) |child| {
            child.tell(.stop, self.self_ref) catch {};
        }
        self.children.deinit();
        
        // 清理监控者
        self.watchers.deinit();
        
        // 清理暂存消息
        for (self.stash.items) |msg| {
            msg.deinit();
        }
        self.stash.deinit();
    }
    
    // Actor引用管理
    pub fn getSelf(self: *Self) *ActorRef {
        return self.self_ref;
    }
    
    pub fn getSender(self: *Self) ?*ActorRef {
        return self.sender;
    }
    
    pub fn setSender(self: *Self, sender: ?*ActorRef) void {
        self.sender = sender;
    }
    
    pub fn getParent(self: *Self) ?*ActorRef {
        return self.parent;
    }
    
    pub fn getSystem(self: *Self) *ActorSystem {
        return self.system;
    }
    
    // 子Actor管理
    pub fn actorOf(self: *Self, props: ActorProps, name: ?[]const u8) !*ActorRef {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 生成子Actor路径
        const child_name = name orelse try generateChildName(self.allocator);
        const child_path = try self.self_ref.getPath().child(child_name, self.allocator);
        
        // 创建子Actor
        const child_actor = try self.system.createActor(props, child_path, self.self_ref);
        const child_ref = try LocalActorRef.init(child_actor, child_path, self.allocator);
        
        // 添加到子Actor列表
        try self.children.append(child_ref.getActorRef());
        
        // 更新统计信息
        self.stats.children_created += 1;
        
        return child_ref.getActorRef();
    }
    
    pub fn stop(self: *Self, child: *ActorRef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 查找并移除子Actor
        for (self.children.items, 0..) |c, i| {
            if (c.equals(child)) {
                _ = self.children.swapRemove(i);
                try child.tell(.stop, self.self_ref);
                self.stats.children_stopped += 1;
                break;
            }
        }
    }
    
    pub fn getChildren(self: *Self) []const *ActorRef {
        return self.children.items;
    }
    
    // 消息处理
    pub fn become(self: *Self, behavior: ActorBehavior) !void {
        // 切换Actor行为
        if (self.self_ref.isLocal()) {
            const local_ref = @fieldParentPtr(LocalActorRef, "actor_ref", self.self_ref);
            try local_ref.actor.setBehavior(behavior);
        }
    }
    
    pub fn unbecome(self: *Self) !void {
        // 恢复之前的行为
        if (self.self_ref.isLocal()) {
            const local_ref = @fieldParentPtr(LocalActorRef, "actor_ref", self.self_ref);
            try local_ref.actor.revertBehavior();
        }
    }
    
    // 消息暂存
    pub fn stash(self: *Self, message: *Message) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.stash.append(message);
        self.stats.messages_stashed += 1;
    }
    
    pub fn unstashAll(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 将所有暂存消息重新发送给自己
        for (self.stash.items) |msg| {
            try self.self_ref.tell(msg, self.sender);
        }
        
        self.stats.messages_unstashed += self.stash.items.len;
        self.stash.clearAndFree();
    }
    
    pub fn unstash(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.stash.items.len > 0) {
            const msg = self.stash.orderedRemove(0);
            try self.self_ref.tell(msg, self.sender);
            self.stats.messages_unstashed += 1;
        }
    }
    
    // 监控管理
    pub fn watch(self: *Self, actor: *ActorRef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 添加到监控列表
        try self.watchers.append(actor);
        
        // 注册监控关系
        try self.system.registerWatch(self.self_ref, actor);
        
        self.stats.actors_watched += 1;
    }
    
    pub fn unwatch(self: *Self, actor: *ActorRef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 从监控列表移除
        for (self.watchers.items, 0..) |w, i| {
            if (w.equals(actor)) {
                _ = self.watchers.swapRemove(i);
                break;
            }
        }
        
        // 取消监控关系
        try self.system.unregisterWatch(self.self_ref, actor);
        
        self.stats.actors_unwatched += 1;
    }
    
    // Actor查找
    pub fn actorSelection(self: *Self, path: []const u8) !*ActorSelection {
        return self.system.actorSelection(path);
    }
    
    // 调度器访问
    pub fn getScheduler(self: *Self) *Scheduler {
        return self.system.getScheduler();
    }
    
    // 配置访问
    pub fn getConfig(self: *Self) ActorConfig {
        return self.config;
    }
    
    pub fn updateConfig(self: *Self, new_config: ActorConfig) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.config = new_config;
    }
    
    // 统计信息
    pub fn getStats(self: *Self) ActorStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.stats;
    }
    
    pub fn updateStats(self: *Self, update_fn: fn (*ActorStats) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        update_fn(&self.stats);
    }
    
    // 生命周期事件
    pub fn preStart(self: *Self) !void {
        // Actor启动前的初始化
        self.stats.start_time = std.time.milliTimestamp();
        self.stats.restart_count = 0;
    }
    
    pub fn postStop(self: *Self) !void {
        // Actor停止后的清理
        self.stats.stop_time = std.time.milliTimestamp();
        
        // 通知监控者
        for (self.watchers.items) |watcher| {
            const terminated_msg = TerminatedMessage{
                .actor = self.self_ref,
                .address_terminated = true,
                .existing_watcher = true,
            };
            watcher.tell(terminated_msg, null) catch {};
        }
    }
    
    pub fn preRestart(self: *Self, reason: anyerror, message: ?*Message) !void {
        _ = reason;
        _ = message;
        
        // 重启前的清理
        self.stats.restart_count += 1;
        self.stats.last_restart_time = std.time.milliTimestamp();
        
        // 停止所有子Actor
        for (self.children.items) |child| {
            child.tell(.stop, self.self_ref) catch {};
        }
    }
    
    pub fn postRestart(self: *Self, reason: anyerror) !void {
        _ = reason;
        
        // 重启后的初始化
        try self.preStart();
    }
};

// Actor属性配置
pub const ActorProps = struct {
    behavior_factory: *const fn (context: *ActorContext) anyerror!ActorBehavior,
    config: ActorConfig,
    dispatcher: ?[]const u8 = null,
    mailbox_type: ?[]const u8 = null,
    
    pub fn create(behavior_factory: *const fn (context: *ActorContext) anyerror!ActorBehavior) ActorProps {
        return ActorProps{
            .behavior_factory = behavior_factory,
            .config = ActorConfig.default(),
        };
    }
    
    pub fn withConfig(self: ActorProps, config: ActorConfig) ActorProps {
        var props = self;
        props.config = config;
        return props;
    }
    
    pub fn withDispatcher(self: ActorProps, dispatcher: []const u8) ActorProps {
        var props = self;
        props.dispatcher = dispatcher;
        return props;
    }
    
    pub fn withMailbox(self: ActorProps, mailbox_type: []const u8) ActorProps {
        var props = self;
        props.mailbox_type = mailbox_type;
        return props;
    }
};

// 终止消息
pub const TerminatedMessage = struct {
    actor: *ActorRef,
    address_terminated: bool,
    existing_watcher: bool,
};

// 前向声明
const ActorSystem = @import("../system/mod.zig").ActorSystem;
const ActorSelection = @import("mod.zig").ActorSelection;
const ActorBehavior = @import("actor.zig").ActorBehavior;
const Scheduler = @import("../scheduler/mod.zig").Scheduler;

// 辅助函数
fn generateChildName(allocator: Allocator) ![]const u8 {
    const timestamp = std.time.nanoTimestamp();
    return std.fmt.allocPrint(allocator, "child-{d}", .{timestamp});
}

// 测试
test "ActorContext creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // 需要实际的ActorRef和ActorSystem来测试
    // 暂时跳过，等待相关模块完成
}

test "ActorProps" {
    const testing = std.testing;
    
    const TestBehavior = struct {
        fn create(context: *ActorContext) !ActorBehavior {
            _ = context;
            return error.NotImplemented;
        }
    };
    
    const props = ActorProps.create(TestBehavior.create)
        .withDispatcher("test-dispatcher")
        .withMailbox("test-mailbox");
    
    try testing.expect(props.dispatcher != null);
    try testing.expect(props.mailbox_type != null);
    try testing.expectEqualStrings("test-dispatcher", props.dispatcher.?);
    try testing.expectEqualStrings("test-mailbox", props.mailbox_type.?);
}

test "TerminatedMessage" {
    const testing = std.testing;
    
    // 需要实际的ActorRef来测试
    // 暂时跳过，等待ActorRef模块完成
}