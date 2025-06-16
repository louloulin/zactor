//! Actor Module - Actor模块
//! 提供Actor系统的核心组件和接口

const std = @import("std");
const Allocator = std.mem.Allocator;

// 重新导出核心Actor组件
pub const Actor = @import("actor.zig").Actor;
pub const ActorRef = @import("actor_ref.zig").ActorRef;
pub const ActorContext = @import("actor.zig").ActorContext;
pub const ActorSystem = @import("actor_system.zig").ActorSystem;
// TODO: 待实现的模块
// pub const ActorBehavior = @import("behavior.zig").ActorBehavior;
pub const ActorState = @import("state.zig").ActorState;
// pub const ActorLifecycle = @import("lifecycle.zig").ActorLifecycle;

// Actor相关类型和错误
pub const ActorError = error{
    ActorNotFound,
    ActorAlreadyExists,
    ActorSystemShutdown,
    InvalidActorState,
    MessageDeliveryFailed,
    ActorCreationFailed,
    ActorTerminated,
    SupervisionFailed,
    InvalidBehavior,
    ResourceExhausted,
    TimeoutError,
};

// Actor状态枚举
pub const ActorStatus = enum(u8) {
    created = 0,
    starting = 1,
    running = 2,
    stopping = 3,
    stopped = 4,
    failed = 5,
    restarting = 6,
};

// Actor配置
pub const ActorConfig = struct {
    name: ?[]const u8 = null,
    mailbox_capacity: u32 = 1024,
    max_restarts: u32 = 3,
    restart_window_ms: u64 = 60000,
    supervision_strategy: SupervisionStrategy = .one_for_one,
    dispatcher: ?[]const u8 = null,
    router: ?RouterConfig = null,

    pub const SupervisionStrategy = enum {
        one_for_one,
        one_for_all,
        rest_for_one,
    };

    pub const RouterConfig = struct {
        strategy: RouterStrategy,
        pool_size: u32 = 5,

        pub const RouterStrategy = enum {
            round_robin,
            random,
            smallest_mailbox,
            broadcast,
            scatter_gather,
        };
    };

    pub fn default() ActorConfig {
        return ActorConfig{};
    }
};

// Actor统计信息
pub const ActorStats = struct {
    messages_processed: u64 = 0,
    messages_failed: u64 = 0,
    restarts: u32 = 0,
    uptime_ms: u64 = 0,
    last_message_time: i64 = 0,
    mailbox_size: u32 = 0,
    processing_time_avg_ns: u64 = 0,

    pub fn init() ActorStats {
        return ActorStats{};
    }

    pub fn reset(self: *ActorStats) void {
        self.* = ActorStats{};
    }

    pub fn recordMessage(self: *ActorStats, processing_time_ns: u64) void {
        self.messages_processed += 1;
        self.last_message_time = std.time.milliTimestamp();

        // 计算平均处理时间（简单移动平均）
        if (self.messages_processed == 1) {
            self.processing_time_avg_ns = processing_time_ns;
        } else {
            const alpha = 0.1; // 平滑因子
            self.processing_time_avg_ns = @intFromFloat(@as(f64, @floatFromInt(self.processing_time_avg_ns)) * (1.0 - alpha) +
                @as(f64, @floatFromInt(processing_time_ns)) * alpha);
        }
    }

    pub fn recordFailure(self: *ActorStats) void {
        self.messages_failed += 1;
    }

    pub fn recordRestart(self: *ActorStats) void {
        self.restarts += 1;
    }
};

// Actor工厂
pub const ActorFactory = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ActorFactory {
        return ActorFactory{
            .allocator = allocator,
        };
    }

    pub fn createActor(self: *ActorFactory, comptime T: type, config: ActorConfig) !*Actor {
        const actor = try self.allocator.create(Actor);
        actor.* = try Actor.init(T, self.allocator, config);
        return actor;
    }

    pub fn createActorRef(self: *ActorFactory, actor: *Actor) !ActorRef {
        return ActorRef.init(actor, self.allocator);
    }

    pub fn destroyActor(self: *ActorFactory, actor: *Actor) void {
        actor.deinit();
        self.allocator.destroy(actor);
    }
};

// Actor路径
pub const ActorPath = struct {
    segments: [][]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, path: []const u8) !ActorPath {
        var segments = std.ArrayList([]const u8).init(allocator);
        defer segments.deinit();

        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |segment| {
            if (segment.len > 0) {
                const owned_segment = try allocator.dupe(u8, segment);
                try segments.append(owned_segment);
            }
        }

        return ActorPath{
            .segments = try segments.toOwnedSlice(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ActorPath) void {
        for (self.segments) |segment| {
            self.allocator.free(segment);
        }
        self.allocator.free(self.segments);
    }

    pub fn toString(self: *const ActorPath, allocator: Allocator) ![]u8 {
        if (self.segments.len == 0) {
            return try allocator.dupe(u8, "/");
        }

        var total_len: usize = 0;
        for (self.segments) |segment| {
            total_len += segment.len + 1; // +1 for '/'
        }

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;

        for (self.segments) |segment| {
            result[pos] = '/';
            pos += 1;
            @memcpy(result[pos .. pos + segment.len], segment);
            pos += segment.len;
        }

        return result;
    }

    pub fn parent(self: *const ActorPath, allocator: Allocator) !?ActorPath {
        if (self.segments.len <= 1) {
            return null;
        }

        var parent_segments = try allocator.alloc([]const u8, self.segments.len - 1);
        for (self.segments[0 .. self.segments.len - 1], 0..) |segment, i| {
            parent_segments[i] = try allocator.dupe(u8, segment);
        }

        return ActorPath{
            .segments = parent_segments,
            .allocator = allocator,
        };
    }

    pub fn child(self: *const ActorPath, allocator: Allocator, name: []const u8) !ActorPath {
        var child_segments = try allocator.alloc([]const u8, self.segments.len + 1);

        for (self.segments, 0..) |segment, i| {
            child_segments[i] = try allocator.dupe(u8, segment);
        }
        child_segments[self.segments.len] = try allocator.dupe(u8, name);

        return ActorPath{
            .segments = child_segments,
            .allocator = allocator,
        };
    }
};

// Actor选择器
pub const ActorSelection = struct {
    path: ActorPath,
    system: *ActorSystem,

    pub fn init(system: *ActorSystem, path: ActorPath) ActorSelection {
        return ActorSelection{
            .path = path,
            .system = system,
        };
    }

    pub fn resolveOne(self: *ActorSelection) !?ActorRef {
        return self.system.actorSelection(self.path);
    }

    pub fn resolveAll(self: *ActorSelection, allocator: Allocator) ![]ActorRef {
        _ = self;
        _ = allocator;
        // 实现通配符匹配和多个actor解析
        _ = allocator;
        return error.NotImplemented;
    }

    pub fn tell(self: *ActorSelection, message: anytype) !void {
        if (try self.resolveOne()) |actor_ref| {
            try actor_ref.tell(message);
        }
    }
};

// 测试
test "ActorPath operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var path = try ActorPath.init(allocator, "/user/parent/child");
    defer path.deinit();

    try testing.expect(path.segments.len == 3);
    try testing.expectEqualStrings(path.segments[0], "user");
    try testing.expectEqualStrings(path.segments[1], "parent");
    try testing.expectEqualStrings(path.segments[2], "child");

    const path_str = try path.toString(allocator);
    defer allocator.free(path_str);
    try testing.expectEqualStrings(path_str, "/user/parent/child");
}

test "ActorStats operations" {
    const testing = std.testing;

    var stats = ActorStats{};

    stats.recordMessage(1000);
    try testing.expect(stats.messages_processed == 1);
    try testing.expect(stats.processing_time_avg_ns == 1000);

    stats.recordMessage(2000);
    try testing.expect(stats.messages_processed == 2);
    // 平均值应该在1000和2000之间
    try testing.expect(stats.processing_time_avg_ns > 1000);
    try testing.expect(stats.processing_time_avg_ns < 2000);

    stats.recordFailure();
    try testing.expect(stats.messages_failed == 1);

    stats.recordRestart();
    try testing.expect(stats.restarts == 1);
}
