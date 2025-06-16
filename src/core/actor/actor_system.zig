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
const ActorRef = @import("actor_ref.zig").ActorRef;
const LocalActorRef = @import("actor_ref.zig").LocalActorRef;
const ActorContext = @import("actor_context.zig").ActorContext;
const ActorProps = @import("actor_context.zig").ActorProps;
const Message = @import("../message/mod.zig").Message;
const Scheduler = @import("../scheduler/mod.zig").Scheduler;
const MailboxInterface = @import("../mailbox/mod.zig").MailboxInterface;
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
    scheduler: *Scheduler,
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
        const scheduler = try Scheduler.init(config.scheduler, allocator);
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

        // 启动调度器
        try self.scheduler.start();

        // 设置为运行状态
        self.state.store(.running, .SeqCst);

        return self;
    }

    pub fn deinit(self: *Self) void {
        // 确保系统已关闭
        self.shutdown() catch {};

        self.mutex.lock();
        defer self.mutex.unlock();

        // 清理Actor
        var actor_iter = self.actors.iterator();
        while (actor_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // ActorRef会在其自己的deinit中清理
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
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.extensions.deinit();

        // 清理调度器
        self.scheduler.deinit();

        // 清理名称
        self.allocator.free(self.name);

        // 销毁自身
        self.allocator.destroy(self);
    }

    // 系统管理
    pub fn getName(self: *Self) []const u8 {
        return self.name;
    }

    pub fn getState(self: *Self) ActorSystemState {
        return self.state.load(.SeqCst);
    }

    pub fn getScheduler(self: *Self) *Scheduler {
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

    pub fn createActorAt(self: *Self, props: ActorProps, parent_path: []const u8, name: ?[]const u8) !*ActorRef {
        if (self.state.load(.SeqCst) != .running) {
            return ActorError.SystemNotRunning;
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
        self.stats.actors_created += 1;
        self.stats.total_actors += 1;

        self.allocator.free(actor_path);
        return actor_ref.getActorRef();
    }

    pub fn createActor(self: *Self, props: ActorProps, path: ActorPath, parent: ?*ActorRef) !*Actor {
        // 创建Actor上下文
        const context = try self.allocator.create(ActorContext);
        errdefer self.allocator.destroy(context);

        // 创建临时ActorRef用于初始化上下文
        const temp_ref = try LocalActorRef.init(undefined, path, self.allocator);
        defer temp_ref.deinit();

        context.* = try ActorContext.init(temp_ref.getActorRef(), parent, self, props.config, self.allocator);

        // 创建Actor行为
        const behavior = try props.behavior_factory(context);

        // 创建Actor实例
        const actor = try Actor.init(context, behavior, self.allocator);

        // 更新ActorRef指向实际的Actor
        temp_ref.actor = actor;

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
            self.stats.actors_stopped += 1;
            self.stats.total_actors -= 1;
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
        const current_state = self.state.load(.SeqCst);
        if (current_state == .terminated or current_state == .terminating) {
            return;
        }

        self.state.store(.terminating, .SeqCst);

        // 停止用户Guardian
        try self.user_guardian.tell(.stop, null);

        // 等待所有Actor停止
        try self.waitForTermination(self.config.shutdown_timeout_ms);

        // 停止调度器
        try self.scheduler.stop();

        self.state.store(.terminated, .SeqCst);
        self.shutdown_signal.set();
    }

    pub fn awaitTermination(self: *Self, timeout_ms: u64) !void {
        const start_time = std.time.milliTimestamp();

        while (self.state.load(.SeqCst) != .terminated) {
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
        self.guardian = try LocalActorRef.init(guardian_actor, guardian_path, self.allocator).getActorRef();

        // 创建用户Guardian
        const user_guardian_props = ActorProps.create(UserGuardianBehavior.create);
        const user_guardian_path = try ActorPath.init(self.allocator, "/user");
        const user_guardian_actor = try self.createActor(user_guardian_props, user_guardian_path, self.guardian);
        self.user_guardian = try LocalActorRef.init(user_guardian_actor, user_guardian_path, self.allocator).getActorRef();

        // 创建系统Guardian
        const system_guardian_props = ActorProps.create(SystemGuardianBehavior.create);
        const system_guardian_path = try ActorPath.init(self.allocator, "/system");
        const system_guardian_actor = try self.createActor(system_guardian_props, system_guardian_path, self.guardian);
        self.system_guardian = try LocalActorRef.init(system_guardian_actor, system_guardian_path, self.allocator).getActorRef();

        // 注册Guardian
        try self.actors.put(try self.allocator.dupe(u8, "/"), self.guardian);
        try self.actors.put(try self.allocator.dupe(u8, "/user"), self.user_guardian);
        try self.actors.put(try self.allocator.dupe(u8, "/system"), self.system_guardian);
    }

    fn waitForTermination(self: *Self, timeout_ms: u64) !void {
        const start_time = std.time.milliTimestamp();

        while (self.stats.total_actors > 3) { // 只剩下3个Guardian
            if (std.time.milliTimestamp() - start_time > timeout_ms) {
                return ActorError.TimeoutError;
            }

            std.time.sleep(10_000_000); // 10ms
        }
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

// Guardian行为
const GuardianBehavior = struct {
    fn create(context: *ActorContext) !ActorBehavior {
        _ = context;
        return ActorBehavior{
            .receive = receive,
        };
    }

    fn receive(context: *ActorContext, message: *Message) !void {
        _ = context;
        _ = message;
        // Guardian的默认行为：监督子Actor
    }
};

const UserGuardianBehavior = struct {
    fn create(context: *ActorContext) !ActorBehavior {
        _ = context;
        return ActorBehavior{
            .receive = receive,
        };
    }

    fn receive(context: *ActorContext, message: *Message) !void {
        _ = context;
        _ = message;
        // 用户Guardian的行为
    }
};

const SystemGuardianBehavior = struct {
    fn create(context: *ActorContext) !ActorBehavior {
        _ = context;
        return ActorBehavior{
            .receive = receive,
        };
    }

    fn receive(context: *ActorContext, message: *Message) !void {
        _ = context;
        _ = message;
        // 系统Guardian的行为
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

const TerminatedMessage = @import("actor_context.zig").TerminatedMessage;
const ActorBehavior = @import("actor.zig").ActorBehavior;

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
