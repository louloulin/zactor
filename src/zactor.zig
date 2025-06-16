//! ZActor - High-Performance Actor System for Zig
//! 高性能Zig Actor系统
//!
//! ZActor provides a robust, high-performance actor model implementation
//! designed for concurrent and distributed systems.
//!
//! Features:
//! - Lock-free message passing
//! - Work-stealing scheduler
//! - Supervision hierarchies
//! - Location transparency
//! - Fault tolerance
//! - High throughput and low latency
//! - Modular architecture
//! - Dynamic mailbox configuration

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

// Core module exports
pub const core = struct {
    pub usingnamespace @import("core/mod.zig");
};

// Utility module exports
pub const utils = struct {
    pub usingnamespace @import("utils/mod.zig");
};

// Re-export main components for backward compatibility
pub const Actor = core.actor.Actor;
pub const ActorContext = core.actor.ActorContext;
pub const ActorSystem = core.actor.ActorSystem;
pub const Message = core.message.Message;
pub const SystemMessage = core.message.SystemMessage;
pub const ControlMessage = core.message.ControlMessage;
pub const Mailbox = core.mailbox.Mailbox;
pub const ActorRef = core.actor.ActorRef;
pub const Scheduler = core.scheduler.Scheduler;
pub const Supervisor = core.actor.Supervisor;
pub const SupervisorStrategy = core.actor.SupervisorStrategy;
pub const SupervisorConfig = core.actor.SupervisorConfig;

// Re-export high-performance components
pub const messaging = core.messaging;
pub const message = core.message;
pub const scheduler = core.scheduler;
pub const memory = core.memory;

// Core types
pub const ActorId = u64;
pub const MessageId = u64;

// Re-export core errors
pub const ActorError = core.actor.ActorError;
pub const SystemError = core.system.SystemError;
pub const MessageError = core.message.MessageError;
pub const MailboxError = core.mailbox.MailboxError;
pub const SchedulerError = core.scheduler.SchedulerError;
pub const UtilsError = utils.UtilsError;

// Re-export core states
pub const ActorState = core.actor.ActorState;
pub const SystemState = core.system.SystemState;

// Test to ensure the module compiles
test "zactor module compilation" {
    // This test ensures the module structure is correct
    const allocator = testing.allocator;
    _ = allocator;

    // Basic type checks
    const actor_id: ActorId = 1;
    const message_id: MessageId = 1;
    _ = actor_id;
    _ = message_id;

    const state = ActorState.created;
    try testing.expect(state == ActorState.created);
}

// Re-export configuration types
pub const Config = core.system.SystemConfiguration;
pub const ActorConfig = core.actor.ActorConfig;
pub const MailboxConfig = core.mailbox.MailboxConfig;
pub const SchedulerConfig = core.scheduler.SchedulerConfig;
pub const UtilsConfig = utils.UtilsConfig;

// Global configuration instance
pub var config: Config = Config.default();

// Initialize ZActor with custom configuration
pub fn configure(cfg: Config) void {
    config = cfg;
}

// Re-export statistics types
pub const SystemStats = core.system.SystemStats;
pub const ActorStats = core.actor.ActorStats;
pub const MailboxStats = core.mailbox.MailboxStats;
pub const SchedulerStats = core.scheduler.SchedulerStats;
pub const UtilsStats = utils.UtilsStats;

// Unified metrics interface
pub const Metrics = struct {
    system_stats: SystemStats,
    utils_stats: UtilsStats,

    pub fn init() Metrics {
        return Metrics{
            .system_stats = SystemStats.init(),
            .utils_stats = UtilsStats.init(),
        };
    }

    pub fn reset(self: *Metrics) void {
        self.system_stats.reset();
        self.utils_stats.reset();
    }

    pub fn print(self: *const Metrics) void {
        std.log.info("ZActor Unified Metrics:", .{});
        self.system_stats.print();
        self.utils_stats.print();
    }

    pub fn getMessagesReceived(self: *const Metrics) u64 {
        return self.system_stats.messages_processed.load(.monotonic);
    }

    pub fn getMessagesSent(self: *const Metrics) u64 {
        return self.system_stats.messages_sent.load(.monotonic);
    }
};

// Global metrics instance
pub var metrics: Metrics = undefined;

// 初始化函数
pub fn init(cfg: Config) void {
    metrics = Metrics.init();
    metrics.system_stats.start_time = std.time.milliTimestamp();
    _ = cfg; // 暂时未使用
}

test "unified metrics functionality" {
    var test_metrics = Metrics.init();

    // Test basic functionality
    test_metrics.reset();

    // Verify metrics can be printed without error
    test_metrics.print();
}

test "core module integration" {
    // Test that all core modules are accessible
    const allocator = testing.allocator;
    _ = allocator;

    // Test type accessibility
    const actor_state = ActorState.created;
    const system_state = SystemState.stopped;
    _ = actor_state;
    _ = system_state;

    // Test configuration
    const cfg = Config.development();
    _ = cfg;
}
