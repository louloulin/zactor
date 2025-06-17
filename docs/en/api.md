# ZActor API Reference

## Core Types

### ActorSystem

The central coordinator for all Actors and system resources.

```zig
pub const ActorSystem = struct {
    pub fn init(name: []const u8, allocator: Allocator) !*Self
    pub fn deinit(self: *Self) void
    pub fn start(self: *Self) !void
    pub fn shutdown(self: *Self) !void
    pub fn spawn(self: *Self, comptime T: type, behavior: T) !ActorRef
    pub fn getStats(self: *Self) SystemStats
};
```

#### Methods

##### `init(name: []const u8, allocator: Allocator) !*ActorSystem`
Creates a new ActorSystem with the given name and allocator.

**Parameters:**
- `name`: Human-readable name for the system
- `allocator`: Memory allocator for system resources

**Returns:** Pointer to initialized ActorSystem or error

**Example:**
```zig
var system = try zactor.ActorSystem.init("my-app", allocator);
defer system.deinit();
```

##### `start(self: *Self) !void`
Starts the ActorSystem and its scheduler.

**Errors:**
- `SystemError.AlreadyStarted`: System is already running
- `SystemError.SchedulerStartFailed`: Failed to start scheduler

##### `spawn(self: *Self, comptime T: type, behavior: T) !ActorRef`
Creates and starts a new Actor with the given behavior.

**Parameters:**
- `T`: Actor behavior type (must implement Actor interface)
- `behavior`: Initial behavior instance

**Returns:** ActorRef for sending messages to the Actor

**Example:**
```zig
const counter = try system.spawn(CounterActor, CounterActor.init("MyCounter"));
```

### Actor

Generic Actor implementation with configurable behavior and mailbox capacity.

```zig
pub fn Actor(comptime BehaviorType: type, comptime mailbox_capacity: u32) type {
    return struct {
        pub fn init(allocator: Allocator, id: ActorId, behavior: BehaviorType) !*Self
        pub fn deinit(self: *Self) void
        pub fn start(self: *Self) !void
        pub fn stop(self: *Self) !void
        pub fn send(self: *Self, message: FastMessage) bool
        pub fn processMessages(self: *Self) !u32
        pub fn getState(self: *const Self) ActorState
        pub fn isRunning(self: *const Self) bool
    };
}
```

#### Methods

##### `send(self: *Self, message: FastMessage) bool`
Sends a message to the Actor's mailbox.

**Parameters:**
- `message`: FastMessage to send

**Returns:** `true` if message was queued, `false` if mailbox is full

**Example:**
```zig
var message = FastMessage.init(sender_id, actor.id, .user);
message.setData("increment");
const success = actor.send(message);
```

##### `processMessages(self: *Self) !u32`
Processes messages from the Actor's mailbox in batches.

**Returns:** Number of messages processed

**Errors:**
- `ActorError.NotRunning`: Actor is not in running state
- `ActorError.ProcessingFailed`: Message processing failed

### ActorRef

Safe reference to an Actor with location transparency.

```zig
pub const ActorRef = struct {
    pub fn send(self: *Self, comptime T: type, data: T, allocator: Allocator) !void
    pub fn sendSystem(self: *Self, message: SystemMessage) !void
    pub fn getId(self: *const Self) ActorId
    pub fn isValid(self: *const Self) bool
};
```

#### Methods

##### `send(self: *Self, comptime T: type, data: T, allocator: Allocator) !void`
Sends a user message to the referenced Actor.

**Parameters:**
- `T`: Type of data to send
- `data`: Data payload
- `allocator`: Allocator for message serialization

**Example:**
```zig
try actor_ref.send([]const u8, "increment", allocator);
try actor_ref.send(u32, 42, allocator);
```

##### `sendSystem(self: *Self, message: SystemMessage) !void`
Sends a system message to the Actor.

**Parameters:**
- `message`: System message type (.ping, .pong, .start, .stop, .restart)

**Example:**
```zig
try actor_ref.sendSystem(.ping);
try actor_ref.sendSystem(.stop);
```

## High-Performance Components

### FastMessage

Optimized 64-byte message structure for high-throughput scenarios.

```zig
pub const FastMessage = struct {
    sender: ActorId,
    receiver: ActorId,
    message_type: MessageType,
    timestamp: i64,
    data: [32]u8,
    metadata: u32,
    
    pub fn init(sender: ActorId, receiver: ActorId, msg_type: MessageType) FastMessage
    pub fn setData(self: *FastMessage, data: []const u8) void
    pub fn getData(self: *const FastMessage) []const u8
    pub fn getTimestamp(self: *const FastMessage) i64
};
```

### SPSCQueue

Lock-free single-producer, single-consumer queue.

```zig
pub fn SPSCQueue(comptime T: type, comptime capacity: u32) type {
    return struct {
        pub fn init() Self
        pub fn push(self: *Self, item: T) bool
        pub fn pop(self: *Self) ?T
        pub fn size(self: *const Self) u32
        pub fn isEmpty(self: *const Self) bool
        pub fn isFull(self: *const Self) bool
    };
}
```

### Scheduler

Work-stealing scheduler for optimal CPU utilization.

```zig
pub const Scheduler = struct {
    pub fn init(allocator: Allocator, config: PerformanceConfig) !Self
    pub fn deinit(self: *Self) void
    pub fn start(self: *Self) !void
    pub fn stop(self: *Self) !void
    pub fn submit(self: *Self, task: ActorTask) bool
    pub fn getStats(self: *const Self) SchedulerStats
    pub fn isRunning(self: *const Self) bool
};
```

## Configuration

### PerformanceConfig

Configuration for high-performance Actor systems.

```zig
pub const PerformanceConfig = struct {
    // Message processing
    batch_size: u32 = 64,
    max_spin_cycles: u32 = 1000,
    
    // Memory configuration
    arena_size: usize = 64 * 1024 * 1024,
    message_pool_size: u32 = 10000,
    actor_pool_size: u32 = 1000,
    
    // Scheduling configuration
    worker_threads: u32 = 0, // 0 = auto-detect
    worker_queue_capacity: u32 = 4096,
    global_queue_capacity: u32 = 32768,
    actor_mailbox_capacity: u32 = 65536,
    enable_work_stealing: bool = true,
    
    // Optimization flags
    enable_zero_copy: bool = true,
    enable_batching: bool = true,
    enable_prefetch: bool = true,
    enable_simd: bool = true,
    
    pub fn default() PerformanceConfig
    pub fn ultraFast() PerformanceConfig
    pub fn autoDetect() PerformanceConfig
};
```

#### Predefined Configurations

##### `default() PerformanceConfig`
Balanced configuration suitable for most applications.

##### `ultraFast() PerformanceConfig`
Maximum performance configuration with larger buffers and all optimizations enabled.

##### `autoDetect() PerformanceConfig`
Automatically detects system capabilities and configures accordingly.

## Error Types

### ActorError

```zig
pub const ActorError = error {
    NotRunning,
    AlreadyRunning,
    MessageDeliveryFailed,
    ProcessingFailed,
    InvalidState,
    ResourceExhausted,
};
```

### SystemError

```zig
pub const SystemError = error {
    AlreadyStarted,
    NotStarted,
    SchedulerStartFailed,
    SchedulerStopFailed,
    InvalidConfiguration,
    ResourceAllocationFailed,
};
```

### MessageError

```zig
pub const MessageError = error {
    InvalidFormat,
    SerializationFailed,
    DeserializationFailed,
    PayloadTooLarge,
    InvalidRecipient,
};
```

## Statistics and Monitoring

### SystemStats

```zig
pub const SystemStats = struct {
    actors_created: u64,
    actors_stopped: u64,
    messages_processed: u64,
    total_processing_time: u64,
    uptime_ms: i64,
    
    pub fn getThroughput(self: *const Self) f64
    pub fn getAverageLatency(self: *const Self) f64
    pub fn print(self: *const Self) void
};
```

### SchedulerStats

```zig
pub const SchedulerStats = struct {
    tasks_submitted: u64,
    tasks_completed: u64,
    tasks_stolen: u64,
    worker_utilization: [8]f64,
    
    pub fn getEfficiency(self: *const Self) f64
    pub fn getLoadBalance(self: *const Self) f64
};
```

## Actor Behavior Interface

### Required Methods

Actors must implement the following interface:

```zig
pub const ActorBehavior = struct {
    // Required: Message processing
    pub fn receive(self: *Self, message: Message, context: *ActorContext) !void
    
    // Optional: Lifecycle hooks
    pub fn preStart(self: *Self, context: *ActorContext) !void
    pub fn postStop(self: *Self, context: *ActorContext) !void
    pub fn preRestart(self: *Self, context: *ActorContext, reason: anyerror) !void
    pub fn postRestart(self: *Self, context: *ActorContext) !void
    
    // Optional: Error handling
    pub fn onError(self: *Self, error: anyerror) !void
};
```

### Example Implementation

```zig
const CounterActor = struct {
    name: []const u8,
    count: u32 = 0,
    
    pub fn init(name: []const u8) @This() {
        return .{ .name = name };
    }
    
    pub fn receive(self: *@This(), message: Message, context: *ActorContext) !void {
        switch (message.message_type) {
            .user => {
                const data = message.getData();
                if (std.mem.eql(u8, data, "increment")) {
                    self.count += 1;
                    std.log.info("Counter '{s}': {}", .{ self.name, self.count });
                } else if (std.mem.eql(u8, data, "get")) {
                    // Send response back to sender
                    if (message.getSender()) |sender| {
                        const response = try std.fmt.allocPrint(
                            context.allocator, 
                            "count:{}", 
                            .{self.count}
                        );
                        defer context.allocator.free(response);
                        try sender.send([]const u8, response, context.allocator);
                    }
                }
            },
            .system => {
                switch (message.data.system) {
                    .ping => try context.self.sendSystem(.pong),
                    .stop => std.log.info("Counter '{s}' stopping", .{self.name}),
                    else => {},
                }
            },
            else => {},
        }
    }
    
    pub fn preStart(self: *@This(), context: *ActorContext) !void {
        std.log.info("Counter '{s}' starting", .{self.name});
    }
    
    pub fn postStop(self: *@This(), context: *ActorContext) !void {
        std.log.info("Counter '{s}' stopped with count: {}", .{ self.name, self.count });
    }
};
```

## Best Practices

### 1. Message Design
- Keep messages small (prefer FastMessage for high-throughput scenarios)
- Use immutable data structures when possible
- Avoid large payloads in messages

### 2. Actor Design
- Keep Actor state minimal and focused
- Implement proper error handling
- Use lifecycle hooks for resource management

### 3. Performance Optimization
- Use appropriate mailbox capacities based on message volume
- Enable batching for high-throughput scenarios
- Monitor queue utilization and adjust configurations

### 4. Error Handling
- Implement supervision strategies appropriate for your use case
- Use proper error propagation in Actor behaviors
- Monitor Actor restart rates and failure patterns
