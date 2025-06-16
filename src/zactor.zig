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
pub const Actor = @import("actor.zig").Actor;
pub const ActorContext = @import("actor.zig").ActorContext;
pub const ActorSystem = @import("actor_system.zig").ActorSystem;
pub const Message = @import("message.zig").Message;
pub const SystemMessage = @import("message.zig").SystemMessage;
pub const ControlMessage = @import("message.zig").ControlMessage;
pub const Mailbox = @import("mailbox.zig").Mailbox;
pub const ActorRef = @import("actor_ref.zig").ActorRef;
pub const Scheduler = @import("scheduler.zig").Scheduler;
pub const Supervisor = @import("supervisor.zig").Supervisor;
pub const SupervisorStrategy = @import("supervisor.zig").SupervisorStrategy;
pub const SupervisorConfig = @import("supervisor.zig").SupervisorConfig;

// Core types
pub const ActorId = u64;
pub const MessageId = u64;

pub const ActorError = error{
    ActorNotFound,
    MailboxFull,
    SystemShutdown,
    InvalidMessage,
    OutOfMemory,
    ActorFailed,
    SupervisorError,
};

pub const ActorState = enum(u8) {
    created = 0,
    running = 1,
    suspended = 2,
    stopped = 3,
    failed = 4,
};

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

// Performance configuration
pub const Config = struct {
    max_actors: u32 = 10000,
    mailbox_capacity: u32 = 1000,
    scheduler_threads: u32 = 0, // 0 = auto-detect
    enable_work_stealing: bool = true,
    enable_numa_awareness: bool = false,
    message_pool_size: u32 = 10000,
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

    pub fn print(self: *const Metrics) void {
        std.log.info("ZActor Metrics:", .{});
        std.log.info("  Messages Sent: {}", .{self.getMessagesSent()});
        std.log.info("  Messages Received: {}", .{self.getMessagesReceived()});
        std.log.info("  Actors Created: {}", .{self.getActorsCreated()});
        std.log.info("  Actors Destroyed: {}", .{self.getActorsDestroyed()});
        std.log.info("  Actor Failures: {}", .{self.getActorFailures()});
    }
};

// Global metrics instance
pub var metrics: Metrics = Metrics{};

test "metrics functionality" {
    var test_metrics = Metrics{};

    test_metrics.incrementMessagesSent();
    test_metrics.incrementMessagesReceived();
    test_metrics.incrementActorsCreated();

    try testing.expect(test_metrics.getMessagesSent() == 1);
    try testing.expect(test_metrics.getMessagesReceived() == 1);
    try testing.expect(test_metrics.getActorsCreated() == 1);
    try testing.expect(test_metrics.getActorsDestroyed() == 0);

    test_metrics.reset();
    try testing.expect(test_metrics.getMessagesSent() == 0);
}
