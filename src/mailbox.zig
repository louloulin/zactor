const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zactor = @import("zactor.zig");
const Message = @import("message.zig").Message;

// Simple thread-safe mailbox using mutex for now (can optimize later)
pub const Mailbox = struct {
    const Self = @This();

    messages: std.ArrayList(Message),
    mutex: std.Thread.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .messages = std.ArrayList(Message).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up remaining messages
        for (self.messages.items) |msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit();
    }

    // Thread-safe send
    pub fn send(self: *Self, message: Message) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.messages.append(message);
    }

    // Single-consumer receive
    pub fn receive(self: *Self) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len > 0) {
            return self.messages.orderedRemove(0);
        }

        return null;
    }

    pub fn isEmpty(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.messages.items.len == 0;
    }

    pub fn size(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return @intCast(self.messages.items.len);
    }
};

test "mailbox basic functionality" {
    const allocator = testing.allocator;

    var mailbox = try Mailbox.init(allocator);
    defer mailbox.deinit();

    try testing.expect(mailbox.isEmpty());
    try testing.expect(mailbox.receive() == null);

    // Send a message
    const msg = Message.createSystem(.start, 123);
    try mailbox.send(msg);

    try testing.expect(!mailbox.isEmpty());

    // Receive the message
    const received = mailbox.receive();
    try testing.expect(received != null);
    try testing.expect(received.?.message_type == .system);
    try testing.expect(received.?.data.system == .start);
}

test "mailbox high throughput" {
    const allocator = testing.allocator;

    var mailbox = try Mailbox.init(allocator);
    defer mailbox.deinit();

    const num_messages = 1000;

    // Send many messages
    for (0..num_messages) |i| {
        const msg = Message.createSystem(.ping, @intCast(i));
        try mailbox.send(msg);
    }

    // Receive all messages
    var received_count: u32 = 0;
    while (mailbox.receive()) |_| {
        received_count += 1;
    }

    try testing.expect(received_count == num_messages);
}
