//! Core Module - 核心模块
//! ZActor框架的核心功能模块，包括Actor、消息、调度器和系统管理

const std = @import("std");
const Allocator = std.mem.Allocator;

// 重新导出核心子模块
pub const actor = @import("actor/mod.zig");
pub const message = @import("message/mod.zig");
pub const scheduler = @import("scheduler/mod.zig");
pub const system = @import("system/mod.zig");

// 重新导出常用类型以便于访问
// Actor相关
pub const Actor = actor.Actor;
pub const ActorRef = actor.ActorRef;
pub const ActorContext = actor.ActorContext;
pub const ActorSystem = actor.ActorSystem;
pub const ActorBehavior = actor.ActorBehavior;
pub const ActorState = actor.ActorState;
pub const ActorLifecycle = actor.ActorLifecycle;
pub const ActorConfig = actor.ActorConfig;
pub const ActorStats = actor.ActorStats;
pub const ActorFactory = actor.ActorFactory;
pub const ActorPath = actor.ActorPath;
pub const ActorSelection = actor.ActorSelection;
pub const ActorError = actor.ActorError;

// 消息相关
pub const Message = message.Message;
pub const MessageType = message.MessageType;
pub const MessagePriority = message.MessagePriority;
pub const MessageBuilder = message.MessageBuilder;
pub const MessagePool = message.MessagePool;
pub const MessageSerializer = message.MessageSerializer;
pub const UserMessage = message.UserMessage;
pub const SystemMessage = message.SystemMessage;
pub const MessageError = message.MessageError;

// 调度器相关
pub const Scheduler = scheduler.Scheduler;
pub const WorkStealingScheduler = scheduler.WorkStealingScheduler;
pub const ThreadPoolScheduler = scheduler.ThreadPoolScheduler;
pub const FiberScheduler = scheduler.FiberScheduler;
pub const Dispatcher = scheduler.Dispatcher;
pub const TaskQueue = scheduler.TaskQueue;
pub const SchedulerConfig = scheduler.SchedulerConfig;
pub const SchedulerStats = scheduler.SchedulerStats;
pub const SchedulerFactory = scheduler.SchedulerFactory;
pub const SchedulerError = scheduler.SchedulerError;

// 系统相关
pub const SystemGuardian = system.SystemGuardian;
pub const SystemRegistry = system.SystemRegistry;
pub const SystemMonitor = system.SystemMonitor;
pub const SystemConfig = system.SystemConfig;
pub const SystemMetrics = system.SystemMetrics;
pub const SystemShutdown = system.SystemShutdown;
pub const SystemConfiguration = system.SystemConfiguration;
pub const SystemComponent = system.SystemComponent;
pub const SystemStats = system.SystemStats;
pub const SystemError = system.SystemError;

// 保持向后兼容的导出
pub const Mailbox = @import("mailbox/mod.zig").Mailbox;
pub const MailboxConfig = @import("mailbox/mod.zig").MailboxConfig;
pub const MailboxType = @import("mailbox/mod.zig").MailboxType;
pub const Supervisor = @import("supervisor/mod.zig").Supervisor;
pub const SupervisorStrategy = @import("supervisor/mod.zig").SupervisorStrategy;
pub const SupervisorConfig = @import("supervisor/mod.zig").SupervisorConfig;
pub const EventScheduler = scheduler.Scheduler; // 别名
pub const ControlMessage = SystemMessage; // 别名

// Core types
pub const ActorId = u64;
pub const MessageId = u64;

// 核心模块错误
pub const CoreError = error{
    InitializationFailed,
    InvalidConfiguration,
    ComponentNotFound,
    OperationFailed,
    ResourceExhausted,
    SystemShuttingDown,
    ActorNotFound,
    MailboxFull,
    SystemShutdown,
    InvalidMessage,
    OutOfMemory,
    ActorFailed,
    SupervisorError,
};

// 核心模块配置
pub const CoreConfig = struct {
    actor_config: ActorConfig = ActorConfig.default(),
    scheduler_config: SchedulerConfig = SchedulerConfig.default(),
    system_config: SystemConfiguration = SystemConfiguration.development(),
    message_config: message.MessageModuleConfig = message.MessageModuleConfig.default(),
    enable_monitoring: bool = true,
    enable_metrics: bool = true,
    enable_debugging: bool = false,
    max_actors: usize = 10000,
    max_messages_per_actor: usize = 1000,
    
    pub fn default() CoreConfig {
        return CoreConfig{};
    }
    
    pub fn development() CoreConfig {
        return CoreConfig{
            .actor_config = ActorConfig.development(),
            .scheduler_config = SchedulerConfig.development(),
            .system_config = SystemConfiguration.development(),
            .message_config = message.MessageModuleConfig.development(),
            .enable_debugging = true,
            .max_actors = 1000,
        };
    }
    
    pub fn production() CoreConfig {
        return CoreConfig{
            .actor_config = ActorConfig.production(),
            .scheduler_config = SchedulerConfig.production(),
            .system_config = SystemConfiguration.production(),
            .message_config = message.MessageModuleConfig.production(),
            .enable_debugging = false,
            .max_actors = 100000,
            .max_messages_per_actor = 10000,
        };
    }
    
    pub fn cluster() CoreConfig {
        return CoreConfig{
            .actor_config = ActorConfig.cluster(),
            .scheduler_config = SchedulerConfig.cluster(),
            .system_config = SystemConfiguration.cluster(),
            .message_config = message.MessageModuleConfig.production(),
            .enable_monitoring = true,
            .enable_metrics = true,
            .max_actors = 1000000,
            .max_messages_per_actor = 50000,
        };
    }
};

// Performance configuration (保持向后兼容)
pub const Config = struct {
    max_actors: u32 = 10000,
    mailbox_capacity: u32 = 1000,
    scheduler_threads: u32 = 0, // 0 = auto-detect
    enable_work_stealing: bool = true,
    enable_numa_awareness: bool = false,
    message_pool_size: u32 = 10000,
    mailbox_type: MailboxType = .standard,
};

// Global configuration instance
pub var config: Config = Config{};

// Initialize ZActor with custom configuration
pub fn init(cfg: Config) void {
    config = cfg;
}

// Utility functions for performance measurement
pub const Metrics = struct {
    messages_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    actors_created: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    actors_destroyed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    actor_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn incrementMessagesSent(self: *Metrics) void {
        _ = self.messages_sent.fetchAdd(1, .monotonic);
    }

    pub fn incrementMessagesReceived(self: *Metrics) void {
        _ = self.messages_received.fetchAdd(1, .monotonic);
    }

    pub fn incrementActorsCreated(self: *Metrics) void {
        _ = self.actors_created.fetchAdd(1, .monotonic);
    }

    pub fn incrementActorsDestroyed(self: *Metrics) void {
        _ = self.actors_destroyed.fetchAdd(1, .monotonic);
    }

    pub fn incrementActorFailures(self: *Metrics) void {
        _ = self.actor_failures.fetchAdd(1, .monotonic);
    }

    pub fn getMessagesSent(self: *const Metrics) u64 {
        return self.messages_sent.load(.monotonic);
    }

    pub fn getMessagesReceived(self: *const Metrics) u64 {
        return self.messages_received.load(.monotonic);
    }

    pub fn getActorsCreated(self: *const Metrics) u64 {
        return self.actors_created.load(.monotonic);
    }

    pub fn getActorsDestroyed(self: *const Metrics) u64 {
        return self.actors_destroyed.load(.monotonic);
    }

    pub fn getActorFailures(self: *const Metrics) u64 {
        return self.actor_failures.load(.monotonic);
    }

    pub fn reset(self: *Metrics) void {
        self.messages_sent.store(0, .monotonic);
        self.messages_received.store(0, .monotonic);
        self.actors_created.store(0, .monotonic);
        self.actors_destroyed.store(0, .monotonic);
        self.actor_failures.store(0, .monotonic);
    }
};

// Global metrics instance
pub var metrics: Metrics = Metrics{};

// Convenience functions
pub fn incrementMessagesSent() void {
    metrics.incrementMessagesSent();
}

pub fn incrementMessagesReceived() void {
    metrics.incrementMessagesReceived();
}

pub fn incrementActorsCreated() void {
    metrics.incrementActorsCreated();
}

pub fn incrementActorsDestroyed() void {
    metrics.incrementActorsDestroyed();
}

pub fn incrementActorFailures() void {
    metrics.incrementActorFailures();
}