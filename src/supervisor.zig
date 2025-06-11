const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zactor = @import("zactor.zig");
const Actor = @import("actor.zig").Actor;
const ActorRef = @import("actor_ref.zig").ActorRef;
const Message = @import("message.zig").Message;
const SystemMessage = @import("message.zig").SystemMessage;

// Supervision strategies for handling actor failures
pub const SupervisorStrategy = enum {
    // Restart the failed actor
    restart,
    // Stop the failed actor
    stop,
    // Restart all child actors
    restart_all,
    // Stop all child actors
    stop_all,
    // Escalate to parent supervisor
    escalate,
};

// Supervisor configuration
pub const SupervisorConfig = struct {
    strategy: SupervisorStrategy = .restart,
    max_restarts: u32 = 3,
    restart_window_seconds: u32 = 60,
    backoff_initial_ms: u32 = 100,
    backoff_max_ms: u32 = 5000,
    backoff_multiplier: f32 = 2.0,
};

// Child actor information for supervision
const ChildInfo = struct {
    actor_ref: ActorRef,
    restart_count: u32,
    last_restart_time: i64,
    backoff_delay_ms: u32,

    pub fn init(actor_ref: ActorRef) ChildInfo {
        return ChildInfo{
            .actor_ref = actor_ref,
            .restart_count = 0,
            .last_restart_time = 0,
            .backoff_delay_ms = 0,
        };
    }

    pub fn shouldRestart(self: *ChildInfo, config: SupervisorConfig) bool {
        const now = std.time.milliTimestamp();
        const window_ms = config.restart_window_seconds * 1000;

        // Reset restart count if outside the window
        if (now - self.last_restart_time > window_ms) {
            self.restart_count = 0;
        }

        return self.restart_count < config.max_restarts;
    }

    pub fn recordRestart(self: *ChildInfo, config: SupervisorConfig) void {
        const now = std.time.milliTimestamp();
        self.restart_count += 1;
        self.last_restart_time = now;

        // Calculate exponential backoff delay
        if (self.backoff_delay_ms == 0) {
            self.backoff_delay_ms = config.backoff_initial_ms;
        } else {
            const new_delay = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.backoff_delay_ms)) * config.backoff_multiplier));
            self.backoff_delay_ms = @min(new_delay, config.backoff_max_ms);
        }
    }
};

// Supervisor actor that manages child actors
pub const Supervisor = struct {
    const Self = @This();

    config: SupervisorConfig,
    children: std.AutoHashMap(zactor.ActorId, ChildInfo),
    parent: ?*Supervisor,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: SupervisorConfig) Self {
        return Self{
            .config = config,
            .children = std.AutoHashMap(zactor.ActorId, ChildInfo).init(allocator),
            .parent = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit();
    }

    // Add a child actor to supervision
    pub fn addChild(self: *Self, actor_ref: ActorRef) !void {
        const child_info = ChildInfo.init(actor_ref);
        try self.children.put(actor_ref.id, child_info);

        std.log.info("Supervisor: Added child actor {} to supervision", .{actor_ref.id});
    }

    // Remove a child actor from supervision
    pub fn removeChild(self: *Self, actor_id: zactor.ActorId) void {
        _ = self.children.remove(actor_id);
        std.log.info("Supervisor: Removed child actor {} from supervision", .{actor_id});
    }

    // Handle actor failure
    pub fn handleFailure(self: *Self, actor_id: zactor.ActorId, error_info: anyerror) !void {
        const child_info = self.children.getPtr(actor_id) orelse {
            std.log.warn("Supervisor: Received failure for unknown child actor {}", .{actor_id});
            return;
        };

        std.log.warn("Supervisor: Child actor {} failed with error: {}", .{ actor_id, error_info });

        switch (self.config.strategy) {
            .restart => try self.restartChild(child_info),
            .stop => try self.stopChild(child_info),
            .restart_all => try self.restartAllChildren(),
            .stop_all => try self.stopAllChildren(),
            .escalate => try self.escalateFailure(actor_id, error_info),
        }
    }

    // Restart a specific child actor
    fn restartChild(self: *Self, child_info: *ChildInfo) !void {
        if (!child_info.shouldRestart(self.config)) {
            std.log.err("Supervisor: Child actor {} exceeded restart limit, stopping", .{child_info.actor_ref.id});
            try self.stopChild(child_info);
            return;
        }

        child_info.recordRestart(self.config);

        // Apply backoff delay
        if (child_info.backoff_delay_ms > 0) {
            std.log.info("Supervisor: Applying backoff delay of {}ms before restart", .{child_info.backoff_delay_ms});
            std.time.sleep(child_info.backoff_delay_ms * std.time.ns_per_ms);
        }

        // Send restart message to the actor
        try child_info.actor_ref.sendSystem(.restart);

        std.log.info("Supervisor: Restarted child actor {} (restart #{}/{})", .{
            child_info.actor_ref.id,
            child_info.restart_count,
            self.config.max_restarts,
        });
    }

    // Stop a specific child actor
    fn stopChild(self: *Self, child_info: *ChildInfo) !void {
        try child_info.actor_ref.sendSystem(.stop);
        self.removeChild(child_info.actor_ref.id);

        std.log.info("Supervisor: Stopped child actor {}", .{child_info.actor_ref.id});
    }

    // Restart all child actors
    fn restartAllChildren(self: *Self) !void {
        std.log.info("Supervisor: Restarting all {} child actors", .{self.children.count()});

        var iterator = self.children.iterator();
        while (iterator.next()) |entry| {
            try self.restartChild(entry.value_ptr);
        }
    }

    // Stop all child actors
    fn stopAllChildren(self: *Self) !void {
        std.log.info("Supervisor: Stopping all {} child actors", .{self.children.count()});

        var iterator = self.children.iterator();
        while (iterator.next()) |entry| {
            try self.stopChild(entry.value_ptr);
        }
    }

    // Escalate failure to parent supervisor
    fn escalateFailure(self: *Self, actor_id: zactor.ActorId, error_info: anyerror) !void {
        if (self.parent) |parent| {
            std.log.info("Supervisor: Escalating failure of actor {} to parent supervisor", .{actor_id});
            try parent.handleFailure(actor_id, error_info);
        } else {
            std.log.err("Supervisor: No parent to escalate failure to, stopping child actor {}", .{actor_id});
            if (self.children.getPtr(actor_id)) |child_info| {
                try self.stopChild(child_info);
            }
        }
    }

    // Get supervision statistics
    pub fn getStats(self: *Self) SupervisorStats {
        var total_restarts: u32 = 0;
        var active_children: u32 = 0;

        var iterator = self.children.iterator();
        while (iterator.next()) |entry| {
            total_restarts += entry.value_ptr.restart_count;
            if (entry.value_ptr.actor_ref.getState() == .running) {
                active_children += 1;
            }
        }

        return SupervisorStats{
            .total_children = @intCast(self.children.count()),
            .active_children = active_children,
            .total_restarts = total_restarts,
            .strategy = self.config.strategy,
        };
    }
};

// Supervisor statistics
pub const SupervisorStats = struct {
    total_children: u32,
    active_children: u32,
    total_restarts: u32,
    strategy: SupervisorStrategy,

    pub fn print(self: SupervisorStats) void {
        std.log.info("Supervisor Stats:", .{});
        std.log.info("  Total Children: {}", .{self.total_children});
        std.log.info("  Active Children: {}", .{self.active_children});
        std.log.info("  Total Restarts: {}", .{self.total_restarts});
        std.log.info("  Strategy: {}", .{self.strategy});
    }
};

// Tests
test "supervisor basic functionality" {
    const allocator = testing.allocator;

    var supervisor = Supervisor.init(allocator, .{
        .strategy = .restart,
        .max_restarts = 3,
    });
    defer supervisor.deinit();

    // Test stats
    const stats = supervisor.getStats();
    try testing.expect(stats.total_children == 0);
    try testing.expect(stats.active_children == 0);
    try testing.expect(stats.total_restarts == 0);
}

test "child info restart logic" {
    var child_info = ChildInfo.init(ActorRef{
        .id = 1,
        .mailbox = undefined,
        .state = undefined,
    });

    const config = SupervisorConfig{
        .max_restarts = 2,
        .restart_window_seconds = 60,
        .backoff_initial_ms = 100,
        .backoff_max_ms = 1000,
        .backoff_multiplier = 2.0,
    };

    // Should allow restarts initially
    try testing.expect(child_info.shouldRestart(config));

    // Record restarts
    child_info.recordRestart(config);
    try testing.expect(child_info.restart_count == 1);
    try testing.expect(child_info.backoff_delay_ms == 100);

    child_info.recordRestart(config);
    try testing.expect(child_info.restart_count == 2);
    try testing.expect(child_info.backoff_delay_ms == 200);

    // Should not allow more restarts after limit
    try testing.expect(!child_info.shouldRestart(config));
}
