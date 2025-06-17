# ZActor Architecture Guide

## Overview

ZActor is a high-performance Actor system implemented in Zig, designed for systems programming with enterprise-grade performance and reliability. The architecture follows the Actor model with modern optimizations for multi-core systems.

## Core Design Principles

### 1. Zero-Cost Abstractions
- **Compile-time optimization**: Leverages Zig's `comptime` for zero runtime overhead
- **Type erasure elimination**: Direct function calls instead of virtual dispatch
- **Memory layout optimization**: Cache-friendly data structures

### 2. Lock-Free Design
- **SPSC/MPSC queues**: Single/Multi-producer, Single-consumer queues
- **Atomic operations**: CAS and FAA operations for synchronization
- **Work-stealing**: Lock-free task distribution across threads

### 3. Memory Efficiency
- **Arena allocators**: Bulk memory allocation for reduced fragmentation
- **Object pools**: Reusable message and Actor objects
- **Reference counting**: Automatic memory management with atomic counters

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                        │
├─────────────────────────────────────────────────────────────┤
│                     Actor System                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Actor A   │  │   Actor B   │  │   Actor C   │         │
│  │             │  │             │  │             │         │
│  │  Mailbox    │  │  Mailbox    │  │  Mailbox    │         │
│  │  (64K)      │  │  (64K)      │  │  (64K)      │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
├─────────────────────────────────────────────────────────────┤
│                    Scheduler Layer                          │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              Work-Stealing Scheduler                    │ │
│  │                                                         │ │
│  │  Worker 1    Worker 2    Worker 3    Worker 4          │ │
│  │  (4K Queue)  (4K Queue)  (4K Queue)  (4K Queue)        │ │
│  │      │           │           │           │              │ │
│  │      └───────────┼───────────┼───────────┘              │ │
│  │                  │           │                          │ │
│  │              Global Queue (32K)                         │ │
│  └─────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                   Infrastructure Layer                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Memory    │  │  Messaging  │  │   Utils     │         │
│  │   Manager   │  │   System    │  │   & Tools   │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. ActorSystem

**Purpose**: Central coordinator for all Actors and system resources.

**Key Features**:
- Actor lifecycle management (spawn, stop, restart)
- Resource allocation and cleanup
- System-wide configuration and monitoring
- Graceful shutdown coordination

**Implementation**:
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

### 2. Actor

**Purpose**: Fundamental computation unit with isolated state.

**Key Features**:
- Isolated state and behavior
- Asynchronous message processing
- Lifecycle hooks (preStart, postStop, preRestart, postRestart)
- Error handling and supervision

**Implementation**:
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

### 3. High-Performance Messaging

**FastMessage**: Optimized 64-byte message structure
```zig
pub const FastMessage = struct {
    sender: ActorId,      // 8 bytes
    receiver: ActorId,    // 8 bytes
    message_type: MessageType, // 4 bytes
    timestamp: i64,       // 8 bytes
    data: [32]u8,        // 32 bytes - inline data
    metadata: u32,       // 4 bytes
    
    pub fn init(sender: ActorId, receiver: ActorId, msg_type: MessageType) FastMessage
    pub fn setData(self: *FastMessage, data: []const u8) void
    pub fn getData(self: *const FastMessage) []const u8
};
```

### 4. Work-Stealing Scheduler

**Purpose**: Efficient multi-threaded task distribution.

**Key Features**:
- 8 worker threads with local queues (4K capacity each)
- Global queue for load balancing (32K capacity)
- Work-stealing algorithm for optimal CPU utilization
- Batch processing for reduced overhead

**Queue Hierarchy**:
```
Worker Local Queues (4K each)
    ↓ (when empty, steal from others)
Global Queue (32K)
    ↓ (when local queues full)
Actor Mailboxes (64K each)
```

### 5. SPSC Queue Implementation

**Purpose**: Lock-free single-producer, single-consumer queue.

**Key Features**:
- Atomic head/tail pointers
- Power-of-2 capacity for efficient modulo operations
- Memory ordering guarantees (acquire/release semantics)
- Overflow protection with wrapping arithmetic

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

## Performance Optimizations

### 1. Queue Capacity Design (Based on Akka Best Practices)

| Component | Capacity | Purpose |
|-----------|----------|---------|
| **Worker Local Queue** | 4K | Fast local processing |
| **Global Queue** | 32K | Load balancing |
| **Actor Mailbox** | 64K | Message buffering |
| **Ultra-Fast Config** | 128K | Extreme performance |

### 2. Memory Layout Optimization

- **Cache-line alignment**: Critical data structures aligned to 64-byte boundaries
- **False sharing prevention**: Atomic variables separated by cache lines
- **Batch processing**: Process up to 128 messages per batch to amortize overhead

### 3. Reference Counting Lifecycle Management

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

## Fault Tolerance

### Supervision Strategies

1. **OneForOne**: Restart only the failed Actor
2. **OneForAll**: Restart all child Actors when one fails
3. **RestForOne**: Restart the failed Actor and all Actors started after it

### Error Handling Flow

```
Actor Error
    ↓
Supervisor Decision
    ↓
┌─────────────┬─────────────┬─────────────┐
│   Restart   │    Stop     │  Escalate   │
│             │             │             │
│ Actor       │ Actor       │ Parent      │
│ Restarts    │ Stops       │ Supervisor  │
└─────────────┴─────────────┴─────────────┘
```

## Configuration System

### Performance Configurations

```zig
pub const PerformanceConfig = struct {
    // Message processing
    batch_size: u32 = 64,
    max_spin_cycles: u32 = 1000,
    
    // Memory management
    arena_size: usize = 64 * 1024 * 1024, // 64MB
    message_pool_size: u32 = 10000,
    actor_pool_size: u32 = 1000,
    
    // Scheduling (based on Akka best practices)
    worker_threads: u32 = 0, // auto-detect
    worker_queue_capacity: u32 = 4096,
    global_queue_capacity: u32 = 32768,
    actor_mailbox_capacity: u32 = 65536,
    
    // Optimizations
    enable_zero_copy: bool = true,
    enable_batching: bool = true,
    enable_work_stealing: bool = true,
};
```

## Monitoring and Observability

### Performance Metrics

- **Message throughput**: Messages processed per second
- **Latency distribution**: P50, P95, P99 message processing times
- **Queue utilization**: Mailbox and scheduler queue sizes
- **Actor lifecycle**: Creation, restart, and termination rates
- **Memory usage**: Heap allocation and object pool utilization

### Real-time Statistics

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

## Future Architecture Enhancements

### 1. Distributed Actor Support
- Network-transparent Actor references
- Cluster membership and failure detection
- Message serialization and routing

### 2. Persistent Actors
- Event sourcing integration
- Snapshot and recovery mechanisms
- Durable message queues

### 3. Advanced Scheduling
- Priority-based message processing
- Deadline-aware scheduling
- Resource-aware load balancing

---

This architecture provides the foundation for ZActor's world-class performance while maintaining the simplicity and safety that Zig offers.
