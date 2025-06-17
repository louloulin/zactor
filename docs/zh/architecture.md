# ZActor 架构指南

## 概述

ZActor是用Zig语言实现的高性能Actor系统，专为系统编程设计，具备企业级性能和可靠性。架构遵循Actor模型，并针对多核系统进行了现代化优化。

## 核心设计原则

### 1. 零成本抽象
- **编译时优化**: 利用Zig的`comptime`实现零运行时开销
- **类型擦除消除**: 直接函数调用而非虚拟分发
- **内存布局优化**: 缓存友好的数据结构

### 2. 无锁设计
- **SPSC/MPSC队列**: 单/多生产者，单消费者队列
- **原子操作**: CAS和FAA操作进行同步
- **工作窃取**: 无锁任务分发

### 3. 内存效率
- **Arena分配器**: 批量内存分配减少碎片
- **对象池**: 可重用的消息和Actor对象
- **引用计数**: 原子计数器自动内存管理

## 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                    应用层                                    │
├─────────────────────────────────────────────────────────────┤
│                   Actor系统                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │  Actor A    │  │  Actor B    │  │  Actor C    │         │
│  │             │  │             │  │             │         │
│  │  邮箱       │  │  邮箱       │  │  邮箱       │         │
│  │  (64K)      │  │  (64K)      │  │  (64K)      │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
├─────────────────────────────────────────────────────────────┤
│                    调度器层                                  │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              工作窃取调度器                              │ │
│  │                                                         │ │
│  │  工作线程1   工作线程2   工作线程3   工作线程4           │ │
│  │  (4K队列)   (4K队列)   (4K队列)   (4K队列)             │ │
│  │      │           │           │           │              │ │
│  │      └───────────┼───────────┼───────────┘              │ │
│  │                  │           │                          │ │
│  │              全局队列 (32K)                              │ │
│  └─────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                   基础设施层                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   内存      │  │   消息      │  │   工具      │         │
│  │   管理器    │  │   系统      │  │   组件      │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

## 核心组件

### 1. ActorSystem (Actor系统)

**目的**: 所有Actor和系统资源的中央协调器。

**关键特性**:
- Actor生命周期管理(生成、停止、重启)
- 资源分配和清理
- 系统级配置和监控
- 优雅关闭协调

**实现**:
```zig
pub const ActorSystem = struct {
    allocator: Allocator,
    scheduler: Scheduler,
    actors: HashMap(ActorId, *Actor),
    supervisor: SupervisorTree,
    config: SystemConfig,
    stats: SystemStats,
    
    pub fn init(name: []const u8, allocator: Allocator) !*Self
    pub fn start(self: *Self) !void
    pub fn spawn(self: *Self, comptime T: type, behavior: T) !ActorRef
    pub fn shutdown(self: *Self) !void
};
```

### 2. Actor (执行者)

**目的**: 具有隔离状态的基本计算单元。

**关键特性**:
- 隔离的状态和行为
- 异步消息处理
- 生命周期钩子(preStart, postStop, preRestart, postRestart)
- 错误处理和监督

**实现**:
```zig
pub fn Actor(comptime BehaviorType: type, comptime mailbox_capacity: u32) type {
    return struct {
        id: ActorId,
        state: AtomicValue(ActorState),
        behavior: BehaviorType,
        mailbox: SPSCQueue(FastMessage, mailbox_capacity),
        stats: PerformanceStats,
        
        pub fn init(allocator: Allocator, id: ActorId, behavior: BehaviorType) !*Self
        pub fn send(self: *Self, message: FastMessage) bool
        pub fn processMessages(self: *Self) !u32
    };
}
```

### 3. 高性能消息传递

**FastMessage**: 优化的64字节消息结构
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
};
```

### 4. 工作窃取调度器

**目的**: 高效的多线程任务分发。

**关键特性**:
- 8个工作线程，每个有本地队列(4K容量)
- 全局队列用于负载均衡(32K容量)
- 工作窃取算法优化CPU利用率
- 批处理减少开销

**队列层次结构**:
```
工作线程本地队列 (每个4K)
    ↓ (空时从其他线程窃取)
全局队列 (32K)
    ↓ (本地队列满时)
Actor邮箱 (每个64K)
```

### 5. SPSC队列实现

**目的**: 无锁单生产者单消费者队列。

**关键特性**:
- 原子头/尾指针
- 2的幂容量实现高效模运算
- 内存序保证(获取/释放语义)
- 环绕算术溢出保护

```zig
pub fn SPSCQueue(comptime T: type, comptime capacity: u32) type {
    return struct {
        buffer: [capacity]T,
        head: AtomicValue(u32),
        tail: AtomicValue(u32),
        
        pub fn push(self: *Self, item: T) bool
        pub fn pop(self: *Self) ?T
        pub fn size(self: *const Self) u32
    };
}
```

## 性能优化

### 1. 队列容量设计 (基于Akka最佳实践)

| 组件 | 容量 | 目的 |
|------|------|------|
| **工作线程本地队列** | 4K | 快速本地处理 |
| **全局队列** | 32K | 负载均衡 |
| **Actor邮箱** | 64K | 消息缓冲 |
| **超高性能配置** | 128K | 极限性能 |

### 2. 内存布局优化

- **缓存行对齐**: 关键数据结构对齐到64字节边界
- **伪共享防护**: 原子变量按缓存行分离
- **批处理**: 每批处理最多128条消息以摊销开销

### 3. 引用计数生命周期管理

```zig
const ActorLoopData = struct {
    actor: *CounterActor,
    system: *HighPerfActorSystem,
    allocator: Allocator,
    is_active: AtomicValue(bool),
    ref_count: AtomicValue(u32),
    
    pub fn addRef(self: *ActorLoopData) void
    pub fn release(self: *ActorLoopData) void
};
```

## 容错机制

### 监督策略

1. **OneForOne**: 仅重启失败的Actor
2. **OneForAll**: 当一个失败时重启所有子Actor
3. **RestForOne**: 重启失败的Actor及其后启动的所有Actor

### 错误处理流程

```
Actor错误
    ↓
监督者决策
    ↓
┌─────────────┬─────────────┬─────────────┐
│    重启     │    停止     │    上报     │
│             │             │             │
│ Actor       │ Actor       │ 父级        │
│ 重启        │ 停止        │ 监督者      │
└─────────────┴─────────────┴─────────────┘
```

## 配置系统

### 性能配置

```zig
pub const PerformanceConfig = struct {
    // 消息处理
    batch_size: u32 = 64,
    max_spin_cycles: u32 = 1000,
    
    // 内存管理
    arena_size: usize = 64 * 1024 * 1024, // 64MB
    message_pool_size: u32 = 10000,
    actor_pool_size: u32 = 1000,
    
    // 调度 (基于Akka最佳实践)
    worker_threads: u32 = 0, // 自动检测
    worker_queue_capacity: u32 = 4096,
    global_queue_capacity: u32 = 32768,
    actor_mailbox_capacity: u32 = 65536,
    
    // 优化选项
    enable_zero_copy: bool = true,
    enable_batching: bool = true,
    enable_work_stealing: bool = true,
};
```

## 监控和可观测性

### 性能指标

- **消息吞吐量**: 每秒处理的消息数
- **延迟分布**: P50、P95、P99消息处理时间
- **队列利用率**: 邮箱和调度器队列大小
- **Actor生命周期**: 创建、重启和终止率
- **内存使用**: 堆分配和对象池利用率

### 实时统计

```zig
pub const SystemStats = struct {
    actors_created: AtomicValue(u64),
    messages_processed: AtomicValue(u64),
    total_processing_time: AtomicValue(u64),
    queue_overflows: AtomicValue(u64),
    
    pub fn getThroughput(self: *const Self) f64
    pub fn getAverageLatency(self: *const Self) f64
};
```

## 未来架构增强

### 1. 分布式Actor支持
- 网络透明的Actor引用
- 集群成员和故障检测
- 消息序列化和路由

### 2. 持久化Actor
- 事件溯源集成
- 快照和恢复机制
- 持久化消息队列

### 3. 高级调度
- 基于优先级的消息处理
- 截止时间感知调度
- 资源感知负载均衡

---

这个架构为ZActor的世界级性能提供了基础，同时保持了Zig提供的简洁性和安全性。
