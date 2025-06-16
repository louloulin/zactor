//! High-Performance Actor System - 高性能Actor系统
//! 基于Zig语言特性的零开销Actor实现
//!
//! 设计原则:
//! 1. 零成本抽象 - 使用comptime消除运行时开销
//! 2. 内存效率 - 基于Arena分配器和对象池
//! 3. 无锁设计 - SPSC/MPSC队列，避免锁竞争
//! 4. 批量处理 - 减少系统调用和上下文切换
//! 5. 缓存友好 - 数据结构针对CPU缓存优化

const std = @import("std");
const Allocator = std.mem.Allocator;
const AtomicValue = std.atomic.Value;
const Thread = std.Thread;

// 导出核心组件
pub const Actor = @import("actor.zig").Actor;
pub const ActorBehavior = @import("actor.zig").ActorBehavior;
pub const CounterActor = @import("actor.zig").CounterActor;
pub const CounterBehavior = @import("actor.zig").CounterBehavior;
pub const ActorState = @import("actor.zig").ActorState;
pub const Scheduler = @import("scheduler.zig").Scheduler;
pub const ActorTask = @import("scheduler.zig").ActorTask;
pub const SchedulerStats = @import("scheduler.zig").SchedulerStats;

// 性能配置
pub const PerformanceConfig = struct {
    // 消息处理配置
    batch_size: u32 = 64, // 批量处理消息数量
    max_spin_cycles: u32 = 1000, // 自旋等待周期

    // 内存配置
    arena_size: usize = 64 * 1024 * 1024, // 64MB Arena
    message_pool_size: u32 = 10000, // 消息池大小
    actor_pool_size: u32 = 1000, // Actor池大小

    // 调度配置
    worker_threads: u32 = 0, // 0 = auto-detect
    queue_capacity: u32 = 65536, // 队列容量
    enable_work_stealing: bool = true,

    // 优化开关
    enable_zero_copy: bool = true, // 零拷贝优化
    enable_batching: bool = true, // 批量处理
    enable_prefetch: bool = true, // 预取优化
    enable_simd: bool = true, // SIMD优化

    pub fn autoDetect() PerformanceConfig {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        return PerformanceConfig{
            .worker_threads = @intCast(@max(1, cpu_count)),
        };
    }

    pub fn ultraFast() PerformanceConfig {
        return PerformanceConfig{
            .batch_size = 128,
            .max_spin_cycles = 10000,
            .arena_size = 128 * 1024 * 1024,
            .message_pool_size = 50000,
            .actor_pool_size = 5000,
            .worker_threads = @intCast(@max(1, std.Thread.getCpuCount() catch 8)),
            .queue_capacity = 131072,
            .enable_zero_copy = true,
            .enable_batching = true,
            .enable_prefetch = true,
            .enable_simd = true,
        };
    }
};

// Actor ID类型 - 使用紧凑表示
pub const ActorId = packed struct {
    node_id: u16, // 节点ID (支持分布式)
    worker_id: u8, // 工作线程ID
    local_id: u39, // 本地ID

    pub fn init(node_id: u16, worker_id: u8, local_id: u39) ActorId {
        return ActorId{
            .node_id = node_id,
            .worker_id = worker_id,
            .local_id = local_id,
        };
    }

    pub fn toU64(self: ActorId) u64 {
        return @bitCast(self);
    }

    pub fn fromU64(value: u64) ActorId {
        return @bitCast(value);
    }
};

// 消息类型 - 使用tagged union优化
pub const MessageType = enum(u8) {
    user = 0,
    system = 1,
    control = 2,
    batch = 3,
};

// 高性能消息结构
pub const FastMessage = struct {
    // 消息头 (16字节，缓存行对齐)
    id: u64, // 消息ID
    sender: ActorId, // 发送者ID
    receiver: ActorId, // 接收者ID
    msg_type: MessageType, // 消息类型
    size: u24, // 数据大小
    flags: u8, // 标志位

    // 消息数据 (内联小消息，避免额外分配)
    data: [48]u8, // 内联数据 (总共64字节)

    pub fn init(sender: ActorId, receiver: ActorId, msg_type: MessageType) FastMessage {
        return FastMessage{
            .id = generateMessageId(),
            .sender = sender,
            .receiver = receiver,
            .msg_type = msg_type,
            .size = 0,
            .flags = 0,
            .data = std.mem.zeroes([48]u8),
        };
    }

    pub fn setData(self: *FastMessage, data: []const u8) void {
        const copy_size = @min(data.len, self.data.len);
        @memcpy(self.data[0..copy_size], data[0..copy_size]);
        self.size = @intCast(copy_size);
    }

    pub fn getData(self: *const FastMessage) []const u8 {
        return self.data[0..self.size];
    }
};

// 消息ID生成器
var message_id_counter = AtomicValue(u64).init(0);

fn generateMessageId() u64 {
    return message_id_counter.fetchAdd(1, .monotonic);
}

// SPSC无锁队列 - 针对单生产者单消费者优化
pub fn SPSCQueue(comptime T: type, comptime capacity: u32) type {
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        // 确保capacity是2的幂
        comptime {
            if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
                @compileError("Capacity must be a power of 2");
            }
        }

        // 缓存行对齐，避免伪共享
        buffer: [capacity]T align(64),
        head: AtomicValue(u32) align(64) = AtomicValue(u32).init(0),
        tail: AtomicValue(u32) align(64) = AtomicValue(u32).init(0),

        pub fn init() Self {
            return Self{
                .buffer = undefined,
                .head = AtomicValue(u32).init(0),
                .tail = AtomicValue(u32).init(0),
            };
        }

        pub fn push(self: *Self, item: T) bool {
            const current_tail = self.tail.load(.monotonic);
            const next_tail = current_tail + 1;

            // 检查队列是否满
            if (next_tail - self.head.load(.acquire) > capacity) {
                return false;
            }

            // 写入数据
            self.buffer[current_tail & mask] = item;

            // 更新tail指针
            self.tail.store(next_tail, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const current_head = self.head.load(.monotonic);

            // 检查队列是否空
            if (current_head == self.tail.load(.acquire)) {
                return null;
            }

            // 读取数据
            const item = self.buffer[current_head & mask];

            // 更新head指针
            self.head.store(current_head + 1, .release);
            return item;
        }

        pub fn size(self: *const Self) u32 {
            return self.tail.load(.monotonic) - self.head.load(.monotonic);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head.load(.monotonic) == self.tail.load(.monotonic);
        }

        pub fn isFull(self: *const Self) bool {
            return self.size() >= capacity;
        }
    };
}

// 批量消息处理器
pub const BatchProcessor = struct {
    const Self = @This();

    messages: []FastMessage,
    count: u32,
    capacity: u32,

    pub fn init(allocator: Allocator, capacity: u32) !Self {
        const messages = try allocator.alloc(FastMessage, capacity);
        return Self{
            .messages = messages,
            .count = 0,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.messages);
    }

    pub fn add(self: *Self, message: FastMessage) bool {
        if (self.count >= self.capacity) {
            return false;
        }

        self.messages[self.count] = message;
        self.count += 1;
        return true;
    }

    pub fn clear(self: *Self) void {
        self.count = 0;
    }

    pub fn getBatch(self: *const Self) []const FastMessage {
        return self.messages[0..self.count];
    }
};

// 性能统计 - 使用原子操作避免锁
pub const PerformanceStats = struct {
    messages_sent: AtomicValue(u64) = AtomicValue(u64).init(0),
    messages_received: AtomicValue(u64) = AtomicValue(u64).init(0),
    messages_processed: AtomicValue(u64) = AtomicValue(u64).init(0),
    batch_count: AtomicValue(u64) = AtomicValue(u64).init(0),
    total_latency_ns: AtomicValue(u64) = AtomicValue(u64).init(0),

    pub fn recordMessageSent(self: *PerformanceStats) void {
        _ = self.messages_sent.fetchAdd(1, .monotonic);
    }

    pub fn recordMessageReceived(self: *PerformanceStats) void {
        _ = self.messages_received.fetchAdd(1, .monotonic);
    }

    pub fn recordMessageProcessed(self: *PerformanceStats, latency_ns: u64) void {
        _ = self.messages_processed.fetchAdd(1, .monotonic);
        _ = self.total_latency_ns.fetchAdd(latency_ns, .monotonic);
    }

    pub fn recordBatch(self: *PerformanceStats, batch_size: u32) void {
        _ = self.batch_count.fetchAdd(1, .monotonic);
        _ = self.messages_processed.fetchAdd(batch_size, .monotonic);
    }

    pub fn getThroughput(self: *const PerformanceStats, duration_ns: u64) f64 {
        const processed = self.messages_processed.load(.monotonic);
        const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(processed)) / duration_s;
    }

    pub fn getAverageLatency(self: *const PerformanceStats) f64 {
        const processed = self.messages_processed.load(.monotonic);
        if (processed == 0) return 0.0;

        const total_latency = self.total_latency_ns.load(.monotonic);
        return @as(f64, @floatFromInt(total_latency)) / @as(f64, @floatFromInt(processed));
    }

    pub fn print(self: *const PerformanceStats) void {
        const sent = self.messages_sent.load(.monotonic);
        const received = self.messages_received.load(.monotonic);
        const processed = self.messages_processed.load(.monotonic);
        const batches = self.batch_count.load(.monotonic);
        const avg_latency = self.getAverageLatency();

        std.log.info("=== High-Performance Actor Stats ===", .{});
        std.log.info("Messages sent: {}", .{sent});
        std.log.info("Messages received: {}", .{received});
        std.log.info("Messages processed: {}", .{processed});
        std.log.info("Batch count: {}", .{batches});
        std.log.info("Average latency: {d:.2} ns", .{avg_latency});

        if (batches > 0) {
            const avg_batch_size = @as(f64, @floatFromInt(processed)) / @as(f64, @floatFromInt(batches));
            std.log.info("Average batch size: {d:.2}", .{avg_batch_size});
        }
    }
};

// 测试
test "SPSCQueue basic operations" {
    const testing = std.testing;

    var queue = SPSCQueue(u32, 16).init();

    // 测试空队列
    try testing.expect(queue.isEmpty());
    try testing.expect(queue.pop() == null);

    // 测试推入和弹出
    try testing.expect(queue.push(42));
    try testing.expect(!queue.isEmpty());
    try testing.expect(queue.size() == 1);

    const value = queue.pop();
    try testing.expect(value != null);
    try testing.expect(value.? == 42);
    try testing.expect(queue.isEmpty());
}

test "FastMessage operations" {
    const testing = std.testing;

    const sender = ActorId.init(0, 0, 1);
    const receiver = ActorId.init(0, 0, 2);

    var message = FastMessage.init(sender, receiver, .user);

    const test_data = "Hello, World!";
    message.setData(test_data);

    const retrieved_data = message.getData();
    try testing.expectEqualStrings(test_data, retrieved_data);
}
