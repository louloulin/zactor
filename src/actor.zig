const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zactor = @import("zactor.zig");
const Message = @import("message.zig").Message;
const SystemMessage = @import("message.zig").SystemMessage;
const ControlMessage = @import("message.zig").ControlMessage;
const Mailbox = @import("mailbox.zig").Mailbox;
const ActorRef = @import("actor_ref.zig").ActorRef;

// Actor context provides the execution environment for an actor
pub const ActorContext = struct {
    const Self = @This();

    self_ref: ActorRef,
    allocator: Allocator,
    system: *ActorSystem,

    const ActorSystem = @import("actor_system.zig").ActorSystem;

    pub fn init(self_ref: ActorRef, allocator: Allocator, system: *ActorSystem) Self {
        return Self{
            .self_ref = self_ref,
            .allocator = allocator,
            .system = system,
        };
    }

    // Send a message to another actor
    pub fn send(self: *Self, target: ActorRef, comptime T: type, data: T) !void {
        try target.send(T, data, self.allocator);
    }

    // Send a system message
    pub fn sendSystem(self: *Self, target: ActorRef, msg: SystemMessage) !void {
        _ = self;
        try target.sendSystem(msg);
    }

    // Spawn a new actor
    pub fn spawn(self: *Self, comptime ActorType: type, init_data: anytype) !ActorRef {
        return try self.system.spawn(ActorType, init_data);
    }

    // Stop self
    pub fn stop(self: *Self) !void {
        try self.self_ref.stop();
    }

    // Get self reference
    pub fn getSelf(self: *Self) ActorRef {
        return self.self_ref;
    }
};

// Actor behavior trait - actors must implement this interface
pub fn ActorBehavior(comptime T: type) type {
    return struct {
        // Called when actor receives a message
        pub fn receive(self: *T, message: Message, context: *ActorContext) !void {
            _ = self;
            _ = message;
            _ = context;
            // Default implementation - override in actor implementations
        }

        // Called when actor starts
        pub fn preStart(self: *T, context: *ActorContext) !void {
            _ = self;
            _ = context;
            // Default implementation - override if needed
        }

        // Called when actor stops
        pub fn postStop(self: *T, context: *ActorContext) !void {
            _ = self;
            _ = context;
            // Default implementation - override if needed
        }

        // Called when actor restarts
        pub fn preRestart(self: *T, context: *ActorContext, reason: anyerror) !void {
            _ = self;
            _ = context;
            _ = reason;
            // Default implementation - override if needed
        }

        // Called after actor restarts
        pub fn postRestart(self: *T, context: *ActorContext) !void {
            _ = self;
            _ = context;
            // Default implementation - override if needed
        }
    };
}

// Core Actor implementation
pub const Actor = struct {
    const Self = @This();

    id: zactor.ActorId,
    state: std.atomic.Value(zactor.ActorState),
    mailbox: Mailbox,
    context: ActorContext,
    behavior: *anyopaque, // Type-erased actor behavior
    behavior_vtable: *const BehaviorVTable,
    allocator: Allocator,

    const BehaviorVTable = struct {
        receive: *const fn (behavior: *anyopaque, message: Message, context: *ActorContext) anyerror!void,
        preStart: *const fn (behavior: *anyopaque, context: *ActorContext) anyerror!void,
        postStop: *const fn (behavior: *anyopaque, context: *ActorContext) anyerror!void,
        preRestart: *const fn (behavior: *anyopaque, context: *ActorContext, reason: anyerror) anyerror!void,
        postRestart: *const fn (behavior: *anyopaque, context: *ActorContext) anyerror!void,
        deinit: *const fn (behavior: *anyopaque, allocator: Allocator) void,
    };

    pub fn init(comptime BehaviorType: type, behavior_data: BehaviorType, id: zactor.ActorId, allocator: Allocator, system: *ActorContext.ActorSystem) !Self {
        // Create behavior instance
        const behavior = try allocator.create(BehaviorType);
        behavior.* = behavior_data;

        // Create mailbox
        const mailbox = try allocator.create(Mailbox);
        mailbox.* = try Mailbox.init(allocator);

        // Create actor state
        const state = try allocator.create(std.atomic.Value(zactor.ActorState));
        state.* = std.atomic.Value(zactor.ActorState).init(.created);

        // Create a temporary actor reference without actor pointer
        const temp_actor_ref = ActorRef.init(id, mailbox, state, system, null);

        // Create context
        const context = ActorContext.init(temp_actor_ref, allocator, system);

        // Create vtable
        const vtable = &BehaviorVTable{
            .receive = struct {
                fn receive(behavior_ptr: *anyopaque, message: Message, ctx: *ActorContext) anyerror!void {
                    const typed_behavior: *BehaviorType = @ptrCast(@alignCast(behavior_ptr));
                    return typed_behavior.receive(message, ctx);
                }
            }.receive,
            .preStart = struct {
                fn preStart(behavior_ptr: *anyopaque, ctx: *ActorContext) anyerror!void {
                    const typed_behavior: *BehaviorType = @ptrCast(@alignCast(behavior_ptr));
                    return typed_behavior.preStart(ctx);
                }
            }.preStart,
            .postStop = struct {
                fn postStop(behavior_ptr: *anyopaque, ctx: *ActorContext) anyerror!void {
                    const typed_behavior: *BehaviorType = @ptrCast(@alignCast(behavior_ptr));
                    return typed_behavior.postStop(ctx);
                }
            }.postStop,
            .preRestart = struct {
                fn preRestart(behavior_ptr: *anyopaque, ctx: *ActorContext, reason: anyerror) anyerror!void {
                    const typed_behavior: *BehaviorType = @ptrCast(@alignCast(behavior_ptr));
                    return typed_behavior.preRestart(ctx, reason);
                }
            }.preRestart,
            .postRestart = struct {
                fn postRestart(behavior_ptr: *anyopaque, ctx: *ActorContext) anyerror!void {
                    const typed_behavior: *BehaviorType = @ptrCast(@alignCast(behavior_ptr));
                    return typed_behavior.postRestart(ctx);
                }
            }.postRestart,
            .deinit = struct {
                fn deinit(behavior_ptr: *anyopaque, alloc: Allocator) void {
                    const typed_behavior: *BehaviorType = @ptrCast(@alignCast(behavior_ptr));
                    alloc.destroy(typed_behavior);
                }
            }.deinit,
        };

        return Self{
            .id = id,
            .state = state.*,
            .mailbox = mailbox.*,
            .context = context,
            .behavior = behavior,
            .behavior_vtable = vtable,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.behavior_vtable.deinit(self.behavior, self.allocator);
        self.mailbox.deinit();
        // Note: mailbox and state are now owned by the actor struct
    }

    // Start the actor
    pub fn start(self: *Self) !void {
        self.state.store(.running, .release);
        try self.behavior_vtable.preStart(self.behavior, &self.context);
        zactor.metrics.incrementActorsCreated();
    }

    // Stop the actor
    pub fn stop(self: *Self) !void {
        const old_state = self.state.swap(.stopped, .acq_rel);
        if (old_state != .stopped and old_state != .failed) {
            try self.behavior_vtable.postStop(self.behavior, &self.context);
            zactor.metrics.incrementActorsDestroyed();
        }
    }

    // Process one message from the mailbox
    pub fn processMessage(self: *Self) !bool {
        if (self.state.load(.acquire) != .running) {
            return false;
        }

        if (self.mailbox.receive()) |message| {
            defer message.deinit(self.allocator);

            // Handle system messages
            if (message.isSystem()) {
                try self.handleSystemMessage(message.data.system);
            } else if (message.isControl()) {
                try self.handleControlMessage(message.data.control);
            } else {
                // User message - delegate to behavior
                try self.behavior_vtable.receive(self.behavior, message, &self.context);
            }

            zactor.metrics.incrementMessagesReceived();
            return true;
        }

        return false;
    }

    fn handleSystemMessage(self: *Self, msg: SystemMessage) !void {
        switch (msg) {
            .start => try self.start(),
            .stop => try self.stop(),
            .restart => try self.restart(),
            .ping => {
                // Send pong back to sender
                const pong = Message.createSystem(.pong, self.id);
                try self.mailbox.send(pong);
            },
            .pong => {
                // Handle pong response - could be used for health checks
            },
            .supervise => {
                // Handle supervision message
            },
        }
    }

    fn handleControlMessage(self: *Self, msg: ControlMessage) !void {
        switch (msg) {
            .shutdown => try self.stop(),
            .suspend_actor => self.state.store(.suspended, .release),
            .resume_actor => self.state.store(.running, .release),
            .status_request => {
                // Could send status response
            },
        }
    }

    fn restart(self: *Self) !void {
        _ = self.state.swap(.created, .acq_rel);
        try self.behavior_vtable.preRestart(self.behavior, &self.context, error.ActorRestart);
        try self.start();
        try self.behavior_vtable.postRestart(self.behavior, &self.context);
    }

    pub fn getRef(self: *Self) ActorRef {
        var actor_ref = self.context.self_ref;
        actor_ref.setActorPtr(@ptrCast(self));
        return actor_ref;
    }

    pub fn getState(self: *Self) zactor.ActorState {
        return self.state.load(.acquire);
    }

    pub fn getId(self: *Self) zactor.ActorId {
        return self.id;
    }
};

// Example actor implementation
pub const EchoActor = struct {
    const Self = @This();

    name: []const u8,

    pub fn init(name: []const u8) Self {
        return Self{ .name = name };
    }

    pub fn receive(self: *Self, message: Message, context: *ActorContext) !void {
        _ = context;
        if (message.isUser()) {
            std.log.info("EchoActor '{s}' received message", .{self.name});
            // Echo the message back to sender if there is one
            if (message.sender) |sender_id| {
                // In a real implementation, we'd look up the sender and echo back
                _ = sender_id;
            }
        }
    }

    pub fn preStart(self: *Self, context: *ActorContext) !void {
        _ = context;
        std.log.info("EchoActor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *ActorContext) !void {
        _ = context;
        std.log.info("EchoActor '{s}' stopping", .{self.name});
    }

    pub fn preRestart(self: *Self, context: *ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("EchoActor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self, context: *ActorContext) !void {
        _ = context;
        std.log.info("EchoActor '{s}' restarted", .{self.name});
    }
};

test "actor creation and lifecycle" {
    const allocator = testing.allocator;

    // Mock actor system
    const MockActorSystem = struct {
        pub fn spawn(self: *@This(), comptime T: type, data: anytype) !ActorRef {
            _ = self;
            _ = T;
            _ = data;
            return error.NotImplemented;
        }
    };

    var mock_system = MockActorSystem{};

    const echo_behavior = EchoActor.init("test");
    var actor = try Actor.init(EchoActor, echo_behavior, 123, allocator, @ptrCast(&mock_system));
    defer actor.deinit();

    try testing.expect(actor.getId() == 123);
    try testing.expect(actor.getState() == .created);

    // Start the actor
    try actor.start();
    try testing.expect(actor.getState() == .running);

    // Send a system message
    const ping_msg = Message.createSystem(.ping, null);
    try actor.mailbox.send(ping_msg);

    // Process the message
    const processed = try actor.processMessage();
    try testing.expect(processed);

    // Stop the actor
    try actor.stop();
    try testing.expect(actor.getState() == .stopped);
}
