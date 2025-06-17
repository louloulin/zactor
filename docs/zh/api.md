# ZActor API 参考文档

## 核心类型

### ActorSystem (Actor系统)

所有Actor和系统资源的中央协调器。

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

#### 方法

##### `init(name: []const u8, allocator: Allocator) !*ActorSystem`
使用给定名称和分配器创建新的ActorSystem。

**参数:**
- `name`: 系统的可读名称
- `allocator`: 系统资源的内存分配器

**返回值:** 初始化的ActorSystem指针或错误

**示例:**
```zig
var system = try zactor.ActorSystem.init("my-app", allocator);
defer system.deinit();
```

##### `start(self: *Self) !void`
启动ActorSystem及其调度器。

**错误:**
- `SystemError.AlreadyStarted`: 系统已在运行
- `SystemError.SchedulerStartFailed`: 调度器启动失败

##### `spawn(self: *Self, comptime T: type, behavior: T) !ActorRef`
使用给定行为创建并启动新的Actor。

**参数:**
- `T`: Actor行为类型(必须实现Actor接口)
- `behavior`: 初始行为实例

**返回值:** 用于向Actor发送消息的ActorRef

**示例:**
```zig
const counter = try system.spawn(CounterActor, CounterActor.init("我的计数器"));
```

### Actor (执行者)

具有可配置行为和邮箱容量的通用Actor实现。

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

#### 方法

##### `send(self: *Self, message: FastMessage) bool`
向Actor的邮箱发送消息。

**参数:**
- `message`: 要发送的FastMessage

**返回值:** 如果消息已排队返回`true`，如果邮箱已满返回`false`

**示例:**
```zig
var message = FastMessage.init(sender_id, actor.id, .user);
message.setData("increment");
const success = actor.send(message);
```

##### `processMessages(self: *Self) !u32`
批量处理Actor邮箱中的消息。

**返回值:** 处理的消息数量

**错误:**
- `ActorError.NotRunning`: Actor不在运行状态
- `ActorError.ProcessingFailed`: 消息处理失败

### ActorRef (Actor引用)

具有位置透明性的Actor安全引用。

```zig
pub const ActorRef = struct {
    pub fn send(self: *Self, comptime T: type, data: T, allocator: Allocator) !void
    pub fn sendSystem(self: *Self, message: SystemMessage) !void
    pub fn getId(self: *const Self) ActorId
    pub fn isValid(self: *const Self) bool
};
```

#### 方法

##### `send(self: *Self, comptime T: type, data: T, allocator: Allocator) !void`
向引用的Actor发送用户消息。

**参数:**
- `T`: 要发送的数据类型
- `data`: 数据载荷
- `allocator`: 消息序列化的分配器

**示例:**
```zig
try actor_ref.send([]const u8, "increment", allocator);
try actor_ref.send(u32, 42, allocator);
```

##### `sendSystem(self: *Self, message: SystemMessage) !void`
向Actor发送系统消息。

**参数:**
- `message`: 系统消息类型(.ping, .pong, .start, .stop, .restart)

**示例:**
```zig
try actor_ref.sendSystem(.ping);
try actor_ref.sendSystem(.stop);
```

## 高性能组件

### FastMessage (快速消息)

为高吞吐量场景优化的64字节消息结构。

```zig
pub const FastMessage = struct {
    sender: ActorId,      // 8字节
    receiver: ActorId,    // 8字节
    message_type: MessageType, // 4字节
    timestamp: i64,       // 8字节
    data: [32]u8,        // 32字节 - 内联数据
    metadata: u32,       // 4字节
    
    pub fn init(sender: ActorId, receiver: ActorId, msg_type: MessageType) FastMessage
    pub fn setData(self: *FastMessage, data: []const u8) void
    pub fn getData(self: *const FastMessage) []const u8
    pub fn getTimestamp(self: *const FastMessage) i64
};
```

### SPSCQueue (单生产者单消费者队列)

无锁单生产者单消费者队列。

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

### Scheduler (调度器)

用于优化CPU利用率的工作窃取调度器。

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

## 配置

### PerformanceConfig (性能配置)

高性能Actor系统的配置。

```zig
pub const PerformanceConfig = struct {
    // 消息处理
    batch_size: u32 = 64,
    max_spin_cycles: u32 = 1000,
    
    // 内存配置
    arena_size: usize = 64 * 1024 * 1024,
    message_pool_size: u32 = 10000,
    actor_pool_size: u32 = 1000,
    
    // 调度配置
    worker_threads: u32 = 0, // 0 = 自动检测
    worker_queue_capacity: u32 = 4096,
    global_queue_capacity: u32 = 32768,
    actor_mailbox_capacity: u32 = 65536,
    enable_work_stealing: bool = true,
    
    // 优化标志
    enable_zero_copy: bool = true,
    enable_batching: bool = true,
    enable_prefetch: bool = true,
    enable_simd: bool = true,
    
    pub fn default() PerformanceConfig
    pub fn ultraFast() PerformanceConfig
    pub fn autoDetect() PerformanceConfig
};
```

#### 预定义配置

##### `default() PerformanceConfig`
适合大多数应用程序的平衡配置。

##### `ultraFast() PerformanceConfig`
具有更大缓冲区和所有优化启用的最大性能配置。

##### `autoDetect() PerformanceConfig`
自动检测系统能力并相应配置。

## 错误类型

### ActorError (Actor错误)

```zig
pub const ActorError = error {
    NotRunning,           // 未运行
    AlreadyRunning,       // 已在运行
    MessageDeliveryFailed, // 消息传递失败
    ProcessingFailed,     // 处理失败
    InvalidState,         // 无效状态
    ResourceExhausted,    // 资源耗尽
};
```

### SystemError (系统错误)

```zig
pub const SystemError = error {
    AlreadyStarted,           // 已启动
    NotStarted,              // 未启动
    SchedulerStartFailed,    // 调度器启动失败
    SchedulerStopFailed,     // 调度器停止失败
    InvalidConfiguration,    // 无效配置
    ResourceAllocationFailed, // 资源分配失败
};
```

### MessageError (消息错误)

```zig
pub const MessageError = error {
    InvalidFormat,        // 无效格式
    SerializationFailed,  // 序列化失败
    DeserializationFailed, // 反序列化失败
    PayloadTooLarge,      // 载荷过大
    InvalidRecipient,     // 无效接收者
};
```

## 统计和监控

### SystemStats (系统统计)

```zig
pub const SystemStats = struct {
    actors_created: u64,        // 创建的Actor数
    actors_stopped: u64,        // 停止的Actor数
    messages_processed: u64,    // 处理的消息数
    total_processing_time: u64, // 总处理时间
    uptime_ms: i64,            // 运行时间(毫秒)
    
    pub fn getThroughput(self: *const Self) f64
    pub fn getAverageLatency(self: *const Self) f64
    pub fn print(self: *const Self) void
};
```

### SchedulerStats (调度器统计)

```zig
pub const SchedulerStats = struct {
    tasks_submitted: u64,      // 提交的任务数
    tasks_completed: u64,      // 完成的任务数
    tasks_stolen: u64,         // 窃取的任务数
    worker_utilization: [8]f64, // 工作线程利用率
    
    pub fn getEfficiency(self: *const Self) f64
    pub fn getLoadBalance(self: *const Self) f64
};
```

## Actor行为接口

### 必需方法

Actor必须实现以下接口:

```zig
pub const ActorBehavior = struct {
    // 必需: 消息处理
    pub fn receive(self: *Self, message: Message, context: *ActorContext) !void
    
    // 可选: 生命周期钩子
    pub fn preStart(self: *Self, context: *ActorContext) !void
    pub fn postStop(self: *Self, context: *ActorContext) !void
    pub fn preRestart(self: *Self, context: *ActorContext, reason: anyerror) !void
    pub fn postRestart(self: *Self, context: *ActorContext) !void
    
    // 可选: 错误处理
    pub fn onError(self: *Self, error: anyerror) !void
};
```

### 示例实现

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
                    std.log.info("计数器 '{s}': {}", .{ self.name, self.count });
                } else if (std.mem.eql(u8, data, "get")) {
                    // 向发送者回复响应
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
                    .stop => std.log.info("计数器 '{s}' 停止中", .{self.name}),
                    else => {},
                }
            },
            else => {},
        }
    }
    
    pub fn preStart(self: *@This(), context: *ActorContext) !void {
        std.log.info("计数器 '{s}' 启动中", .{self.name});
    }
    
    pub fn postStop(self: *@This(), context: *ActorContext) !void {
        std.log.info("计数器 '{s}' 已停止，最终计数: {}", .{ self.name, self.count });
    }
};
```

## 最佳实践

### 1. 消息设计
- 保持消息小巧(高吞吐量场景优先使用FastMessage)
- 尽可能使用不可变数据结构
- 避免消息中的大载荷

### 2. Actor设计
- 保持Actor状态最小且专注
- 实现适当的错误处理
- 使用生命周期钩子进行资源管理

### 3. 性能优化
- 根据消息量使用适当的邮箱容量
- 为高吞吐量场景启用批处理
- 监控队列利用率并调整配置

### 4. 错误处理
- 实现适合用例的监督策略
- 在Actor行为中使用适当的错误传播
- 监控Actor重启率和故障模式
