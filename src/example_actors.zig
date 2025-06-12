const std = @import("std");
const FastMessage = @import("message_pool.zig").FastMessage;

// 高性能计数器Actor
pub const HighPerfCounterActor = struct {
    const Self = @This();

    name: []const u8,
    count: std.atomic.Value(u64),
    last_report_time: i128,
    last_report_count: u64,

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .count = std.atomic.Value(u64).init(0),
            .last_report_time = std.time.nanoTimestamp(),
            .last_report_count = 0,
        };
    }

    pub fn receive(self: *Self, msg: *FastMessage) bool {
        const current_count = self.count.fetchAdd(1, .monotonic) + 1;

        switch (msg.msg_type) {
            .user_string => {
                // 处理字符串消息 - 计算长度
                const str = msg.getString();
                _ = self.count.fetchAdd(str.len, .monotonic);
            },
            .user_int => {
                // 处理整数消息 - 累加值
                const value = msg.getInt();
                if (value > 0) {
                    _ = self.count.fetchAdd(@intCast(value), .monotonic);
                }
            },
            .user_float => {
                // 处理浮点数消息 - 累加整数部分
                const value = msg.getFloat();
                if (value > 0) {
                    _ = self.count.fetchAdd(@intFromFloat(value), .monotonic);
                }
            },
            .system_ping => {
                // 处理ping - 报告当前状态
                const now = std.time.nanoTimestamp();
                const elapsed_ms = @divTrunc(now - self.last_report_time, 1000000);

                // 安全地计算消息窗口，避免溢出
                const messages_in_window = if (current_count >= self.last_report_count)
                    current_count - self.last_report_count
                else
                    current_count; // 如果发生溢出，使用当前计数

                if (elapsed_ms > 0) {
                    const rate = @divTrunc(messages_in_window * 1000, @as(u64, @intCast(elapsed_ms)));
                    std.log.info("🔢 Counter '{s}': {} total, {} msg/s", .{ self.name, current_count, rate });
                }

                self.last_report_time = now;
                self.last_report_count = current_count;
            },
            else => {
                // 其他消息类型
            },
        }

        // 每10万条消息报告一次
        if (current_count % 100000 == 0) {
            const now = std.time.nanoTimestamp();
            const elapsed_ms = @divTrunc(now - self.last_report_time, 1000000);

            if (elapsed_ms > 0) {
                const rate = @divTrunc((current_count - self.last_report_count) * 1000, @as(u64, @intCast(elapsed_ms)));
                std.log.info("📈 Counter '{s}' milestone: {}k messages (rate: {} msg/s)", .{ self.name, current_count / 1000, rate });
            }
        }

        return true;
    }

    pub fn preStart(self: *Self) void {
        std.log.info("🚀 HighPerfCounterActor '{s}' starting", .{self.name});
        self.last_report_time = std.time.nanoTimestamp();
    }

    pub fn preStop(self: *Self) void {
        const final_count = self.count.load(.monotonic);
        std.log.info("🛑 HighPerfCounterActor '{s}' stopping (final count: {})", .{ self.name, final_count });
    }

    pub fn getCount(self: *Self) u64 {
        return self.count.load(.monotonic);
    }
};

// 高性能聚合器Actor
pub const HighPerfAggregatorActor = struct {
    const Self = @This();

    name: []const u8,
    string_count: std.atomic.Value(u64),
    int_sum: std.atomic.Value(i64),
    float_sum: f64, // 不使用原子操作，因为f64不支持
    total_messages: std.atomic.Value(u64),

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .string_count = std.atomic.Value(u64).init(0),
            .int_sum = std.atomic.Value(i64).init(0),
            .float_sum = 0.0,
            .total_messages = std.atomic.Value(u64).init(0),
        };
    }

    pub fn receive(self: *Self, msg: *FastMessage) bool {
        _ = self.total_messages.fetchAdd(1, .monotonic);

        switch (msg.msg_type) {
            .user_string => {
                const str = msg.getString();
                _ = self.string_count.fetchAdd(str.len, .monotonic);
            },
            .user_int => {
                const value = msg.getInt();
                _ = self.int_sum.fetchAdd(value, .monotonic);
            },
            .user_float => {
                // 简单累加（非原子操作，仅用于演示）
                const value = msg.getFloat();
                self.float_sum += value;
            },
            .system_ping => {
                const total = self.total_messages.load(.monotonic);
                const str_count = self.string_count.load(.monotonic);
                const int_sum = self.int_sum.load(.monotonic);
                const float_sum = self.float_sum;

                std.log.info("📊 Aggregator '{s}': {} msgs, {} chars, sum_int={}, sum_float={d:.2}", .{ self.name, total, str_count, int_sum, float_sum });
            },
            else => {},
        }

        return true;
    }

    pub fn preStart(self: *Self) void {
        std.log.info("🚀 HighPerfAggregatorActor '{s}' starting", .{self.name});
    }

    pub fn preStop(self: *Self) void {
        const total = self.total_messages.load(.monotonic);
        std.log.info("🛑 HighPerfAggregatorActor '{s}' stopping (processed {} messages)", .{ self.name, total });
    }
};

// 高性能转发器Actor
pub const HighPerfForwarderActor = struct {
    const Self = @This();

    name: []const u8,
    target_actors: []u32, // 目标Actor ID列表
    forward_count: std.atomic.Value(u64),
    round_robin_index: std.atomic.Value(u32),

    pub fn init(name: []const u8, target_actors: []u32) Self {
        return Self{
            .name = name,
            .target_actors = target_actors,
            .forward_count = std.atomic.Value(u64).init(0),
            .round_robin_index = std.atomic.Value(u32).init(0),
        };
    }

    pub fn receive(self: *Self, msg: *FastMessage) bool {
        _ = self.forward_count.fetchAdd(1, .monotonic);

        // 简单的轮询转发（在实际系统中需要访问系统引用来发送消息）
        const index = self.round_robin_index.fetchAdd(1, .monotonic) % @as(u32, @intCast(self.target_actors.len));
        const target_id = self.target_actors[index];

        // 在实际实现中，这里会调用系统的sendMessage方法
        // 现在只是模拟处理
        _ = target_id;
        _ = msg;

        return true;
    }

    pub fn preStart(self: *Self) void {
        std.log.info("🚀 HighPerfForwarderActor '{s}' starting (targets: {})", .{ self.name, self.target_actors.len });
    }

    pub fn preStop(self: *Self) void {
        const total = self.forward_count.load(.monotonic);
        std.log.info("🛑 HighPerfForwarderActor '{s}' stopping (forwarded {} messages)", .{ self.name, total });
    }
};

// 高性能批处理Actor
pub const HighPerfBatchProcessorActor = struct {
    const Self = @This();
    const BATCH_SIZE = 1000;

    name: []const u8,
    batch_buffer: [BATCH_SIZE]ProcessedMessage,
    batch_count: std.atomic.Value(u32),
    total_batches: std.atomic.Value(u64),
    total_processed: std.atomic.Value(u64),

    const ProcessedMessage = struct {
        msg_type: FastMessage.Type,
        processed_at: i128,
        data_hash: u64,
    };

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .batch_buffer = undefined,
            .batch_count = std.atomic.Value(u32).init(0),
            .total_batches = std.atomic.Value(u64).init(0),
            .total_processed = std.atomic.Value(u64).init(0),
        };
    }

    pub fn receive(self: *Self, msg: *FastMessage) bool {
        // 原子地获取当前批次计数
        const current_count = self.batch_count.load(.monotonic);

        // 添加到批处理缓冲区
        if (current_count < BATCH_SIZE) {
            self.batch_buffer[current_count] = ProcessedMessage{
                .msg_type = msg.msg_type,
                .processed_at = std.time.nanoTimestamp(),
                .data_hash = self.calculateHash(msg),
            };

            // 原子地增加计数
            const new_count = self.batch_count.fetchAdd(1, .monotonic) + 1;

            // 如果批次满了，处理整个批次
            if (new_count >= BATCH_SIZE) {
                self.processBatch();
            }
        }

        _ = self.total_processed.fetchAdd(1, .monotonic);
        return true;
    }

    fn calculateHash(self: *Self, msg: *FastMessage) u64 {
        _ = self;
        // 简单的哈希计算
        var hash: u64 = @intFromEnum(msg.msg_type);
        hash = hash * 31 + msg.actor_id;
        hash = hash * 31 + msg.sequence;
        return hash;
    }

    fn processBatch(self: *Self) void {
        // 模拟批处理逻辑
        var type_counts = [_]u32{0} ** 8; // 假设最多8种消息类型

        // 原子地获取当前批次大小
        const current_count = self.batch_count.load(.monotonic);
        const safe_count = @min(current_count, BATCH_SIZE);

        for (self.batch_buffer[0..safe_count]) |processed_msg| {
            const type_index = @intFromEnum(processed_msg.msg_type);
            if (type_index < type_counts.len) {
                type_counts[type_index] += 1;
            }
        }

        _ = self.total_batches.fetchAdd(1, .monotonic);
        // 原子地重置批次计数
        _ = self.batch_count.fetchSub(safe_count, .acq_rel);

        // 每100个批次报告一次
        const batch_num = self.total_batches.load(.monotonic);
        if (batch_num % 100 == 0) {
            std.log.info("📦 BatchProcessor '{s}': processed {} batches ({} messages)", .{ self.name, batch_num, batch_num * BATCH_SIZE });
        }
    }

    pub fn preStart(self: *Self) void {
        std.log.info("🚀 HighPerfBatchProcessorActor '{s}' starting", .{self.name});
    }

    pub fn preStop(self: *Self) void {
        // 处理剩余的消息
        if (self.batch_count.load(.monotonic) > 0) {
            self.processBatch();
        }

        const total_batches = self.total_batches.load(.monotonic);
        const total_processed = self.total_processed.load(.monotonic);
        std.log.info("🛑 HighPerfBatchProcessorActor '{s}' stopping ({} batches, {} messages)", .{ self.name, total_batches, total_processed });
    }
};
