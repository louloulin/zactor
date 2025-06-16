//! System Module - 系统模块
//! 提供Actor系统的核心管理和协调功能

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const AtomicValue = std.atomic.Value;

// 重新导出系统组件
// pub const ActorSystem = @import("actor_system.zig").ActorSystem;
// pub const SystemGuardian = @import("guardian.zig").SystemGuardian;
// pub const SystemRegistry = @import("registry.zig").SystemRegistry;
// pub const SystemMonitor = @import("monitor.zig").SystemMonitor;
// pub const SystemConfig = @import("config.zig").SystemConfig;
// pub const SystemMetrics = @import("metrics.zig").SystemMetrics;
// pub const SystemShutdown = @import("shutdown.zig").SystemShutdown;

// 系统相关错误
pub const SystemError = error{
    SystemNotStarted,
    SystemAlreadyStarted,
    SystemShutdown,
    SystemInitializationFailed,
    InvalidSystemConfig,
    ResourceExhausted,
    ComponentStartupFailed,
    ComponentShutdownFailed,
    RegistryFull,
    ActorNotFound,
    InvalidActorPath,
    CircularDependency,
};

// 系统状态
pub const SystemState = enum {
    created,
    initializing,
    starting,
    running,
    stopping,
    stopped,
    failed,

    pub fn isRunning(self: SystemState) bool {
        return self == .running;
    }

    pub fn canAcceptActors(self: SystemState) bool {
        return self == .running or self == .starting;
    }

    pub fn isShuttingDown(self: SystemState) bool {
        return self == .stopping or self == .stopped;
    }
};

// 系统配置
pub const SystemConfiguration = struct {
    name: []const u8 = "zactor-system",

    // 调度器配置
    scheduler_config: SchedulerConfig = SchedulerConfig{},
    scheduler_threads: u32 = 0, // 0 = auto-detect, 兼容性字段
    enable_work_stealing: bool = true, // 兼容性字段

    // Actor配置
    default_mailbox_capacity: u32 = 1024,
    mailbox_capacity: u32 = 1024, // 兼容性字段

    // 关闭配置
    shutdown_timeout_ms: u64 = 30000, // 30秒关闭超时
    max_actors: u32 = 100000,
    actor_creation_timeout_ms: u64 = 5000,

    // 监控配置
    enable_monitoring: bool = true,
    metrics_collection_interval_ms: u64 = 1000,
    enable_deadlock_detection: bool = true,
    deadlock_detection_interval_ms: u64 = 5000,

    // 内存配置
    enable_memory_pooling: bool = true,
    initial_pool_size: u32 = 1000,
    max_pool_size: u32 = 10000,

    // 网络配置
    enable_remoting: bool = false,
    listen_address: []const u8 = "127.0.0.1",
    listen_port: u16 = 2552,

    // 持久化配置
    enable_persistence: bool = false,
    persistence_backend: PersistenceBackend = .memory,
    persistence_path: []const u8 = "./data",

    // 集群配置
    enable_clustering: bool = false,
    cluster_name: []const u8 = "zactor-cluster",
    seed_nodes: [][]const u8 = &[_][]const u8{},

    // 安全配置
    enable_security: bool = false,
    security_provider: SecurityProvider = .none,

    // 调试配置
    enable_debug_logging: bool = false,
    log_level: LogLevel = .info,
    enable_tracing: bool = false,

    pub const SchedulerConfig = @import("../scheduler/mod.zig").SchedulerConfig;

    pub const PersistenceBackend = enum {
        memory,
        file,
        database,
        custom,
    };

    pub const SecurityProvider = enum {
        none,
        basic,
        tls,
        custom,
    };

    pub const LogLevel = enum {
        debug,
        info,
        warn,
        err,
        fatal,
    };

    pub fn default() SystemConfiguration {
        return SystemConfiguration{};
    }

    pub fn development() SystemConfiguration {
        return SystemConfiguration{
            .name = "zactor-dev",
            .scheduler_config = SchedulerConfig.autoDetect(),
            .enable_monitoring = true,
            .enable_debug_logging = true,
            .log_level = .debug,
            .enable_tracing = true,
            .deadlock_detection_interval_ms = 1000,
        };
    }

    pub fn production() SystemConfiguration {
        return SystemConfiguration{
            .name = "zactor-prod",
            .scheduler_config = SchedulerConfig.forHighThroughput(),
            .enable_monitoring = true,
            .enable_debug_logging = false,
            .log_level = .info,
            .enable_tracing = false,
            .max_actors = 1000000,
            .enable_memory_pooling = true,
            .max_pool_size = 100000,
        };
    }

    pub fn cluster() SystemConfiguration {
        return SystemConfiguration{
            .name = "zactor-cluster",
            .scheduler_config = SchedulerConfig.forHighThroughput(),
            .enable_monitoring = true,
            .enable_remoting = true,
            .enable_clustering = true,
            .enable_persistence = true,
            .persistence_backend = .database,
            .enable_security = true,
            .security_provider = .tls,
        };
    }

    /// 快速启动配置 - 专门解决启动缓慢问题
    pub fn fastStartup() SystemConfiguration {
        return SystemConfiguration{
            .name = "zactor-fast",
            .scheduler_config = SchedulerConfig.forFastStartup(),
            .default_mailbox_capacity = 256, // 小邮箱，快速创建
            .shutdown_timeout_ms = 1000, // 快速关闭
            .max_actors = 1000, // 限制Actor数量
            .actor_creation_timeout_ms = 1000, // 快速创建超时
            .enable_monitoring = false, // 禁用监控
            .enable_deadlock_detection = false, // 禁用死锁检测
            .enable_memory_pooling = false, // 禁用内存池
            .enable_debug_logging = false, // 禁用调试日志
            .log_level = .err, // 只记录错误
            .enable_tracing = false, // 禁用追踪
        };
    }
};

// 系统组件接口
pub const SystemComponent = struct {
    vtable: *const VTable,
    name: []const u8,
    state: AtomicValue(ComponentState),

    pub const ComponentState = enum {
        created,
        starting,
        running,
        stopping,
        stopped,
        failed,
    };

    pub const VTable = struct {
        start: *const fn (self: *SystemComponent) SystemError!void,
        stop: *const fn (self: *SystemComponent) SystemError!void,
        getHealth: *const fn (self: *SystemComponent) HealthStatus,
        getMetrics: *const fn (self: *SystemComponent) ComponentMetrics,
    };

    pub const HealthStatus = enum {
        healthy,
        degraded,
        unhealthy,
        unknown,
    };

    pub const ComponentMetrics = struct {
        uptime_ms: u64,
        memory_usage_bytes: u64,
        cpu_usage_percent: f32,
        error_count: u64,
        last_error_time: i64,
    };

    pub fn init(vtable: *const VTable, name: []const u8) SystemComponent {
        return SystemComponent{
            .vtable = vtable,
            .name = name,
            .state = AtomicValue(ComponentState).init(.created),
        };
    }

    pub fn start(self: *SystemComponent) !void {
        self.state.store(.starting, .monotonic);
        self.vtable.start(self) catch |err| {
            self.state.store(.failed, .monotonic);
            return err;
        };
        self.state.store(.running, .monotonic);
    }

    pub fn stop(self: *SystemComponent) !void {
        self.state.store(.stopping, .monotonic);
        self.vtable.stop(self) catch |err| {
            self.state.store(.failed, .monotonic);
            return err;
        };
        self.state.store(.stopped, .monotonic);
    }

    pub fn getState(self: *const SystemComponent) ComponentState {
        return self.state.load(.monotonic);
    }

    pub fn isRunning(self: *const SystemComponent) bool {
        return self.getState() == .running;
    }

    pub fn getHealth(self: *SystemComponent) HealthStatus {
        return self.vtable.getHealth(self);
    }

    pub fn getMetrics(self: *SystemComponent) ComponentMetrics {
        return self.vtable.getMetrics(self);
    }
};

// 系统事件
pub const SystemEvent = union(enum) {
    system_started: SystemStartedEvent,
    system_stopping: SystemStoppingEvent,
    system_stopped: SystemStoppedEvent,
    actor_created: ActorCreatedEvent,
    actor_terminated: ActorTerminatedEvent,
    component_started: ComponentStartedEvent,
    component_stopped: ComponentStoppedEvent,
    component_failed: ComponentFailedEvent,
    resource_exhausted: ResourceExhaustedEvent,
    deadlock_detected: DeadlockDetectedEvent,

    pub const SystemStartedEvent = struct {
        timestamp: i64,
        system_name: []const u8,
        config: SystemConfiguration,
    };

    pub const SystemStoppingEvent = struct {
        timestamp: i64,
        reason: []const u8,
    };

    pub const SystemStoppedEvent = struct {
        timestamp: i64,
        uptime_ms: u64,
    };

    pub const ActorCreatedEvent = struct {
        timestamp: i64,
        actor_path: []const u8,
        actor_type: []const u8,
    };

    pub const ActorTerminatedEvent = struct {
        timestamp: i64,
        actor_path: []const u8,
        reason: []const u8,
    };

    pub const ComponentStartedEvent = struct {
        timestamp: i64,
        component_name: []const u8,
    };

    pub const ComponentStoppedEvent = struct {
        timestamp: i64,
        component_name: []const u8,
    };

    pub const ComponentFailedEvent = struct {
        timestamp: i64,
        component_name: []const u8,
        error_message: []const u8,
    };

    pub const ResourceExhaustedEvent = struct {
        timestamp: i64,
        resource_type: []const u8,
        current_usage: u64,
        limit: u64,
    };

    pub const DeadlockDetectedEvent = struct {
        timestamp: i64,
        involved_actors: [][]const u8,
        deadlock_chain: [][]const u8,
    };
};

// 系统事件监听器
pub const SystemEventListener = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        onEvent: *const fn (self: *SystemEventListener, event: SystemEvent) void,
    };

    pub fn onEvent(self: *SystemEventListener, event: SystemEvent) void {
        self.vtable.onEvent(self, event);
    }
};

// 系统统计信息
pub const SystemStats = struct {
    start_time: i64,
    uptime_ms: AtomicValue(u64),

    // Actor统计
    total_actors: AtomicValue(u32),
    active_actors: AtomicValue(u32),
    failed_actors: AtomicValue(u32),
    restarted_actors: AtomicValue(u32),

    // 消息统计
    messages_sent: AtomicValue(u64),
    messages_processed: AtomicValue(u64),
    messages_failed: AtomicValue(u64),
    messages_dropped: AtomicValue(u64),

    // 资源统计
    memory_usage_bytes: AtomicValue(u64),
    cpu_usage_percent: AtomicValue(u32), // 存储为整数百分比 * 100
    thread_count: AtomicValue(u32),

    // 性能统计
    avg_message_processing_time_ns: AtomicValue(u64),
    max_message_processing_time_ns: AtomicValue(u64),
    throughput_messages_per_second: AtomicValue(u64),

    pub fn init() SystemStats {
        return SystemStats{
            .start_time = 0, // 将在运行时设置
            .uptime_ms = AtomicValue(u64).init(0),
            .total_actors = AtomicValue(u32).init(0),
            .active_actors = AtomicValue(u32).init(0),
            .failed_actors = AtomicValue(u32).init(0),
            .restarted_actors = AtomicValue(u32).init(0),
            .messages_sent = AtomicValue(u64).init(0),
            .messages_processed = AtomicValue(u64).init(0),
            .messages_failed = AtomicValue(u64).init(0),
            .messages_dropped = AtomicValue(u64).init(0),
            .memory_usage_bytes = AtomicValue(u64).init(0),
            .cpu_usage_percent = AtomicValue(u32).init(0),
            .thread_count = AtomicValue(u32).init(0),
            .avg_message_processing_time_ns = AtomicValue(u64).init(0),
            .max_message_processing_time_ns = AtomicValue(u64).init(0),
            .throughput_messages_per_second = AtomicValue(u64).init(0),
        };
    }

    pub fn initWithCurrentTime() SystemStats {
        var stats = init();
        stats.start_time = std.time.milliTimestamp();
        return stats;
    }

    pub fn updateUptime(self: *SystemStats) void {
        const now = std.time.milliTimestamp();
        const uptime = @as(u64, @intCast(now - self.start_time));
        self.uptime_ms.store(uptime, .monotonic);
    }

    pub fn recordActorCreated(self: *SystemStats) void {
        _ = self.total_actors.fetchAdd(1, .monotonic);
        _ = self.active_actors.fetchAdd(1, .monotonic);
    }

    pub fn recordActorTerminated(self: *SystemStats) void {
        _ = self.active_actors.fetchSub(1, .monotonic);
    }

    pub fn recordActorFailed(self: *SystemStats) void {
        _ = self.failed_actors.fetchAdd(1, .monotonic);
    }

    pub fn recordActorRestarted(self: *SystemStats) void {
        _ = self.restarted_actors.fetchAdd(1, .monotonic);
    }

    pub fn recordMessageSent(self: *SystemStats) void {
        _ = self.messages_sent.fetchAdd(1, .monotonic);
    }

    pub fn recordMessageProcessed(self: *SystemStats, processing_time_ns: u64) void {
        _ = self.messages_processed.fetchAdd(1, .monotonic);

        // 更新平均处理时间
        const current_avg = self.avg_message_processing_time_ns.load(.monotonic);
        const new_avg = if (current_avg == 0)
            processing_time_ns
        else
            // 简单移动平均
            (current_avg * 9 + processing_time_ns) / 10;
        self.avg_message_processing_time_ns.store(new_avg, .monotonic);

        // 更新最大处理时间
        const current_max = self.max_message_processing_time_ns.load(.monotonic);
        if (processing_time_ns > current_max) {
            self.max_message_processing_time_ns.store(processing_time_ns, .monotonic);
        }
    }

    pub fn recordMessageFailed(self: *SystemStats) void {
        _ = self.messages_failed.fetchAdd(1, .monotonic);
    }

    pub fn recordMessageDropped(self: *SystemStats) void {
        _ = self.messages_dropped.fetchAdd(1, .monotonic);
    }

    pub fn updateMemoryUsage(self: *SystemStats, bytes: u64) void {
        self.memory_usage_bytes.store(bytes, .monotonic);
    }

    pub fn updateCpuUsage(self: *SystemStats, percent: f32) void {
        const percent_int = @as(u32, @intFromFloat(percent * 100));
        self.cpu_usage_percent.store(percent_int, .monotonic);
    }

    pub fn updateThreadCount(self: *SystemStats, count: u32) void {
        self.thread_count.store(count, .monotonic);
    }

    pub fn updateThroughput(self: *SystemStats, messages_per_second: u64) void {
        self.throughput_messages_per_second.store(messages_per_second, .monotonic);
    }

    pub fn updateResourceUsage(self: *SystemStats, memory_bytes: u64, cpu_percent: f32, threads: u32) void {
        self.memory_usage_bytes.store(memory_bytes, .monotonic);
        self.cpu_usage_percent.store(@intFromFloat(cpu_percent * 100), .monotonic);
        self.thread_count.store(threads, .monotonic);
    }

    pub fn calculateThroughput(self: *SystemStats, window_ms: u64) void {
        const processed = self.messages_processed.load(.monotonic);
        const throughput = (processed * 1000) / window_ms;
        self.throughput_messages_per_second.store(throughput, .monotonic);
    }

    pub fn getSnapshot(self: *const SystemStats) SystemStatsSnapshot {
        return SystemStatsSnapshot{
            .uptime_ms = self.uptime_ms.load(.monotonic),
            .total_actors = self.total_actors.load(.monotonic),
            .active_actors = self.active_actors.load(.monotonic),
            .failed_actors = self.failed_actors.load(.monotonic),
            .restarted_actors = self.restarted_actors.load(.monotonic),
            .messages_sent = self.messages_sent.load(.monotonic),
            .messages_processed = self.messages_processed.load(.monotonic),
            .messages_failed = self.messages_failed.load(.monotonic),
            .messages_dropped = self.messages_dropped.load(.monotonic),
            .memory_usage_bytes = self.memory_usage_bytes.load(.monotonic),
            .cpu_usage_percent = @as(f32, @floatFromInt(self.cpu_usage_percent.load(.monotonic))) / 100.0,
            .thread_count = self.thread_count.load(.monotonic),
            .avg_message_processing_time_ns = self.avg_message_processing_time_ns.load(.monotonic),
            .max_message_processing_time_ns = self.max_message_processing_time_ns.load(.monotonic),
            .throughput_messages_per_second = self.throughput_messages_per_second.load(.monotonic),
        };
    }

    pub fn reset(self: *SystemStats) void {
        self.start_time = std.time.milliTimestamp();
        self.uptime_ms.store(0, .monotonic);
        self.total_actors.store(0, .monotonic);
        self.active_actors.store(0, .monotonic);
        self.failed_actors.store(0, .monotonic);
        self.restarted_actors.store(0, .monotonic);
        self.messages_sent.store(0, .monotonic);
        self.messages_processed.store(0, .monotonic);
        self.messages_failed.store(0, .monotonic);
        self.messages_dropped.store(0, .monotonic);
        self.memory_usage_bytes.store(0, .monotonic);
        self.cpu_usage_percent.store(0, .monotonic);
        self.thread_count.store(0, .monotonic);
        self.avg_message_processing_time_ns.store(0, .monotonic);
        self.max_message_processing_time_ns.store(0, .monotonic);
        self.throughput_messages_per_second.store(0, .monotonic);
    }

    pub fn print(self: *const SystemStats) void {
        const uptime = self.uptime_ms.load(.monotonic);
        const total_actors = self.total_actors.load(.monotonic);
        const active_actors = self.active_actors.load(.monotonic);
        const messages_sent = self.messages_sent.load(.monotonic);
        const messages_processed = self.messages_processed.load(.monotonic);
        const memory_usage = self.memory_usage_bytes.load(.monotonic);
        const cpu_usage = self.cpu_usage_percent.load(.monotonic);

        std.log.info("System Stats:", .{});
        std.log.info("  Uptime: {}ms", .{uptime});
        std.log.info("  Actors: {}/{} (active/total)", .{ active_actors, total_actors });
        std.log.info("  Messages: {}/{} (processed/sent)", .{ messages_processed, messages_sent });
        std.log.info("  Memory: {} bytes", .{memory_usage});
        std.log.info("  CPU: {}.{}%", .{ cpu_usage / 100, cpu_usage % 100 });
    }
};

// 系统统计快照
pub const SystemStatsSnapshot = struct {
    uptime_ms: u64,
    total_actors: u32,
    active_actors: u32,
    failed_actors: u32,
    restarted_actors: u32,
    messages_sent: u64,
    messages_processed: u64,
    messages_failed: u64,
    messages_dropped: u64,
    memory_usage_bytes: u64,
    cpu_usage_percent: f32,
    thread_count: u32,
    avg_message_processing_time_ns: u64,
    max_message_processing_time_ns: u64,
    throughput_messages_per_second: u64,

    pub fn format(self: SystemStatsSnapshot, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print(
            "SystemStats{{ uptime: {}ms, actors: {}/{}, messages: {}/{}/{}/{}, " ++
                "memory: {}MB, cpu: {d:.1}%, threads: {}, " ++
                "avg_processing: {}ns, max_processing: {}ns, throughput: {}/s }}",
            .{
                self.uptime_ms,
                self.active_actors,
                self.total_actors,
                self.messages_processed,
                self.messages_sent,
                self.messages_failed,
                self.messages_dropped,
                self.memory_usage_bytes / (1024 * 1024),
                self.cpu_usage_percent,
                self.thread_count,
                self.avg_message_processing_time_ns,
                self.max_message_processing_time_ns,
                self.throughput_messages_per_second,
            },
        );
    }
};

// 测试
test "SystemState operations" {
    const testing = std.testing;

    try testing.expect(SystemState.running.isRunning());
    try testing.expect(!SystemState.stopped.isRunning());

    try testing.expect(SystemState.running.canAcceptActors());
    try testing.expect(SystemState.starting.canAcceptActors());
    try testing.expect(!SystemState.stopped.canAcceptActors());

    try testing.expect(SystemState.stopping.isShuttingDown());
    try testing.expect(SystemState.stopped.isShuttingDown());
    try testing.expect(!SystemState.running.isShuttingDown());
}

test "SystemConfiguration presets" {
    const testing = std.testing;

    const dev_config = SystemConfiguration.development();
    try testing.expectEqualStrings(dev_config.name, "zactor-dev");
    try testing.expect(dev_config.enable_debug_logging);
    try testing.expect(dev_config.log_level == .debug);

    const prod_config = SystemConfiguration.production();
    try testing.expectEqualStrings(prod_config.name, "zactor-prod");
    try testing.expect(!prod_config.enable_debug_logging);
    try testing.expect(prod_config.log_level == .info);

    const cluster_config = SystemConfiguration.cluster();
    try testing.expect(cluster_config.enable_clustering);
    try testing.expect(cluster_config.enable_remoting);
    try testing.expect(cluster_config.enable_security);
}

test "SystemStats operations" {
    const testing = std.testing;

    var stats = SystemStats.init();

    stats.recordActorCreated();
    try testing.expect(stats.total_actors.load(.monotonic) == 1);
    try testing.expect(stats.active_actors.load(.monotonic) == 1);

    stats.recordMessageProcessed(1000);
    try testing.expect(stats.messages_processed.load(.monotonic) == 1);
    try testing.expect(stats.avg_message_processing_time_ns.load(.monotonic) == 1000);

    stats.recordMessageProcessed(2000);
    const avg = stats.avg_message_processing_time_ns.load(.monotonic);
    try testing.expect(avg > 1000 and avg < 2000); // 应该是移动平均

    const snapshot = stats.getSnapshot();
    try testing.expect(snapshot.total_actors == 1);
    try testing.expect(snapshot.messages_processed == 2);
}
