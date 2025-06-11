const std = @import("std");
const testing = std.testing;
const zactor = @import("zactor.zig");
const Message = @import("message.zig").Message;
const SystemMessage = @import("message.zig").SystemMessage;
const ControlMessage = @import("message.zig").ControlMessage;
const Mailbox = @import("mailbox.zig").Mailbox;

// ActorRef provides a safe reference to an actor that can be used to send messages
// It handles actor lifecycle and ensures messages are not sent to dead actors
pub const ActorRef = struct {
    const Self = @This();

    id: zactor.ActorId,
    mailbox: *Mailbox,
    state: *std.atomic.Value(zactor.ActorState),
    system_ref: *ActorSystem, // Reference to the actor system
    actor_ptr: ?*anyopaque, // Pointer to the actual Actor

    const ActorSystem = @import("actor_system.zig").ActorSystem;

    pub fn init(id: zactor.ActorId, mailbox: *Mailbox, state: *std.atomic.Value(zactor.ActorState), system: *ActorSystem, actor_ptr: ?*anyopaque) Self {
        return Self{
            .id = id,
            .mailbox = mailbox,
            .state = state,
            .system_ref = system,
            .actor_ptr = actor_ptr,
        };
    }

    // Send a user message to the actor
    pub fn send(self: Self, comptime T: type, data: T, allocator: std.mem.Allocator) !void {
        // Check if actor is still alive
        const current_state = self.state.load(.acquire);
        if (current_state == .stopped or current_state == .failed) {
            return zactor.ActorError.ActorNotFound;
        }

        // Create and send message
        const message = try Message.createUser(T, data, null, allocator);
        try self.mailbox.send(message);

        // Reschedule actor if it's running and we have actor pointer
        if (current_state == .running and self.actor_ptr != null) {
            const Actor = @import("actor.zig").Actor;
            const actor: *Actor = @ptrCast(@alignCast(self.actor_ptr.?));
            std.log.info("Rescheduling actor {} after message send", .{self.id});
            self.system_ref.scheduler.schedule(actor) catch |err| {
                std.log.warn("Failed to reschedule actor {} after message send: {}", .{ self.id, err });
            };
        }

        // Update metrics
        zactor.metrics.incrementMessagesSent();
    }

    // Send a system message to the actor
    pub fn sendSystem(self: Self, msg: SystemMessage) !void {
        const current_state = self.state.load(.acquire);
        if (current_state == .stopped or current_state == .failed) {
            return zactor.ActorError.ActorNotFound;
        }

        const message = Message.createSystem(msg, null);
        try self.mailbox.send(message);

        zactor.metrics.incrementMessagesSent();
    }

    // Send a control message to the actor
    pub fn sendControl(self: Self, msg: ControlMessage) !void {
        const message = Message.createControl(msg, null);
        try self.mailbox.send(message);

        zactor.metrics.incrementMessagesSent();
    }

    // Get the current state of the actor
    pub fn getState(self: Self) zactor.ActorState {
        return self.state.load(.acquire);
    }

    // Check if the actor is alive (not stopped or failed)
    pub fn isAlive(self: Self) bool {
        const state = self.getState();
        return state != .stopped and state != .failed;
    }

    // Stop the actor gracefully
    pub fn stop(self: Self) !void {
        try self.sendSystem(.stop);
    }

    // Restart the actor
    pub fn restart(self: Self) !void {
        try self.sendSystem(.restart);
    }

    // Send a ping message and expect a pong response
    pub fn ping(self: Self) !void {
        try self.sendSystem(.ping);
    }

    // Get actor ID
    pub fn getId(self: Self) zactor.ActorId {
        return self.id;
    }

    // Compare two actor references
    pub fn eql(self: Self, other: Self) bool {
        return self.id == other.id;
    }

    // Hash function for using ActorRef in hash maps
    pub fn hash(self: Self) u64 {
        return std.hash_map.hashInt(self.id);
    }

    // Set the actor pointer (used during actor creation)
    pub fn setActorPtr(self: *Self, actor_ptr: *anyopaque) void {
        self.actor_ptr = actor_ptr;
    }
};

// ActorRefRegistry manages actor references and provides lookup functionality
pub const ActorRefRegistry = struct {
    const Self = @This();

    refs: std.HashMap(zactor.ActorId, ActorRef, std.hash_map.AutoContext(zactor.ActorId), std.hash_map.default_max_load_percentage),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .refs = std.HashMap(zactor.ActorId, ActorRef, std.hash_map.AutoContext(zactor.ActorId), std.hash_map.default_max_load_percentage).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.refs.deinit();
    }

    pub fn register(self: *Self, actor_ref: ActorRef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.refs.put(actor_ref.id, actor_ref);
    }

    pub fn unregister(self: *Self, actor_id: zactor.ActorId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.refs.remove(actor_id);
    }

    pub fn lookup(self: *Self, actor_id: zactor.ActorId) ?ActorRef {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.refs.get(actor_id);
    }

    pub fn count(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return @intCast(self.refs.count());
    }

    pub fn getAllRefs(self: *Self, allocator: std.mem.Allocator) ![]ActorRef {
        self.mutex.lock();
        defer self.mutex.unlock();

        var refs = try allocator.alloc(ActorRef, self.refs.count());
        var i: usize = 0;

        var iterator = self.refs.valueIterator();
        while (iterator.next()) |ref| {
            refs[i] = ref.*;
            i += 1;
        }

        return refs;
    }

    // Broadcast a message to all registered actors
    pub fn broadcast(self: *Self, comptime T: type, data: T, allocator: std.mem.Allocator) !void {
        const refs = try self.getAllRefs(allocator);
        defer allocator.free(refs);

        for (refs) |ref| {
            ref.send(T, data, allocator) catch |err| {
                // Log error but continue broadcasting to other actors
                std.log.warn("Failed to broadcast to actor {}: {}", .{ ref.id, err });
            };
        }
    }

    // Stop all registered actors
    pub fn stopAll(self: *Self, allocator: std.mem.Allocator) !void {
        const refs = try self.getAllRefs(allocator);
        defer allocator.free(refs);

        for (refs) |ref| {
            ref.stop() catch |err| {
                std.log.warn("Failed to stop actor {}: {}", .{ ref.id, err });
            };
        }
    }
};

test "actor ref basic functionality" {
    const allocator = testing.allocator;

    // Mock actor system for testing
    const MockActorSystem = struct {
        pub fn init() @This() {
            return @This(){};
        }
    };

    var mock_system = MockActorSystem.init();
    var mailbox = try Mailbox.init(allocator);
    defer mailbox.deinit();

    var state = std.atomic.Value(zactor.ActorState).init(.running);

    const dummy_actor: u32 = 0;
    const actor_ref = ActorRef.init(123, &mailbox, &state, @ptrCast(&mock_system), @ptrCast(&dummy_actor));

    try testing.expect(actor_ref.getId() == 123);
    try testing.expect(actor_ref.isAlive());
    try testing.expect(actor_ref.getState() == .running);

    // Test sending system message
    try actor_ref.sendSystem(.ping);

    const received = mailbox.receive();
    try testing.expect(received != null);
    try testing.expect(received.?.message_type == .system);
    try testing.expect(received.?.data.system == .ping);
}

test "actor ref registry" {
    const allocator = testing.allocator;

    var registry = ActorRefRegistry.init(allocator);
    defer registry.deinit();

    // Mock components
    const MockActorSystem = struct {
        pub fn init() @This() {
            return @This(){};
        }
    };

    var mock_system = MockActorSystem.init();
    var mailbox1 = try Mailbox.init(allocator);
    defer mailbox1.deinit();
    var mailbox2 = try Mailbox.init(allocator);
    defer mailbox2.deinit();

    var state1 = std.atomic.Value(zactor.ActorState).init(.running);
    var state2 = std.atomic.Value(zactor.ActorState).init(.running);

    const dummy_actor1: u32 = 0;
    const dummy_actor2: u32 = 0;
    const ref1 = ActorRef.init(1, &mailbox1, &state1, @ptrCast(&mock_system), @ptrCast(&dummy_actor1));
    const ref2 = ActorRef.init(2, &mailbox2, &state2, @ptrCast(&mock_system), @ptrCast(&dummy_actor2));

    // Register actors
    try registry.register(ref1);
    try registry.register(ref2);

    try testing.expect(registry.count() == 2);

    // Lookup actors
    const found1 = registry.lookup(1);
    try testing.expect(found1 != null);
    try testing.expect(found1.?.getId() == 1);

    const not_found = registry.lookup(999);
    try testing.expect(not_found == null);

    // Unregister actor
    registry.unregister(1);
    try testing.expect(registry.count() == 1);
}
