const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

// Import all components
const HighPerfActor = @import("high_perf_actor.zig").HighPerfActor;
const HighPerfActorBehavior = @import("high_perf_actor.zig").HighPerfActorBehavior;
const ActorStats = @import("high_perf_actor.zig").ActorStats;
const LoadMetrics = @import("high_perf_actor.zig").LoadMetrics;
const ProcessingState = @import("high_perf_actor.zig").ProcessingState;

const HighPerfScheduler = @import("high_perf_scheduler.zig").HighPerfScheduler;
const SchedulerConfig = @import("high_perf_scheduler.zig").SchedulerConfig;

const FastMessage = @import("message_pool.zig").FastMessage;
const MessagePool = @import("message_pool.zig").MessagePool;
const MessageBatch = @import("message_pool.zig").MessageBatch;

// 超高性能Actor系统 - 目标: 100M+ msg/s
pub const UltraHighPerfSystem = struct {
    const Self = @This();
    const MAX_ACTORS = 1000000; // 支持100万Actor

    // 核心组件
    message_pool: MessagePool,
    scheduler: *HighPerfScheduler,

    // Actor管理
    actors: std.ArrayList(*HighPerfActor),
    actor_map: std.AutoHashMap(u32, *HighPerfActor),
    next_actor_id: std.atomic.Value(u32),

    // 系统状态
    running: std.atomic.Value(bool),
    start_time: i128,

    // 性能监控
    stats: SystemStats,
    monitor_thread: ?Thread,

    // 内存管理
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: SystemConfig) !Self {
        const scheduler_config = SchedulerConfig{
            .worker_threads = config.worker_threads,
            .enable_work_stealing = config.enable_work_stealing,
            .high_priority_ratio = config.high_priority_ratio,
        };

        return Self{
            .message_pool = try MessagePool.init(allocator),
            .scheduler = try HighPerfScheduler.init(allocator, scheduler_config),
            .actors = std.ArrayList(*HighPerfActor).init(allocator),
            .actor_map = std.AutoHashMap(u32, *HighPerfActor).init(allocator),
            .next_actor_id = std.atomic.Value(u32).init(1),
            .running = std.atomic.Value(bool).init(false),
            .start_time = std.time.nanoTimestamp(),
            .stats = SystemStats.init(),
            .monitor_thread = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // 清理所有Actor
        for (self.actors.items) |actor| {
            actor.deinit();
            self.allocator.destroy(actor);
        }
        self.actors.deinit();
        self.actor_map.deinit();

        // 清理组件
        self.scheduler.deinit(); // 这会释放调度器本身
        self.message_pool.deinit();
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.start_time = std.time.nanoTimestamp();

        // 启动调度器
        try self.scheduler.start();

        // 启动监控线程
        self.monitor_thread = try Thread.spawn(.{}, monitorLoop, .{self});

        std.log.info("UltraHighPerfSystem started with {} workers", .{self.scheduler.worker_count});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);

        // 停止调度器
        self.scheduler.stop();

        // 停止监控线程
        if (self.monitor_thread) |thread| {
            thread.join();
            self.monitor_thread = null;
        }

        std.log.info("UltraHighPerfSystem stopped", .{});
    }

    // 创建高性能Actor
    pub fn spawn(self: *Self, comptime T: type, behavior: T, name: []const u8) !ActorRef {
        const actor_id = self.next_actor_id.fetchAdd(1, .monotonic);

        // 分配行为对象
        const behavior_ptr = try self.allocator.create(T);
        behavior_ptr.* = behavior;

        // 获取虚函数表
        const vtable = HighPerfActorBehavior(T).getVTable();

        // 创建Actor
        const actor = try self.allocator.create(HighPerfActor);
        actor.* = HighPerfActor.init(
            actor_id,
            name,
            behavior_ptr,
            &vtable,
            &self.message_pool,
            self.allocator,
        );

        // 添加到管理结构
        try self.actors.append(actor);
        try self.actor_map.put(actor_id, actor);

        // 启动Actor
        actor.start();

        // 调度Actor进行初始处理
        try self.scheduler.schedule(actor);

        _ = self.stats.actors_created.fetchAdd(1, .monotonic);

        return ActorRef{
            .id = actor_id,
            .actor = actor,
            .system = self,
        };
    }

    // 高性能字符串消息发送
    pub fn sendString(self: *Self, actor_id: u32, data: []const u8) !bool {
        const actor = self.actor_map.get(actor_id) orelse return false;

        if (self.message_pool.acquire()) |msg| {
            const sequence = self.message_pool.nextSequence();
            msg.* = FastMessage.createUserString(actor_id, 0, sequence, data);

            const sent = actor.send(msg);
            if (sent) {
                _ = self.stats.messages_sent.fetchAdd(1, .monotonic);
                try self.scheduler.schedule(actor);
            } else {
                self.message_pool.release(msg);
            }
            return sent;
        }
        return false;
    }

    // 高性能整数消息发送
    pub fn sendInt(self: *Self, actor_id: u32, data: i64) !bool {
        const actor = self.actor_map.get(actor_id) orelse return false;

        if (self.message_pool.acquire()) |msg| {
            const sequence = self.message_pool.nextSequence();
            msg.* = FastMessage.createUserInt(actor_id, 0, sequence, data);

            const sent = actor.send(msg);
            if (sent) {
                _ = self.stats.messages_sent.fetchAdd(1, .monotonic);
                try self.scheduler.schedule(actor);
            } else {
                self.message_pool.release(msg);
            }
            return sent;
        }
        return false;
    }

    // 高性能浮点数消息发送
    pub fn sendFloat(self: *Self, actor_id: u32, data: f64) !bool {
        const actor = self.actor_map.get(actor_id) orelse return false;

        if (self.message_pool.acquire()) |msg| {
            const sequence = self.message_pool.nextSequence();
            msg.* = FastMessage.createUserFloat(actor_id, 0, sequence, data);

            const sent = actor.send(msg);
            if (sent) {
                _ = self.stats.messages_sent.fetchAdd(1, .monotonic);
                try self.scheduler.schedule(actor);
            } else {
                self.message_pool.release(msg);
            }
            return sent;
        }
        return false;
    }

    // 高性能ping消息发送
    pub fn sendPing(self: *Self, actor_id: u32) !bool {
        const actor = self.actor_map.get(actor_id) orelse return false;

        if (self.message_pool.acquire()) |msg| {
            const sequence = self.message_pool.nextSequence();
            msg.* = FastMessage.createSystemPing(actor_id, 0, sequence);

            const sent = actor.send(msg);
            if (sent) {
                _ = self.stats.messages_sent.fetchAdd(1, .monotonic);
                try self.scheduler.schedule(actor);
            } else {
                self.message_pool.release(msg);
            }
            return sent;
        }
        return false;
    }

    // 批量消息发送
    pub fn sendBatch(self: *Self, actor_id: u32, messages: []const BatchMessageData) !u32 {
        const actor = self.actor_map.get(actor_id) orelse return 0;

        var batch = MessageBatch.init();
        var created: u32 = 0;

        for (messages) |msg_data| {
            if (self.message_pool.acquire()) |msg| {
                const sequence = self.message_pool.nextSequence();

                switch (msg_data.msg_type) {
                    .user_string => {
                        msg.* = FastMessage.createUserString(actor_id, 0, sequence, msg_data.data.string);
                    },
                    .user_int => {
                        msg.* = FastMessage.createUserInt(actor_id, 0, sequence, msg_data.data.int_val);
                    },
                    .user_float => {
                        msg.* = FastMessage.createUserFloat(actor_id, 0, sequence, msg_data.data.float_val);
                    },
                    else => {
                        self.message_pool.release(msg);
                        continue;
                    },
                }

                if (!batch.add(msg)) {
                    self.message_pool.release(msg);
                    break;
                }
                created += 1;
            }
        }

        // 发送批量消息
        const sent = actor.sendBatch(&batch);
        _ = self.stats.messages_sent.fetchAdd(sent, .monotonic);

        // 释放未发送的消息
        if (sent < created) {
            for (batch.getMessages()[sent..]) |msg| {
                self.message_pool.release(msg);
            }
        }

        // 重新调度Actor
        if (sent > 0) {
            try self.scheduler.schedule(actor);
        }

        return sent;
    }

    // 获取Actor引用
    pub fn getActor(self: *Self, actor_id: u32) ?ActorRef {
        if (self.actor_map.get(actor_id)) |actor| {
            return ActorRef{
                .id = actor_id,
                .actor = actor,
                .system = self,
            };
        }
        return null;
    }

    // 系统统计
    pub fn getStats(self: *Self) SystemStats {
        var stats = self.stats;

        // 聚合调度器统计
        const scheduler_stats = self.scheduler.getStats();
        stats.total_scheduled = scheduler_stats.high_priority_scheduled.load(.monotonic) +
            scheduler_stats.global_scheduled.load(.monotonic) +
            scheduler_stats.local_scheduled.load(.monotonic);

        // 聚合Actor统计
        var total_processed: u64 = 0;
        var total_dropped: u64 = 0;
        var healthy_actors: u32 = 0;

        for (self.actors.items) |actor| {
            const actor_stats = actor.getStats();
            total_processed += actor_stats.messages_processed.load(.monotonic);
            total_dropped += actor_stats.messages_dropped.load(.monotonic);

            if (actor.isHealthy()) {
                healthy_actors += 1;
            }
        }

        stats.messages_processed = total_processed;
        stats.messages_dropped = total_dropped;
        stats.healthy_actors = healthy_actors;
        stats.total_actors = @intCast(self.actors.items.len);

        // 计算吞吐量
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(now - self.start_time, 1000000);
        if (elapsed_ms > 0) {
            stats.throughput = @divTrunc(total_processed * 1000, @as(u64, @intCast(elapsed_ms)));
        }

        return stats;
    }

    // 性能监控循环
    fn monitorLoop(self: *Self) void {
        while (self.running.load(.acquire)) {
            std.time.sleep(5000 * std.time.ns_per_ms); // 每5秒监控一次

            const stats = self.getStats();
            const pool_stats = self.message_pool.getStats();

            std.log.info("📊 System Stats: {} actors, {d:.1}M msg/s, {d:.1}% pool usage, {} healthy", .{
                stats.total_actors,
                @as(f64, @floatFromInt(stats.throughput)) / 1000000.0,
                @as(f64, @floatFromInt(pool_stats.used_messages)) * 100.0 / @as(f64, @floatFromInt(pool_stats.total_messages)),
                stats.healthy_actors,
            });
        }
    }
};

// Actor引用
pub const ActorRef = struct {
    id: u32,
    actor: *HighPerfActor,
    system: *UltraHighPerfSystem,

    pub fn sendString(self: ActorRef, data: []const u8) !bool {
        return self.system.sendString(self.id, data);
    }

    pub fn sendInt(self: ActorRef, data: i64) !bool {
        return self.system.sendInt(self.id, data);
    }

    pub fn sendFloat(self: ActorRef, data: f64) !bool {
        return self.system.sendFloat(self.id, data);
    }

    pub fn sendPing(self: ActorRef) !bool {
        return self.system.sendPing(self.id);
    }

    pub fn sendBatch(self: ActorRef, messages: []const BatchMessageData) !u32 {
        return self.system.sendBatch(self.id, messages);
    }

    pub fn getStats(self: ActorRef) ActorStats {
        return self.actor.getStats();
    }

    pub fn getLoadMetrics(self: ActorRef) LoadMetrics {
        return self.actor.getLoadMetrics();
    }

    pub fn isHealthy(self: ActorRef) bool {
        return self.actor.isHealthy();
    }
};

// 系统配置
pub const SystemConfig = struct {
    worker_threads: u32 = 16,
    enable_work_stealing: bool = true,
    high_priority_ratio: f32 = 0.2,
};

// 批量消息数据
pub const BatchMessageData = struct {
    msg_type: FastMessage.Type,
    data: union {
        string: []const u8,
        int_val: i64,
        float_val: f64,
    },
};

// 系统统计
pub const SystemStats = struct {
    actors_created: std.atomic.Value(u64),
    messages_sent: std.atomic.Value(u64),
    messages_processed: u64,
    messages_dropped: u64,
    total_scheduled: u64,
    throughput: u64,
    total_actors: u32,
    healthy_actors: u32,

    pub fn init() SystemStats {
        return SystemStats{
            .actors_created = std.atomic.Value(u64).init(0),
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_processed = 0,
            .messages_dropped = 0,
            .total_scheduled = 0,
            .throughput = 0,
            .total_actors = 0,
            .healthy_actors = 0,
        };
    }
};
