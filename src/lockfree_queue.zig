const std = @import("std");
const Allocator = std.mem.Allocator;

// High-performance lock-free SPSC (Single Producer Single Consumer) queue
// Optimized for maximum throughput with minimal contention
pub fn LockFreeQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const CACHE_LINE_SIZE = 64;
        const CAPACITY = 65536; // Must be power of 2 for fast modulo

        // Separate cache lines to avoid false sharing
        buffer: [CAPACITY]T align(CACHE_LINE_SIZE),

        // Producer cache line
        head: std.atomic.Value(u32) align(CACHE_LINE_SIZE),
        head_cache: u32,

        // Consumer cache line
        tail: std.atomic.Value(u32) align(CACHE_LINE_SIZE),
        tail_cache: u32,

        pub fn init() Self {
            return Self{
                .buffer = undefined,
                .head = std.atomic.Value(u32).init(0),
                .head_cache = 0,
                .tail = std.atomic.Value(u32).init(0),
                .tail_cache = 0,
            };
        }

        // Producer side - optimized for minimal atomic operations
        pub fn push(self: *Self, item: T) bool {
            const head = self.head.load(.monotonic);
            const next_head = (head + 1) & (CAPACITY - 1);

            // Check if queue is full using cached tail
            if (next_head == self.tail_cache) {
                // Update cache and check again
                self.tail_cache = self.tail.load(.acquire);
                if (next_head == self.tail_cache) {
                    return false; // Queue is full
                }
            }

            // Store item and update head
            self.buffer[head] = item;
            self.head.store(next_head, .release);
            return true;
        }

        // Consumer side - optimized for minimal atomic operations
        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);

            // Check if queue is empty using cached head
            if (tail == self.head_cache) {
                // Update cache and check again
                self.head_cache = self.head.load(.acquire);
                if (tail == self.head_cache) {
                    return null; // Queue is empty
                }
            }

            // Load item and update tail
            const item = self.buffer[tail];
            const next_tail = (tail + 1) & (CAPACITY - 1);
            self.tail.store(next_tail, .release);
            return item;
        }

        // Batch operations for higher throughput
        pub fn pushBatch(self: *Self, items: []const T) u32 {
            var pushed: u32 = 0;
            for (items) |item| {
                if (!self.push(item)) break;
                pushed += 1;
            }
            return pushed;
        }

        pub fn popBatch(self: *Self, buffer: []T) u32 {
            var popped: u32 = 0;
            for (buffer) |*slot| {
                if (self.pop()) |item| {
                    slot.* = item;
                    popped += 1;
                } else break;
            }
            return popped;
        }

        pub fn isEmpty(self: *Self) bool {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            return tail == head;
        }

        pub fn size(self: *Self) u32 {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            // 使用wrapping arithmetic避免溢出
            return (head -% tail) & (CAPACITY - 1);
        }

        pub fn capacity(self: *Self) u32 {
            _ = self;
            return CAPACITY;
        }
    };
}

// Multi-Producer Single-Consumer queue for actor scheduling
pub fn MPSCQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            data: T,
            next: std.atomic.Value(?*Node),
        };

        head: std.atomic.Value(?*Node),
        tail: *Node,
        allocator: Allocator,

        pub fn init(allocator: Allocator) !Self {
            const dummy = try allocator.create(Node);
            dummy.* = Node{
                .data = undefined,
                .next = std.atomic.Value(?*Node).init(null),
            };

            return Self{
                .head = std.atomic.Value(?*Node).init(dummy),
                .tail = dummy,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Clean up remaining nodes
            while (self.pop()) |_| {}
            self.allocator.destroy(self.tail);
        }

        pub fn push(self: *Self, data: T) !void {
            const node = try self.allocator.create(Node);
            node.* = Node{
                .data = data,
                .next = std.atomic.Value(?*Node).init(null),
            };

            const prev_head = self.head.swap(node, .acq_rel);
            prev_head.?.next.store(node, .release);
        }

        pub fn pop(self: *Self) ?T {
            const tail = self.tail;
            const next = tail.next.load(.acquire);

            if (next) |next_node| {
                const data = next_node.data;
                self.tail = next_node;
                self.allocator.destroy(tail);
                return data;
            }

            return null;
        }
    };
}

test "lockfree queue basic operations" {
    const testing = std.testing;

    var queue = LockFreeQueue(u32).init();

    // Test empty queue
    try testing.expect(queue.isEmpty());
    try testing.expect(queue.pop() == null);

    // Test push/pop
    try testing.expect(queue.push(42));
    try testing.expect(!queue.isEmpty());
    try testing.expect(queue.pop().? == 42);
    try testing.expect(queue.isEmpty());

    // Test batch operations
    const items = [_]u32{ 1, 2, 3, 4, 5 };
    const pushed = queue.pushBatch(&items);
    try testing.expect(pushed == 5);

    var buffer: [10]u32 = undefined;
    const popped = queue.popBatch(&buffer);
    try testing.expect(popped == 5);

    for (0..5) |i| {
        try testing.expect(buffer[i] == items[i]);
    }
}

test "mpsc queue operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var queue = try MPSCQueue(u32).init(allocator);
    defer queue.deinit();

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);

    try testing.expect(queue.pop().? == 1);
    try testing.expect(queue.pop().? == 2);
    try testing.expect(queue.pop().? == 3);
    try testing.expect(queue.pop() == null);
}
