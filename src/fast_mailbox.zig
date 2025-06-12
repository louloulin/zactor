const std = @import("std");
const Allocator = std.mem.Allocator;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;
const FastMessage = @import("message_pool.zig").FastMessage;
const MessageBatch = @import("message_pool.zig").MessageBatch;

// Ultra-high-performance mailbox using lock-free queue
pub const FastMailbox = struct {
    const Self = @This();
    
    // Lock-free queue for maximum throughput
    queue: LockFreeQueue(*FastMessage),
    
    // Statistics for monitoring
    messages_sent: std.atomic.Value(u64),
    messages_received: std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),

    pub fn init() Self {
        return Self{
            .queue = LockFreeQueue(*FastMessage).init(),
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_received = std.atomic.Value(u64).init(0),
            .messages_dropped = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No cleanup needed for lock-free queue
    }

    // Single message operations
    pub fn send(self: *Self, message: *FastMessage) bool {
        if (self.queue.push(message)) {
            _ = self.messages_sent.fetchAdd(1, .monotonic);
            return true;
        } else {
            _ = self.messages_dropped.fetchAdd(1, .monotonic);
            return false;
        }
    }

    pub fn receive(self: *Self) ?*FastMessage {
        if (self.queue.pop()) |msg| {
            _ = self.messages_received.fetchAdd(1, .monotonic);
            return msg;
        }
        return null;
    }

    // Batch operations for maximum throughput
    pub fn sendBatch(self: *Self, batch: *const MessageBatch) u32 {
        const messages = batch.getMessages();
        var sent: u32 = 0;
        
        for (messages) |msg| {
            if (self.queue.push(msg)) {
                sent += 1;
            } else {
                _ = self.messages_dropped.fetchAdd(1, .monotonic);
                break;
            }
        }
        
        _ = self.messages_sent.fetchAdd(sent, .monotonic);
        return sent;
    }

    pub fn receiveBatch(self: *Self, batch: *MessageBatch) u32 {
        batch.clear();
        var received: u32 = 0;
        
        while (!batch.isFull()) {
            if (self.queue.pop()) |msg| {
                if (batch.add(msg)) {
                    received += 1;
                } else {
                    // This shouldn't happen since we check isFull()
                    break;
                }
            } else {
                break;
            }
        }
        
        _ = self.messages_received.fetchAdd(received, .monotonic);
        return received;
    }

    // Optimized batch receive with pre-allocated buffer
    pub fn receiveBatchDirect(self: *Self, buffer: []*FastMessage) u32 {
        var received: u32 = 0;
        
        for (buffer) |*slot| {
            if (self.queue.pop()) |msg| {
                slot.* = msg;
                received += 1;
            } else {
                break;
            }
        }
        
        _ = self.messages_received.fetchAdd(received, .monotonic);
        return received;
    }

    // Status and statistics
    pub fn isEmpty(self: *Self) bool {
        return self.queue.isEmpty();
    }

    pub fn size(self: *Self) u32 {
        return self.queue.size();
    }

    pub fn capacity(self: *Self) u32 {
        return self.queue.capacity();
    }

    pub fn getStats(self: *Self) MailboxStats {
        return MailboxStats{
            .messages_sent = self.messages_sent.load(.monotonic),
            .messages_received = self.messages_received.load(.monotonic),
            .messages_dropped = self.messages_dropped.load(.monotonic),
            .current_size = self.size(),
            .capacity = self.capacity(),
        };
    }

    // Performance monitoring
    pub fn resetStats(self: *Self) void {
        self.messages_sent.store(0, .monotonic);
        self.messages_received.store(0, .monotonic);
        self.messages_dropped.store(0, .monotonic);
    }
};

pub const MailboxStats = struct {
    messages_sent: u64,
    messages_received: u64,
    messages_dropped: u64,
    current_size: u32,
    capacity: u32,

    pub fn getDropRate(self: *const MailboxStats) f64 {
        const total = self.messages_sent + self.messages_dropped;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.messages_dropped)) / @as(f64, @floatFromInt(total));
    }

    pub fn getThroughput(self: *const MailboxStats, elapsed_ms: u64) f64 {
        if (elapsed_ms == 0) return 0.0;
        return @as(f64, @floatFromInt(self.messages_received * 1000)) / @as(f64, @floatFromInt(elapsed_ms));
    }
};

// Specialized mailbox for different actor types
pub const ActorMailboxType = enum {
    standard,    // Normal actors
    high_volume, // High-throughput actors
    system,      // System actors (lower latency)
};

pub fn createOptimizedMailbox(mailbox_type: ActorMailboxType) FastMailbox {
    _ = mailbox_type;
    // For now, all types use the same implementation
    // In the future, we could have different queue sizes or algorithms
    return FastMailbox.init();
}

test "fast mailbox basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var mailbox = FastMailbox.init();
    defer mailbox.deinit();
    
    // Create a mock message pool for testing
    var pool = @import("message_pool.zig").MessagePool.init(allocator) catch return;
    defer pool.deinit();
    
    // Test empty mailbox
    try testing.expect(mailbox.isEmpty());
    try testing.expect(mailbox.receive() == null);
    
    // Test send/receive
    if (pool.acquire()) |msg| {
        msg.* = @import("message_pool.zig").FastMessage.createSystemPing(1, 0, 0);
        try testing.expect(mailbox.send(msg));
        try testing.expect(!mailbox.isEmpty());
        
        const received = mailbox.receive();
        try testing.expect(received != null);
        try testing.expect(received.?.msg_type == .system_ping);
        
        pool.release(received.?);
    }
}

test "fast mailbox batch operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var mailbox = FastMailbox.init();
    defer mailbox.deinit();
    
    var pool = @import("message_pool.zig").MessagePool.init(allocator) catch return;
    defer pool.deinit();
    
    // Create a batch of messages
    var send_batch = @import("message_pool.zig").MessageBatch.init();
    for (0..10) |i| {
        if (pool.acquire()) |msg| {
            msg.* = @import("message_pool.zig").FastMessage.createUserInt(1, 0, i, @intCast(i));
            _ = send_batch.add(msg);
        }
    }
    
    // Send batch
    const sent = mailbox.sendBatch(&send_batch);
    try testing.expect(sent == 10);
    
    // Receive batch
    var receive_batch = @import("message_pool.zig").MessageBatch.init();
    const received = mailbox.receiveBatch(&receive_batch);
    try testing.expect(received == 10);
    
    // Verify messages
    const messages = receive_batch.getMessages();
    for (messages, 0..) |msg, i| {
        try testing.expect(msg.getInt() == @as(i64, @intCast(i)));
        pool.release(msg);
    }
}

test "mailbox statistics" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var mailbox = FastMailbox.init();
    defer mailbox.deinit();
    
    var pool = @import("message_pool.zig").MessagePool.init(allocator) catch return;
    defer pool.deinit();
    
    // Send some messages
    for (0..5) |_| {
        if (pool.acquire()) |msg| {
            msg.* = @import("message_pool.zig").FastMessage.createSystemPing(1, 0, 0);
            _ = mailbox.send(msg);
        }
    }
    
    // Receive some messages
    for (0..3) |_| {
        if (mailbox.receive()) |msg| {
            pool.release(msg);
        }
    }
    
    const stats = mailbox.getStats();
    try testing.expect(stats.messages_sent == 5);
    try testing.expect(stats.messages_received == 3);
    try testing.expect(stats.current_size == 2);
}
