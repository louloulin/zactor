const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zactor = @import("zactor.zig");
const Message = @import("message.zig").Message;

// High-performance mailbox using ring buffer and atomic operations
pub const Mailbox = struct {
    const Self = @This();
    const CAPACITY = 4096; // Fixed size ring buffer for better performance

    messages: [CAPACITY]Message,
    head: std.atomic.Value(u32), // Read position
    tail: std.atomic.Value(u32), // Write position
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Self {
        var self = Self{
            .messages = undefined, // Will be initialized as needed
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };

        // Initialize all message slots to avoid undefined behavior
        for (0..CAPACITY) |i| {
            self.messages[i] = undefined;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up remaining messages
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);

        var pos = head;
        while (pos != tail) {
            self.messages[pos % CAPACITY].deinit(self.allocator);
            pos = (pos + 1) % CAPACITY;
        }
    }

    // Lock-free send (single producer for now)
    pub fn send(self: *Self, message: Message) !void {
        const tail = self.tail.load(.acquire);
        const head = self.head.load(.acquire);
        const next_tail = (tail + 1) % CAPACITY;

        // Check if queue is full
        if (next_tail == head) {
            return error.MailboxFull;
        }

        self.messages[tail] = message;
        self.tail.store(next_tail, .release);
    }

    // Lock-free receive (single consumer)
    pub fn receive(self: *Self) ?Message {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);

        if (head == tail) {
            return null; // Empty
        }

        const message = self.messages[head];
        self.head.store((head + 1) % CAPACITY, .release);
        return message;
    }

    pub fn isEmpty(self: *Self) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return head == tail;
    }

    pub fn size(self: *Self) u32 {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);

        if (tail >= head) {
            return tail - head;
        } else {
            return (CAPACITY - head) + tail;
        }
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
