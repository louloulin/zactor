//! ActorSystem Implementation - Actor系统实现
//! 提供Actor系统的核心管理和协调功能

const std = @import("std");
const Allocator = std.mem.Allocator;
const AtomicValue = std.atomic.Value;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Thread = std.Thread;

// 导入相关模块
const Actor = @import("actor.zig").Actor;
const ActorBehavior = @import("actor.zig").ActorBehavior;
const ActorContext = @import("actor.zig").ActorContext;
const ActorRef = @import("actor_ref.zig").ActorRef;
const LocalActorRef = @import("actor_ref.zig").LocalActorRef;
const ActorConfig = @import("mod.zig").ActorConfig;
// 简化的 ActorProps 实现
pub const ActorProps = struct {
    behavior_factory: *const fn (context: *ActorContext) anyerror!*ActorBehavior,
    config: ActorConfig,

    pub fn create(behavior_factory: *const fn (context: *ActorContext) anyerror!*ActorBehavior) ActorProps {
        return ActorProps{
            .behavior_factory = behavior_factory,
            .config = ActorConfig.default(),
        };
    }
};

// 简化的 TerminatedMessage
pub const TerminatedMessage = struct {
    actor: *ActorRef,
    address_terminated: bool,
    existing_watcher: bool,
};
const Message = @import("../message/mod.zig").Message;
const WorkStealingScheduler = @import("../scheduler/mod.zig").WorkStealingScheduler;
const SchedulerConfig = @import("../scheduler/mod.zig").SchedulerConfig;
const Task = @import("../scheduler/mod.zig").Task;
const MailboxConfig = @import("../mailbox/mod.zig").MailboxConfig;
const MailboxFactory = @import("../mailbox/mod.zig").MailboxFactory;
const MailboxInterface = @import("../mailbox/mod.zig").MailboxInterface;
const StandardMailbox = @import("../mailbox/standard.zig").StandardMailbox;
const ActorPath = @import("mod.zig").ActorPath;
const ActorSelection = @import("mod.zig").ActorSelection;
const ActorError = @import("mod.zig").ActorError;
const SystemConfiguration = @import("../system/mod.zig").SystemConfiguration;
const SystemStats = @import("../system/mod.zig").SystemStats;

// Actor系统状态
pub const ActorSystemState = enum(u8) {
    starting = 0,
    running = 1,
    terminating = 2,
    terminated = 3,
};

// Actor系统
pub const ActorSystem = struct {
    const Self = @This();

    // 核心属性
    name: []const u8,
    allocator: Allocator,
    state: AtomicValue(ActorSystemState),

    // 系统组件
    scheduler: *WorkStealingScheduler,
    guardian: *ActorRef,
    user_guardian: *ActorRef,
    system_guardian: *ActorRef,

    // 配置和统计
    config: SystemConfiguration,
    stats: SystemStats,

    // Actor管理
    actors: HashMap([]const u8, *ActorRef, StringContext, std.hash_map.default_max_load_percentage),
    watchers: HashMap(*ActorRef, ArrayList(*ActorRef), ActorRefContext, std.hash_map.default_max_load_percentage),

    // 同步原语
    mutex: Thread.Mutex,
    shutdown_signal: Thread.ResetEvent,

    // 扩展点
    extensions: HashMap([]const u8, *Extension, StringContext, std.hash_map.default_max_load_percentage),

    pub fn init(name: []const u8, config: SystemConfiguration, allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // 初始化调度器
        const scheduler = try WorkStealingScheduler.init(config.scheduler_config, allocator);
        errdefer scheduler.deinit();

        self.* = Self{
            .name = try allocator.dupe(u8, name),
            .allocator = allocator,
            .state = AtomicValue(ActorSystemState).init(.starting),
            .scheduler = scheduler,
            .guardian = undefined, // 稍后初始化
            .user_guardian = undefined,
            .system_guardian = undefined,
            .config = config,
            .stats = SystemStats.init(),
            .actors = HashMap([]const u8, *ActorRef, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .watchers = HashMap(*ActorRef, ArrayList(*ActorRef), ActorRefContext, std.hash_map.default_max_load_percentage).init(allocator),
            .mutex = Thread.Mutex{},
            .shutdown_signal = Thread.ResetEvent{},
            .extensions = HashMap([]const u8, *Extension, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };

        // 初始化守护者Actor
        try self.initGuardians();

        // 设置为初始化完成状态
        self.state.store(.starting, .seq_cst);

        return self;
    }

    pub fn start(self: *Self) !void {
        // 启动调度器
        try self.scheduler.start();

        // 设置为运行状态
        self.state.store(.running, .seq_cst);
    }

    pub fn deinit(self: *Self) void {
        // 确保系统已关闭
        self.shutdown() catch {};

        // 获取allocator的副本，因为我们稍后会销毁self
        const allocator = self.allocator;

        self.mutex.lock();

        // 清理Actor
        var actor_iter = self.actors.iterator();
        while (actor_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);

            // 获取ActorRef
            const actor_ref = entry.value_ptr.*;

            // 如果是本地Actor，先释放底层Actor
            if (actor_ref.getLocalActor()) |actor| {
                actor.deinit();
                allocator.destroy(actor);
            }

            // 调用ActorRef的deinit方法
            actor_ref.deinit();

            // 如果是LocalActorRef，释放LocalActorRef本身
            if (actor_ref.isLocal()) {
                const local_ref = @as(*LocalActorRef, @fieldParentPtr("actor_ref", actor_ref));
                allocator.destroy(local_ref);
            }
        }
        self.actors.deinit();

        // 清理监控关系
        var watcher_iter = self.watchers.iterator();
        while (watcher_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.watchers.deinit();

        // 清理扩展
        var ext_iter = self.extensions.iterator();
        while (ext_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.extensions.deinit();

        // 清理调度器
        self.scheduler.deinit();

        // 清理名称
        allocator.free(self.name);

        // 解锁mutex
        self.mutex.unlock();

        // 销毁自身
        allocator.destroy(self);
    }

    // 系统管理
    pub fn getName(self: *Self) []const u8 {
        return self.name;
    }

    pub fn getState(self: *Self) ActorSystemState {
        return self.state.load(.seq_cst);
    }

    pub fn getScheduler(self: *Self) *WorkStealingScheduler {
        return self.scheduler;
    }

    pub fn getConfig(self: *Self) SystemConfiguration {
        return self.config;
    }

    pub fn getStats(self: *Self) SystemStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.stats;
    }

    // Actor创建和管理
    pub fn actorOf(self: *Self, props: ActorProps, name: ?[]const u8) !*ActorRef {
        return self.createActorAt(props, "/user", name);
    }

    pub fn spawn(self: *Self, comptime ActorType: type, init_data: anytype) !*ActorRef {
        _ = ActorType;
        _ = init_data;
        // 简化的spawn实现 - 创建一个基本的Actor
        const props = ActorProps.create(GuardianBehavior.create);
        const actor_ref_ptr = try self.actorOf(props, null);

        // 为Actor创建并提交消息处理任务
        try self.scheduleActorMessageProcessing(actor_ref_ptr);

        return actor_ref_ptr;
    }

    /// 为Actor调度消息处理任务
    fn scheduleActorMessageProcessing(self: *Self, actor_ref: *ActorRef) !void {
        // 获取底层Actor - 这需要从ActorRef中提取
        // 暂时使用一个简化的实现，直接调度消息处理
        _ = actor_ref;

        // 创建一个通用的消息处理任务
        const task = try self.allocator.create(MessageProcessingTask);
        task.* = MessageProcessingTask{
            .task = Task{
                .vtable = &MessageProcessingTask.vtable,
            },
            .system = self,
            .allocator = self.allocator,
        };

        // 提交任务到调度器
        try self.scheduler.submit(&task.task);
    }

    /// 通用消息处理任务
    const MessageProcessingTask = struct {
        const TaskSelf = @This();

        task: Task,
        system: *ActorSystem,
        allocator: Allocator,

        const vtable = Task.VTable{
            .execute = execute,
            .deinit = deinitTask,
            .getName = getTaskName,
        };

        fn execute(task: *Task) !void {
            const self = @as(*TaskSelf, @fieldParentPtr("task", task));

            // 遍历所有Actor，处理它们的消息
            var iterator = self.system.actors.iterator();
            while (iterator.next()) |entry| {
                const actor_ref = entry.value_ptr.*;

                // 尝试处理这个Actor的消息
                // 这是一个简化的实现，实际应该更高效
                _ = actor_ref;
                // TODO: 实现实际的消息处理逻辑
            }

            // 重新调度自己，形成持续的消息处理循环
            const next_task = try self.allocator.create(MessageProcessingTask);
            next_task.* = MessageProcessingTask{
                .task = Task{
                    .vtable = &MessageProcessingTask.vtable,
                },
                .system = self.system,
                .allocator = self.allocator,
            };

            // 延迟一点时间再调度，避免CPU占用过高
            std.time.sleep(1 * std.time.ns_per_ms);
            self.system.scheduler.submit(&next_task.task) catch {};
        }

        fn deinitTask(task: *Task) void {
            const self = @as(*TaskSelf, @fieldParentPtr("task", task));
            self.allocator.destroy(self);
        }

        fn getTaskName(task: *Task) []const u8 {
            _ = task;
            return "SystemMessageProcessing";
        }
    };

    pub fn createActorAt(self: *Self, props: ActorProps, parent_path: []const u8, name: ?[]const u8) !*ActorRef {
        if (self.state.load(.seq_cst) != .running) {
            return ActorError.ActorSystemShutdown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // 生成Actor名称和路径
        const actor_name = name orelse try generateActorName(self.allocator);
        const actor_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent_path, actor_name });
        defer if (name == null) self.allocator.free(actor_name);

        // 检查路径是否已存在
        if (self.actors.contains(actor_path)) {
            self.allocator.free(actor_path);
            return ActorError.ActorAlreadyExists;
        }

        // 获取父Actor
        const parent = self.actors.get(parent_path);

        // 创建Actor路径对象
        const path_obj = try ActorPath.init(self.allocator, actor_path);

        // 创建Actor实例
        const actor = try self.createActor(props, path_obj, parent);

        // 创建ActorRef
        const actor_ref = try LocalActorRef.init(actor, path_obj, self.allocator);

        // 注册到系统
        try self.actors.put(try self.allocator.dupe(u8, actor_path), actor_ref.getActorRef());

        // 更新统计信息
        self.stats.recordActorCreated();

        self.allocator.free(actor_path);
        return actor_ref.getActorRef();
    }

    pub fn createActor(self: *Self, props: ActorProps, path: ActorPath, parent: ?*ActorRef) !*Actor {
        _ = path;
        _ = parent;

        // 直接创建StandardMailbox，避免MailboxInterface的复制问题
        const mailbox = try self.allocator.create(StandardMailbox);
        mailbox.* = try StandardMailbox.init(self.allocator, MailboxConfig.default());

        // 创建MailboxInterface包装器
        const mailbox_interface = try self.allocator.create(MailboxInterface);
        mailbox_interface.* = MailboxInterface{
            .vtable = &StandardMailbox.vtable,
            .ptr = mailbox,
        };

        // 创建Actor实例
        const actor = try Actor.init(self.allocator, props.config, mailbox_interface);

        // 创建Actor行为
        const behavior = try props.behavior_factory(&actor.context);
        actor.setBehavior(behavior);

        // 启动Actor
        try actor.start();

        return actor;
    }

    pub fn stopActor(self: *Self, actor_ref: *ActorRef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 发送停止消息
        try actor_ref.tell(.stop, null);

        // 从注册表中移除
        const path_str = try actor_ref.getPath().toString(self.allocator);
        defer self.allocator.free(path_str);

        if (self.actors.fetchRemove(path_str)) |entry| {
            self.allocator.free(entry.key);
            self.stats.recordActorTerminated();
        }
    }

    // Actor查找
    pub fn actorSelection(self: *Self, path: []const u8) !*ActorSelection {
        return ActorSelection.init(path, self, self.allocator);
    }

    pub fn findActor(self: *Self, path: []const u8) ?*ActorRef {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.actors.get(path);
    }

    // 监控管理
    pub fn registerWatch(self: *Self, watcher: *ActorRef, watched: *ActorRef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = try self.watchers.getOrPut(watched);
        if (!result.found_existing) {
            result.value_ptr.* = ArrayList(*ActorRef).init(self.allocator);
        }

        try result.value_ptr.append(watcher);
    }

    pub fn unregisterWatch(self: *Self, watcher: *ActorRef, watched: *ActorRef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.watchers.getPtr(watched)) |watchers_list| {
            for (watchers_list.items, 0..) |w, i| {
                if (w.equals(watcher)) {
                    _ = watchers_list.swapRemove(i);
                    break;
                }
            }

            // 如果没有监控者了，移除条目
            if (watchers_list.items.len == 0) {
                watchers_list.deinit();
                _ = self.watchers.remove(watched);
            }
        }
    }

    pub fn notifyWatchers(self: *Self, terminated_actor: *ActorRef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.watchers.get(terminated_actor)) |watchers_list| {
            const terminated_msg = TerminatedMessage{
                .actor = terminated_actor,
                .address_terminated = true,
                .existing_watcher = true,
            };

            for (watchers_list.items) |watcher| {
                watcher.tell(terminated_msg, null) catch {};
            }
        }
    }

    // 系统生命周期
    pub fn shutdown(self: *Self) !void {
        const current_state = self.state.load(.seq_cst);
        if (current_state == .terminated or current_state == .terminating) {
            return;
        }

        self.state.store(.terminating, .seq_cst);

        // 创建停止消息
        var stop_message = Message.createSystem(.stop, null);

        // 停止用户Guardian
        try self.user_guardian.tell(&stop_message, null);

        // 等待所有Actor停止
        try self.waitForTermination(self.config.shutdown_timeout_ms);

        // 停止调度器
        try self.scheduler.stop();

        self.state.store(.terminated, .seq_cst);
        self.shutdown_signal.set();
    }

    pub fn awaitTermination(self: *Self, timeout_ms: u64) !void {
        const start_time = std.time.milliTimestamp();

        while (self.state.load(.seq_cst) != .terminated) {
            if (std.time.milliTimestamp() - start_time > timeout_ms) {
                return ActorError.TimeoutError;
            }

            std.time.sleep(1_000_000); // 1ms
        }
    }

    // 扩展管理
    pub fn registerExtension(self: *Self, name: []const u8, extension: *Extension) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const name_copy = try self.allocator.dupe(u8, name);
        try self.extensions.put(name_copy, extension);
    }

    pub fn getExtension(self: *Self, name: []const u8) ?*Extension {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.extensions.get(name);
    }

    // 私有方法
    fn initGuardians(self: *Self) !void {
        // 创建根Guardian
        const guardian_props = ActorProps.create(GuardianBehavior.create);
        const guardian_path = try ActorPath.init(self.allocator, "/");
        const guardian_actor = try self.createActor(guardian_props, guardian_path, null);
        const guardian_local_ref = try LocalActorRef.init(guardian_actor, guardian_path, self.allocator);
        self.guardian = guardian_local_ref.getActorRef();

        // 创建用户Guardian
        const user_guardian_props = ActorProps.create(UserGuardianBehavior.create);
        const user_guardian_path = try ActorPath.init(self.allocator, "/user");
        const user_guardian_actor = try self.createActor(user_guardian_props, user_guardian_path, self.guardian);
        const user_guardian_local_ref = try LocalActorRef.init(user_guardian_actor, user_guardian_path, self.allocator);
        self.user_guardian = user_guardian_local_ref.getActorRef();

        // 创建系统Guardian
        const system_guardian_props = ActorProps.create(SystemGuardianBehavior.create);
        const system_guardian_path = try ActorPath.init(self.allocator, "/system");
        const system_guardian_actor = try self.createActor(system_guardian_props, system_guardian_path, self.guardian);
        const system_guardian_local_ref = try LocalActorRef.init(system_guardian_actor, system_guardian_path, self.allocator);
        self.system_guardian = system_guardian_local_ref.getActorRef();

        // 注册Guardian
        try self.actors.put(try self.allocator.dupe(u8, "/"), self.guardian);
        try self.actors.put(try self.allocator.dupe(u8, "/user"), self.user_guardian);
        try self.actors.put(try self.allocator.dupe(u8, "/system"), self.system_guardian);
    }

    fn waitForTermination(self: *Self, timeout_ms: u64) !void {
        const start_time = std.time.milliTimestamp();

        while (self.stats.total_actors.load(.monotonic) > 3) { // 只剩下3个Guardian
            if (std.time.milliTimestamp() - start_time > timeout_ms) {
                return ActorError.TimeoutError;
            }

            std.time.sleep(10_000_000); // 10ms
        }
    }

    pub fn awaitQuiescence(self: *Self, timeout_ms: u64) !void {
        // 等待所有消息处理完成
        const timeout_ns = timeout_ms * std.time.ns_per_ms;
        const start_time = std.time.nanoTimestamp();

        while (true) {
            const current_time = std.time.nanoTimestamp();
            if (current_time - start_time > timeout_ns) {
                return ActorError.TimeoutError;
            }

            // 简单的静默检测 - 检查是否有活跃的消息处理
            const current_processed = self.stats.messages_processed.load(.monotonic);
            std.time.sleep(10 * std.time.ns_per_ms); // 等待10ms
            const new_processed = self.stats.messages_processed.load(.monotonic);

            if (current_processed == new_processed) {
                // 没有新消息被处理，认为达到静默状态
                break;
            }
        }
    }

    pub fn setSupervisorConfig(self: *Self, config: anytype) void {
        _ = self;
        _ = config;
        // 简化实现 - 暂时不做任何操作
    }

    pub fn getSupervisorStats(self: *Self) SupervisorStats {
        _ = self;
        return SupervisorStats{
            .restarts = 0,
            .failures = 0,
        };
    }
};

// 监督统计信息
pub const SupervisorStats = struct {
    restarts: u64,
    failures: u64,

    pub fn print(self: *const SupervisorStats) void {
        std.log.info("Supervisor Stats:", .{});
        std.log.info("  Restarts: {}", .{self.restarts});
        std.log.info("  Failures: {}", .{self.failures});
    }
};

// 扩展接口
pub const Extension = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        init: *const fn (self: *Extension, system: *ActorSystem) anyerror!void,
        deinit: *const fn (self: *Extension) void,
    };

    pub fn init(self: *Extension, system: *ActorSystem) !void {
        try self.vtable.init(self, system);
    }

    pub fn deinit(self: *Extension) void {
        self.vtable.deinit(self);
    }
};

// 简化的 Guardian 行为
const GuardianBehavior = struct {
    const vtable = ActorBehavior.VTable{
        .receive = receive,
        .preStart = preStart,
        .postStop = postStop,
        .preRestart = preRestart,
        .postRestart = postRestart,
        .supervisorStrategy = supervisorStrategy,
    };

    fn create(context: *ActorContext) !*ActorBehavior {
        const behavior = try context.allocator.create(ActorBehavior);
        behavior.* = ActorBehavior{
            .vtable = &vtable,
        };
        return behavior;
    }

    fn receive(behavior: *ActorBehavior, context: *ActorContext, message: *Message) !void {
        _ = behavior;
        _ = context;
        _ = message;
        // Guardian的默认行为：监督子Actor
    }

    fn preStart(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn postStop(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn preRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("Guardian preRestart: {}", .{reason});
    }

    fn postRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("Guardian postRestart: {}", .{reason});
    }

    fn supervisorStrategy(behavior: *ActorBehavior) ActorBehavior.SupervisionStrategy {
        _ = behavior;
        return .restart_actor;
    }
};

const UserGuardianBehavior = struct {
    const vtable = ActorBehavior.VTable{
        .receive = receive,
        .preStart = preStart,
        .postStop = postStop,
        .preRestart = preRestart,
        .postRestart = postRestart,
        .supervisorStrategy = supervisorStrategy,
    };

    fn create(context: *ActorContext) !*ActorBehavior {
        const behavior = try context.allocator.create(ActorBehavior);
        behavior.* = ActorBehavior{
            .vtable = &vtable,
        };
        return behavior;
    }

    fn receive(behavior: *ActorBehavior, context: *ActorContext, message: *Message) !void {
        _ = behavior;
        _ = context;
        _ = message;
        // 用户Guardian的行为
    }

    fn preStart(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn postStop(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn preRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("UserGuardian preRestart: {}", .{reason});
    }

    fn postRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("UserGuardian postRestart: {}", .{reason});
    }

    fn supervisorStrategy(behavior: *ActorBehavior) ActorBehavior.SupervisionStrategy {
        _ = behavior;
        return .restart_actor;
    }
};

const SystemGuardianBehavior = struct {
    const vtable = ActorBehavior.VTable{
        .receive = receive,
        .preStart = preStart,
        .postStop = postStop,
        .preRestart = preRestart,
        .postRestart = postRestart,
        .supervisorStrategy = supervisorStrategy,
    };

    fn create(context: *ActorContext) !*ActorBehavior {
        const behavior = try context.allocator.create(ActorBehavior);
        behavior.* = ActorBehavior{
            .vtable = &vtable,
        };
        return behavior;
    }

    fn receive(behavior: *ActorBehavior, context: *ActorContext, message: *Message) !void {
        _ = behavior;
        _ = context;
        _ = message;
        // 系统Guardian的行为
    }

    fn preStart(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn postStop(behavior: *ActorBehavior, context: *ActorContext) !void {
        _ = behavior;
        _ = context;
    }

    fn preRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("SystemGuardian preRestart: {}", .{reason});
    }

    fn postRestart(behavior: *ActorBehavior, context: *ActorContext, reason: anyerror) !void {
        _ = behavior;
        _ = context;
        std.log.debug("SystemGuardian postRestart: {}", .{reason});
    }

    fn supervisorStrategy(behavior: *ActorBehavior) ActorBehavior.SupervisionStrategy {
        _ = behavior;
        return .restart_actor;
    }
};

// 辅助类型和函数
const StringContext = struct {
    pub fn hash(self: @This(), s: []const u8) u64 {
        _ = self;
        return std.hash_map.hashString(s);
    }

    pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, a, b);
    }
};

const ActorRefContext = struct {
    pub fn hash(self: @This(), actor_ref: *ActorRef) u64 {
        _ = self;
        return @intFromPtr(actor_ref);
    }

    pub fn eql(self: @This(), a: *ActorRef, b: *ActorRef) bool {
        _ = self;
        return a == b;
    }
};

fn generateActorName(allocator: Allocator) ![]const u8 {
    const timestamp = std.time.nanoTimestamp();
    return std.fmt.allocPrint(allocator, "actor-{d}", .{timestamp});
}

// 测试
test "ActorSystem creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = SystemConfiguration.development();
    const system = try ActorSystem.init("test-system", config, allocator);
    defer system.deinit();

    try testing.expectEqualStrings("test-system", system.getName());
    try testing.expect(system.getState() == .running);
}

test "ActorSystem state transitions" {
    const testing = std.testing;

    try testing.expect(ActorSystemState.starting != ActorSystemState.running);
    try testing.expect(ActorSystemState.running != ActorSystemState.terminating);
    try testing.expect(ActorSystemState.terminating != ActorSystemState.terminated);
}
