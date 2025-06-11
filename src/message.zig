const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zactor = @import("zactor.zig");

pub const MessageType = enum {
    user,
    system,
    control,
};

pub const SystemMessage = enum {
    start,
    stop,
    restart,
    supervise,
    ping,
    pong,
};

pub const ControlMessage = enum {
    shutdown,
    suspend_actor,
    resume_actor,
    status_request,
};

// Generic message container that can hold any type of data
pub const Message = struct {
    id: zactor.MessageId,
    message_type: MessageType,
    sender: ?zactor.ActorId,
    timestamp: i64,
    data: MessageData,

    pub const MessageData = union(MessageType) {
        user: UserData,
        system: SystemMessage,
        control: ControlMessage,
    };

    pub const UserData = struct {
        payload: []const u8,
        type_hash: u64,

        pub fn init(comptime T: type, data: T, allocator: Allocator) !UserData {
            _ = @typeInfo(T);
            const type_hash = std.hash_map.hashString(@typeName(T));

            // Serialize the data
            var payload = std.ArrayList(u8).init(allocator);
            defer payload.deinit();

            try std.json.stringify(data, .{}, payload.writer());

            return UserData{
                .payload = try allocator.dupe(u8, payload.items),
                .type_hash = type_hash,
            };
        }

        pub fn get(self: UserData, comptime T: type, allocator: Allocator) !T {
            const expected_hash = std.hash_map.hashString(@typeName(T));
            if (self.type_hash != expected_hash) {
                return error.TypeMismatch;
            }

            var stream = std.json.TokenStream.init(self.payload);
            return try std.json.parse(T, &stream, .{ .allocator = allocator });
        }

        pub fn deinit(self: UserData, allocator: Allocator) void {
            allocator.free(self.payload);
        }
    };

    // Create a user message
    pub fn createUser(comptime T: type, data: T, sender: ?zactor.ActorId, allocator: Allocator) !Message {
        const user_data = try UserData.init(T, data, allocator);
        return Message{
            .id = generateMessageId(),
            .message_type = .user,
            .sender = sender,
            .timestamp = std.time.milliTimestamp(),
            .data = .{ .user = user_data },
        };
    }

    // Create a system message
    pub fn createSystem(msg: SystemMessage, sender: ?zactor.ActorId) Message {
        return Message{
            .id = generateMessageId(),
            .message_type = .system,
            .sender = sender,
            .timestamp = std.time.milliTimestamp(),
            .data = .{ .system = msg },
        };
    }

    // Create a control message
    pub fn createControl(msg: ControlMessage, sender: ?zactor.ActorId) Message {
        return Message{
            .id = generateMessageId(),
            .message_type = .control,
            .sender = sender,
            .timestamp = std.time.milliTimestamp(),
            .data = .{ .control = msg },
        };
    }

    pub fn deinit(self: Message, allocator: Allocator) void {
        switch (self.data) {
            .user => |user_data| user_data.deinit(allocator),
            else => {},
        }
    }

    pub fn isSystem(self: Message) bool {
        return self.message_type == .system;
    }

    pub fn isControl(self: Message) bool {
        return self.message_type == .control;
    }

    pub fn isUser(self: Message) bool {
        return self.message_type == .user;
    }
};

// Thread-safe message ID generator
var message_id_counter = std.atomic.Value(u64).init(1);

fn generateMessageId() zactor.MessageId {
    return message_id_counter.fetchAdd(1, .monotonic);
}

// Message pool for high-performance message allocation
pub const MessagePool = struct {
    pool: std.ArrayList(*Message),
    mutex: std.Thread.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator, initial_size: u32) !MessagePool {
        var pool = std.ArrayList(*Message).init(allocator);
        try pool.ensureTotalCapacity(initial_size);

        // Pre-allocate messages
        for (0..initial_size) |_| {
            const msg = try allocator.create(Message);
            try pool.append(msg);
        }

        return MessagePool{
            .pool = pool,
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessagePool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.pool.items) |msg| {
            self.allocator.destroy(msg);
        }
        self.pool.deinit();
    }

    pub fn acquire(self: *MessagePool) !*Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pool.items.len > 0) {
            return self.pool.pop();
        }

        // Pool is empty, allocate new message
        return try self.allocator.create(Message);
    }

    pub fn release(self: *MessagePool, msg: *Message) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Reset message for reuse
        msg.* = undefined;
        self.pool.append(msg) catch {
            // If we can't add to pool, just free it
            self.allocator.destroy(msg);
        };
    }
};

test "message creation and serialization" {
    const allocator = testing.allocator;

    // Test user message with string data
    const test_data = "Hello, ZActor!";
    var msg = try Message.createUser([]const u8, test_data, 123, allocator);
    defer msg.deinit(allocator);

    try testing.expect(msg.message_type == .user);
    try testing.expect(msg.sender.? == 123);
    try testing.expect(msg.isUser());
    try testing.expect(!msg.isSystem());

    // Test retrieving data
    const retrieved = try msg.data.user.get([]const u8, allocator);
    defer allocator.free(retrieved);
    try testing.expectEqualStrings(test_data, retrieved);
}

test "system message creation" {
    const msg = Message.createSystem(.start, 456);

    try testing.expect(msg.message_type == .system);
    try testing.expect(msg.sender.? == 456);
    try testing.expect(msg.data.system == .start);
    try testing.expect(msg.isSystem());
}

test "message pool functionality" {
    const allocator = testing.allocator;

    var pool = try MessagePool.init(allocator, 5);
    defer pool.deinit();

    // Acquire messages
    const msg1 = try pool.acquire();
    const msg2 = try pool.acquire();

    // Release them back
    pool.release(msg1);
    pool.release(msg2);

    // Should be able to acquire again
    const msg3 = try pool.acquire();
    pool.release(msg3);
}
