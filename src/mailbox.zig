const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zactor = @import("zactor.zig");
const Message = @import("message.zig").Message;

// Lock-free MPSC (Multi-Producer Single-Consumer) queue implementation
// Based on research from the plan - optimized for high performance message passing
pub const Mailbox = struct {
    const Self = @This();

    // Buffer size must be power of 2 for efficient modulo operations
    const BUFFER_SIZE = 1024;
    const BUFFER_MASK = BUFFER_SIZE - 1;

    const Node = struct {
        message: ?Message,
        ready: std.atomic.Value(bool),

        fn init() Node {
            return Node{
                .message = null,
                .ready = std.atomic.Value(bool).init(false),
            };
        }
    };

    const Buffer = struct {
        nodes: [BUFFER_SIZE]Node,
        next: std.atomic.Value(?*Buffer),
        pending: std.atomic.Value(i32),

        fn init(allocator: Allocator) !*Buffer {
            const buffer = try allocator.create(Buffer);
            buffer.* = Buffer{
                .nodes = [_]Node{Node.init()} ** BUFFER_SIZE,
                .next = std.atomic.Value(?*Buffer).init(null),
                .pending = std.atomic.Value(i32).init(0),
            };
            return buffer;
        }

        fn deinit(self: *Buffer, allocator: Allocator) void {
            allocator.destroy(self);
        }

        fn unref(self: *Buffer, count: i32, allocator: Allocator) void {
            const prev = self.pending.fetchAdd(count, .release);
            if (prev + count == 0) {
                std.atomic.fence(.acquire);
                self.deinit(allocator);
            }
        }
    };

    // Packed producer state: [buffer_ptr:48, index:16]
    const ProducerState = packed struct {
        index: u16,
        buffer_ptr: u48,

        fn encode(buffer: ?*Buffer, index: u16) u64 {
            const ptr_val: u64 = if (buffer) |buf| @intFromPtr(buf) else 0;
            const state = ProducerState{
                .index = index,
                .buffer_ptr = @truncate(ptr_val),
            };
            return @bitCast(state);
        }

        fn decode(value: u64) struct { buffer: ?*Buffer, index: u16 } {
            const state: ProducerState = @bitCast(value);
            const buffer = if (state.buffer_ptr != 0)
                @as(*Buffer, @ptrFromInt(@as(usize, state.buffer_ptr)))
            else
                null;
            return .{ .buffer = buffer, .index = state.index };
        }
    };

    producer: std.atomic.Value(u64), // Encoded ProducerState
    consumer: std.atomic.Value(u64), // Encoded ProducerState
    allocator: Allocator,
    cached_buffer: ?*Buffer,

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .producer = std.atomic.Value(u64).init(ProducerState.encode(null, 0)),
            .consumer = std.atomic.Value(u64).init(ProducerState.encode(null, 0)),
            .allocator = allocator,
            .cached_buffer = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up any remaining buffers
        const consumer_state = ProducerState.decode(self.consumer.load(.acquire));
        if (consumer_state.buffer) |buffer| {
            buffer.deinit(self.allocator);
        }

        if (self.cached_buffer) |buffer| {
            buffer.deinit(self.allocator);
        }
    }

    // High-performance enqueue using FAA (Fetch-And-Add) on x86_64
    pub fn send(self: *Self, message: Message) !void {
        while (true) {
            // Fast path: try to reserve a slot using FAA
            const old_producer = self.producer.fetchAdd(1, .acquire);
            const state = ProducerState.decode(old_producer);

            if (state.buffer != null and state.index < BUFFER_SIZE) {
                // Successfully reserved a slot
                const buffer = state.buffer.?;
                const slot = &buffer.nodes[state.index];

                // Write message and mark as ready
                slot.message = message;
                slot.ready.store(true, .release);
                return;
            }

            // Slow path: need to allocate new buffer
            try self.installNewBuffer(state.buffer, state.index);
        }
    }

    fn installNewBuffer(self: *Self, old_buffer: ?*Buffer, overflow_index: u16) !void {
        // Find where to link the new buffer
        const prev_link = if (old_buffer) |buf| &buf.next else &self.consumer;

        // Get or create new buffer
        var next_buffer = prev_link.load(.acquire);
        if (next_buffer == null) {
            // Use cached buffer or allocate new one
            if (self.cached_buffer) |cached| {
                next_buffer = cached;
                self.cached_buffer = null;
            } else {
                next_buffer = try Buffer.init(self.allocator);
            }

            // Try to install the new buffer
            if (prev_link.compareAndSwap(null, next_buffer, .release, .acquire)) |existing| {
                // Someone else installed a buffer, use theirs
                if (self.cached_buffer == null) {
                    self.cached_buffer = next_buffer;
                }
                next_buffer = existing;
            }
        }

        // Try to update producer to point to new buffer
        const current_producer = self.producer.load(.relaxed);
        const current_state = ProducerState.decode(current_producer);

        while (current_state.buffer == old_buffer) {
            const new_producer = ProducerState.encode(next_buffer, 1);
            if (self.producer.compareAndSwap(current_producer, new_producer, .release, .relaxed)) |_| {
                continue;
            }

            // Successfully installed new buffer, handle reference counting
            const increment = @as(i32, @intCast(overflow_index)) - BUFFER_SIZE;
            if (old_buffer) |buf| {
                buf.unref(increment, self.allocator);
            } else {
                next_buffer.?.unref(1, self.allocator); // Account for consumer
            }

            // Write to slot 0 of new buffer
            // Note: message should be set by caller after this function returns
            return;
        }
    }

    // Single-consumer receive
    pub fn receive(self: *Self) ?Message {
        const consumer_state = ProducerState.decode(self.consumer.load(.acquire));
        var buffer = consumer_state.buffer;
        var index = consumer_state.index;

        if (buffer == null) return null;

        // Check if we need to move to next buffer
        if (index == BUFFER_SIZE) {
            const next = buffer.?.next.load(.acquire);
            if (next == null) return null;

            buffer.?.unref(-1, self.allocator);
            buffer = next;
            index = 0;
            self.consumer.store(ProducerState.encode(buffer, index), .unordered);
        }

        // Try to read from current slot
        const slot = &buffer.?.nodes[index];
        if (!slot.ready.load(.acquire)) {
            return null; // No message ready
        }

        const message = slot.message.?;
        slot.message = null;
        slot.ready.store(false, .release);

        // Update consumer position
        self.consumer.store(ProducerState.encode(buffer, index + 1), .unordered);

        return message;
    }

    pub fn isEmpty(self: *Self) bool {
        const consumer_state = ProducerState.decode(self.consumer.load(.acquire));
        if (consumer_state.buffer == null) return true;

        const slot = &consumer_state.buffer.?.nodes[consumer_state.index];
        return !slot.ready.load(.acquire);
    }

    pub fn size(self: *Self) u32 {
        // Approximate size - not exact due to concurrent nature
        const producer_state = ProducerState.decode(self.producer.load(.acquire));
        const consumer_state = ProducerState.decode(self.consumer.load(.acquire));

        if (producer_state.buffer == consumer_state.buffer) {
            return @as(u32, producer_state.index) - @as(u32, consumer_state.index);
        }

        // Different buffers, approximate
        return BUFFER_SIZE; // Conservative estimate
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
