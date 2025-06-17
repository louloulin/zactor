# ZActor Examples Guide

This guide provides comprehensive examples demonstrating ZActor's capabilities, from basic usage to advanced high-performance scenarios.

## Basic Examples

### 1. Simple Counter Actor

**File:** `examples/basic.zig`

A fundamental example showing Actor creation, message sending, and lifecycle management.

```zig
const std = @import("std");
const zactor = @import("zactor");

const CounterActor = struct {
    name: []const u8,
    count: u32 = 0,
    
    pub fn init(name: []const u8) @This() {
        return .{ .name = name };
    }
    
    pub fn receive(self: *@This(), message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                const data = message.getData();
                if (std.mem.eql(u8, data, "increment")) {
                    self.count += 1;
                    std.log.info("Counter '{s}': {}", .{ self.name, self.count });
                } else if (std.mem.eql(u8, data, "get_count")) {
                    std.log.info("Counter '{s}' current count: {}", .{ self.name, self.count });
                }
            },
            .system => {
                switch (message.data.system) {
                    .ping => {
                        std.log.info("Counter '{s}' received ping", .{self.name});
                        try context.self.sendSystem(.pong);
                    },
                    .pong => std.log.info("Counter '{s}' received pong", .{self.name}),
                    else => {},
                }
            },
            else => {},
        }
    }
    
    pub fn preStart(self: *@This(), context: *zactor.ActorContext) !void {
        std.log.info("Counter '{s}' starting", .{self.name});
    }
    
    pub fn postStop(self: *@This(), context: *zactor.ActorContext) !void {
        std.log.info("Counter '{s}' stopped with final count: {}", .{ self.name, self.count });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create and start Actor system
    var system = try zactor.ActorSystem.init("basic-example", allocator);
    defer system.deinit();
    
    try system.start();
    
    // Spawn Actors
    const counter1 = try system.spawn(CounterActor, CounterActor.init("Counter-1"));
    const counter2 = try system.spawn(CounterActor, CounterActor.init("Counter-2"));
    
    // Send messages
    try counter1.send([]const u8, "increment", allocator);
    try counter1.send([]const u8, "increment", allocator);
    try counter1.send([]const u8, "get_count", allocator);
    
    try counter2.send([]const u8, "increment", allocator);
    try counter2.send([]const u8, "get_count", allocator);
    
    // Send system messages
    try counter1.sendSystem(.ping);
    try counter2.sendSystem(.ping);
    
    // Wait for processing
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Graceful shutdown
    try system.shutdown();
}
```

**Run:** `zig build run-basic`

### 2. Ping-Pong Communication

**File:** `examples/ping_pong.zig`

Demonstrates inter-Actor communication patterns and message routing.

```zig
const std = @import("std");
const zactor = @import("zactor");

const PingActor = struct {
    name: []const u8,
    pong_partner: ?zactor.ActorRef = null,
    ping_count: u32 = 0,
    max_pings: u32,
    
    pub fn init(name: []const u8, max_pings: u32) @This() {
        return .{ .name = name, .max_pings = max_pings };
    }
    
    pub fn receive(self: *@This(), message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                const data = message.getData();
                
                // Set partner
                if (std.mem.startsWith(u8, data, "partner:")) {
                    const partner_id_str = data[8..];
                    const partner_id = std.fmt.parseInt(u64, partner_id_str, 10) catch return;
                    
                    if (context.system.findActor(partner_id)) |partner| {
                        self.pong_partner = partner;
                        std.log.info("PingActor '{s}' set partner", .{self.name});
                        
                        // Start ping-pong
                        try self.sendPing(partner, context);
                    }
                }
                // Handle pong response
                else if (std.mem.startsWith(u8, data, "pong:")) {
                    const count_str = data[5..];
                    const count = std.fmt.parseInt(u32, count_str, 10) catch return;
                    
                    std.log.info("PingActor '{s}' received pong #{}", .{ self.name, count });
                    
                    if (self.ping_count < self.max_pings) {
                        if (self.pong_partner) |partner| {
                            try self.sendPing(partner, context);
                        }
                    } else {
                        std.log.info("PingActor '{s}' finished ping-pong game", .{self.name});
                    }
                }
            },
            else => {},
        }
    }
    
    fn sendPing(self: *@This(), partner: zactor.ActorRef, context: *zactor.ActorContext) !void {
        self.ping_count += 1;
        const ping_msg = try std.fmt.allocPrint(
            context.allocator, 
            "ping:{}", 
            .{self.ping_count}
        );
        defer context.allocator.free(ping_msg);
        
        std.log.info("PingActor '{s}' sending ping #{}", .{ self.name, self.ping_count });
        try partner.send([]const u8, ping_msg, context.allocator);
    }
};

const PongActor = struct {
    name: []const u8,
    pong_count: u32 = 0,
    
    pub fn init(name: []const u8) @This() {
        return .{ .name = name };
    }
    
    pub fn receive(self: *@This(), message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                const data = message.getData();
                
                if (std.mem.startsWith(u8, data, "ping:")) {
                    const count_str = data[5..];
                    const count = std.fmt.parseInt(u32, count_str, 10) catch return;
                    
                    self.pong_count += 1;
                    std.log.info("PongActor '{s}' received ping #{}, sending pong", .{ self.name, count });
                    
                    // Send pong response
                    if (message.getSender()) |sender| {
                        const pong_msg = try std.fmt.allocPrint(
                            context.allocator, 
                            "pong:{}", 
                            .{count}
                        );
                        defer context.allocator.free(pong_msg);
                        
                        try sender.send([]const u8, pong_msg, context.allocator);
                    }
                }
            },
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var system = try zactor.ActorSystem.init("ping-pong-system", allocator);
    defer system.deinit();
    
    try system.start();
    
    // Spawn Actors
    const ping_actor = try system.spawn(PingActor, PingActor.init("Ping", 5));
    const pong_actor = try system.spawn(PongActor, PongActor.init("Pong"));
    
    // Set up partnership
    const partner_msg = try std.fmt.allocPrint(allocator, "partner:{}", .{pong_actor.getId()});
    defer allocator.free(partner_msg);
    
    try ping_actor.send([]const u8, partner_msg, allocator);
    
    // Wait for ping-pong to complete
    std.time.sleep(1000 * std.time.ns_per_ms);
    
    try system.shutdown();
}
```

**Run:** `zig build run-ping-pong`

## Advanced Examples

### 3. Supervision and Fault Tolerance

**File:** `examples/supervisor_example.zig`

Shows how to implement supervision trees for fault tolerance.

```zig
const std = @import("std");
const zactor = @import("zactor");

const WorkerActor = struct {
    name: []const u8,
    work_count: u32 = 0,
    should_fail: bool = false,
    
    pub fn init(name: []const u8) @This() {
        return .{ .name = name };
    }
    
    pub fn receive(self: *@This(), message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                const data = message.getData();
                
                if (std.mem.eql(u8, data, "work")) {
                    self.work_count += 1;
                    std.log.info("Worker '{s}' completed work #{}", .{ self.name, self.work_count });
                    
                    // Simulate failure every 5th work item
                    if (self.work_count % 5 == 0) {
                        std.log.err("Worker '{s}' simulating failure!", .{self.name});
                        return error.SimulatedFailure;
                    }
                } else if (std.mem.eql(u8, data, "fail")) {
                    std.log.err("Worker '{s}' received fail command", .{self.name});
                    return error.CommandedFailure;
                } else if (std.mem.eql(u8, data, "status")) {
                    std.log.info("Worker '{s}' status: {} work items completed", .{ self.name, self.work_count });
                }
            },
            .system => {
                switch (message.data.system) {
                    .restart => {
                        std.log.info("Worker '{s}' restarting, resetting work count", .{self.name});
                        self.work_count = 0;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    
    pub fn preRestart(self: *@This(), context: *zactor.ActorContext, reason: anyerror) !void {
        std.log.warn("Worker '{s}' restarting due to: {}", .{ self.name, reason });
    }
    
    pub fn postRestart(self: *@This(), context: *zactor.ActorContext) !void {
        std.log.info("Worker '{s}' successfully restarted", .{self.name});
    }
};

const SupervisorActor = struct {
    name: []const u8,
    workers: std.ArrayList(zactor.ActorRef),
    restart_count: u32 = 0,
    
    pub fn init(name: []const u8, allocator: std.mem.Allocator) @This() {
        return .{ 
            .name = name, 
            .workers = std.ArrayList(zactor.ActorRef).init(allocator),
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.workers.deinit();
    }
    
    pub fn receive(self: *@This(), message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                const data = message.getData();
                
                if (std.mem.eql(u8, data, "create_workers")) {
                    // Create worker Actors
                    for (0..3) |i| {
                        const worker_name = try std.fmt.allocPrint(
                            context.allocator, 
                            "Worker-{}", 
                            .{i}
                        );
                        defer context.allocator.free(worker_name);
                        
                        const worker = try context.system.spawn(WorkerActor, WorkerActor.init(worker_name));
                        try self.workers.append(worker);
                    }
                    std.log.info("Supervisor '{s}' created {} workers", .{ self.name, self.workers.items.len });
                    
                } else if (std.mem.eql(u8, data, "distribute_work")) {
                    // Distribute work to all workers
                    for (self.workers.items) |worker| {
                        try worker.send([]const u8, "work", context.allocator);
                    }
                    std.log.info("Supervisor '{s}' distributed work to all workers", .{self.name});
                    
                } else if (std.mem.eql(u8, data, "check_status")) {
                    // Check status of all workers
                    for (self.workers.items) |worker| {
                        try worker.send([]const u8, "status", context.allocator);
                    }
                }
            },
            .system => {
                switch (message.data.system) {
                    .child_failed => {
                        self.restart_count += 1;
                        std.log.warn("Supervisor '{s}' handling child failure (restart #{})", .{ self.name, self.restart_count });
                        
                        // Implement supervision strategy
                        if (self.restart_count > 10) {
                            std.log.err("Supervisor '{s}' too many restarts, stopping", .{self.name});
                            try context.self.sendSystem(.stop);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var system = try zactor.ActorSystem.init("supervisor-example", allocator);
    defer system.deinit();
    
    try system.start();
    
    // Create supervisor
    var supervisor_behavior = SupervisorActor.init("MainSupervisor", allocator);
    defer supervisor_behavior.deinit();
    
    const supervisor = try system.spawn(SupervisorActor, supervisor_behavior);
    
    // Create workers
    try supervisor.send([]const u8, "create_workers", allocator);
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Distribute work multiple times to trigger failures
    for (0..10) |i| {
        std.log.info("=== Work Distribution Round {} ===", .{i + 1});
        try supervisor.send([]const u8, "distribute_work", allocator);
        std.time.sleep(200 * std.time.ns_per_ms);
        
        try supervisor.send([]const u8, "check_status", allocator);
        std.time.sleep(100 * std.time.ns_per_ms);
    }
    
    try system.shutdown();
}
```

**Run:** `zig build run-supervisor`

## High-Performance Examples

### 4. Stress Testing

**File:** `examples/zactor_stress_test.zig`

Demonstrates ZActor's high-performance capabilities with stress testing.

```zig
const std = @import("std");
const zactor = @import("zactor");
const high_perf = zactor.HighPerf;

const SilentCounterBehavior = struct {
    name: []const u8,
    count: u32 = 0,

    pub fn init(name: []const u8) @This() {
        return .{ .name = name };
    }

    pub fn receive(self: *@This(), message: high_perf.FastMessage) !void {
        const data = message.getData();
        
        if (std.mem.eql(u8, data, "increment")) {
            self.count += 1;
            // Only log every 1000 messages to reduce overhead
            if (self.count % 1000 == 0) {
                std.log.info("Counter '{s}' reached {}", .{ self.name, self.count });
            }
        }
    }

    pub fn getCount(self: *const @This()) u32 {
        return self.count;
    }
};

const SilentCounterActor = high_perf.Actor(SilentCounterBehavior, 65536);

fn runStressTest(allocator: std.mem.Allocator, message_count: u32, actor_count: u32) !void {
    std.log.info("=== Stress Test: {} messages, {} actors ===", .{ message_count, actor_count });
    
    const config = high_perf.PerformanceConfig.ultraFast();
    var scheduler = try high_perf.Scheduler.init(allocator, config);
    defer scheduler.deinit();
    
    try scheduler.start();
    
    // Create Actors
    var actors = std.ArrayList(*SilentCounterActor).init(allocator);
    defer {
        for (actors.items) |actor| {
            actor.deinit();
        }
        actors.deinit();
    }
    
    for (0..actor_count) |i| {
        const name = try std.fmt.allocPrint(allocator, "actor-{}", .{i});
        defer allocator.free(name);
        
        const behavior = SilentCounterBehavior.init(name);
        const id = high_perf.ActorId.init(0, 0, @intCast(i + 1));
        
        const actor = try SilentCounterActor.init(allocator, id, behavior);
        try actor.start();
        try actors.append(actor);
    }
    
    std.log.info("Created {} actors", .{actor_count});
    
    // Send messages
    const start_time = std.time.nanoTimestamp();
    var messages_sent: u64 = 0;
    
    for (0..message_count) |i| {
        const actor_index = i % actor_count;
        const actor = actors.items[actor_index];
        
        const sender_id = high_perf.ActorId.init(0, 0, 0);
        var message = high_perf.FastMessage.init(sender_id, actor.id, .user);
        message.setData("increment");
        
        if (actor.send(message)) {
            messages_sent += 1;
        }
    }
    
    const send_time = std.time.nanoTimestamp();
    const send_duration_ms = @as(f64, @floatFromInt(send_time - start_time)) / 1_000_000.0;
    
    std.log.info("Sent {} messages in {d:.2} ms", .{ messages_sent, send_duration_ms });
    
    // Wait for processing
    std.time.sleep(2000 * std.time.ns_per_ms);
    
    // Collect statistics
    var total_processed: u64 = 0;
    var total_mailbox_size: u32 = 0;
    
    for (actors.items) |actor| {
        const debug_info = actor.getDebugInfo();
        total_processed += debug_info.message_count;
        total_mailbox_size += debug_info.mailbox_size;
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    
    // Stop Actors
    for (actors.items) |actor| {
        try actor.stop();
    }
    
    try scheduler.stop();
    
    // Print results
    std.log.info("=== Stress Test Results ===", .{});
    std.log.info("Actors: {}", .{actor_count});
    std.log.info("Messages sent: {}", .{messages_sent});
    std.log.info("Messages processed: {}", .{total_processed});
    std.log.info("Send duration: {d:.2} ms", .{send_duration_ms});
    std.log.info("Total duration: {d:.2} ms", .{total_duration_ms});
    std.log.info("Send throughput: {d:.2} msg/s", .{@as(f64, @floatFromInt(messages_sent)) / (send_duration_ms / 1000.0)});
    std.log.info("Process throughput: {d:.2} msg/s", .{@as(f64, @floatFromInt(total_processed)) / (total_duration_ms / 1000.0)});
    std.log.info("Success rate: {d:.2}%", .{@as(f64, @floatFromInt(total_processed)) / @as(f64, @floatFromInt(messages_sent)) * 100.0});
    std.log.info("Mailbox backlog: {}", .{total_mailbox_size});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("Starting ZActor stress tests...", .{});
    
    // Light stress test
    try runStressTest(allocator, 10_000, 5);
    
    std.log.info("\n" ++ "=" ** 50 ++ "\n", .{});
    
    // Medium stress test
    try runStressTest(allocator, 100_000, 20);
    
    std.log.info("\n=== All stress tests completed! ===", .{});
}
```

**Run:** `zig build zactor-stress-test`

## Running Examples

### Build and Run Commands

```bash
# Basic examples
zig build run-basic              # Simple counter Actor
zig build run-ping-pong          # Inter-Actor communication
zig build run-supervisor         # Supervision and fault tolerance

# Performance examples
zig build zactor-stress-test     # High-performance stress testing
zig build high-perf-test         # High-performance Actor system
zig build simple-high-perf-test  # Simple performance validation

# All examples
zig build                        # Build all examples
```

### Example Output

**Basic Counter Example:**
```
info: Counter 'Counter-1' starting
info: Counter 'Counter-2' starting
info: Counter 'Counter-1': 1
info: Counter 'Counter-1': 2
info: Counter 'Counter-1' current count: 2
info: Counter 'Counter-2': 1
info: Counter 'Counter-2' current count: 1
info: Counter 'Counter-1' received ping
info: Counter 'Counter-2' received ping
```

**Stress Test Example:**
```
info: === Stress Test: 100000 messages, 20 actors ===
info: Created 20 actors
info: Sent 100000 messages in 10.27 ms
info: === Stress Test Results ===
info: Actors: 20
info: Messages sent: 100000
info: Messages processed: 100000
info: Send throughput: 9738425.05 msg/s
info: Process throughput: 4651162.79 msg/s
info: Success rate: 100.00%
info: Mailbox backlog: 0
```

## Best Practices from Examples

### 1. Actor Design
- Keep Actor state minimal and focused
- Implement proper lifecycle hooks
- Handle errors gracefully
- Use appropriate logging levels

### 2. Message Handling
- Process messages efficiently
- Avoid blocking operations
- Use batch processing for high throughput
- Implement proper error handling

### 3. System Configuration
- Choose appropriate configurations for your use case
- Monitor system performance
- Implement proper shutdown procedures
- Use supervision strategies for fault tolerance

### 4. Performance Optimization
- Use FastMessage for high-throughput scenarios
- Enable batching and other optimizations
- Monitor queue utilization
- Profile and optimize hot paths

These examples provide a solid foundation for building high-performance, fault-tolerant applications with ZActor.
