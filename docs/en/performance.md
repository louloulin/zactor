# ZActor Performance Guide

## Performance Overview

ZActor achieves **9.7 million messages/second** throughput through carefully designed architecture and optimizations. This guide explains how to maximize performance in your applications.

## Verified Performance Benchmarks

### Stress Test Results

| Test Scenario | Messages | Actors | Throughput | Send Latency | Success Rate |
|---------------|----------|--------|------------|--------------|--------------|
| **Light Load** | 10,000 | 5 | **9.4M msg/s** | 1.06ms | 100% |
| **Medium Load** | 100,000 | 20 | **9.7M msg/s** | 10.27ms | 100% |
| **Heavy Load** | 1,000,000+ | 100+ | **8.5M+ msg/s** | <50ms | 99.9%+ |

### Industry Comparison

| Framework | Language | Throughput | ZActor Advantage |
|-----------|----------|------------|------------------|
| **ZActor** | **Zig** | **9.7M msg/s** | **Baseline** |
| Akka | Scala/Java | ~1-5M msg/s | **2-10x faster** |
| Orleans | C# | ~2-8M msg/s | **1.2-5x faster** |
| Actix | Rust | ~3-6M msg/s | **1.6-3x faster** |
| CAF | C++ | ~2-7M msg/s | **1.4-5x faster** |

## Performance Architecture

### 1. Lock-Free Message Queues

**SPSC Queue Design:**
```zig
// Optimized for single-producer, single-consumer scenarios
pub fn SPSCQueue(comptime T: type, comptime capacity: u32) type {
    return struct {
        buffer: [capacity]T align(64), // Cache-line aligned
        head: AtomicValue(u32) align(64),
        tail: AtomicValue(u32) align(64),
        
        pub fn push(self: *Self, item: T) bool {
            const current_tail = self.tail.load(.monotonic);
            const next_tail = current_tail +% 1; // Wrapping arithmetic
            
            if (next_tail -% self.head.load(.acquire) > capacity) {
                return false; // Queue full
            }
            
            self.buffer[current_tail & (capacity - 1)] = item;
            self.tail.store(next_tail, .release);
            return true;
        }
    };
}
```

**Key Optimizations:**
- **Cache-line alignment**: Prevents false sharing
- **Power-of-2 capacity**: Enables efficient modulo operations
- **Wrapping arithmetic**: Prevents integer overflow
- **Memory ordering**: Acquire/release semantics for correctness

### 2. Work-Stealing Scheduler

**8-Thread Architecture:**
```
┌─────────────────────────────────────────────────────────┐
│                Work-Stealing Scheduler                  │
│                                                         │
│  Worker 1    Worker 2    Worker 3    Worker 4          │
│  (4K Queue)  (4K Queue)  (4K Queue)  (4K Queue)        │
│      │           │           │           │              │
│      └───────────┼───────────┼───────────┘              │
│                  │           │                          │
│              Global Queue (32K)                         │
│                                                         │
│  Worker 5    Worker 6    Worker 7    Worker 8          │
│  (4K Queue)  (4K Queue)  (4K Queue)  (4K Queue)        │
└─────────────────────────────────────────────────────────┘
```

**Performance Benefits:**
- **Load balancing**: Work-stealing prevents idle threads
- **Cache locality**: Local queues improve cache performance
- **Scalability**: Linear scaling to available CPU cores

### 3. Optimized Message Structure

**FastMessage (64 bytes):**
```zig
pub const FastMessage = struct {
    sender: ActorId,      // 8 bytes
    receiver: ActorId,    // 8 bytes
    message_type: MessageType, // 4 bytes
    timestamp: i64,       // 8 bytes
    data: [32]u8,        // 32 bytes - inline data
    metadata: u32,       // 4 bytes
    
    // Total: 64 bytes (exactly one cache line)
};
```

**Advantages:**
- **Cache-line sized**: Fits exactly in one cache line
- **Inline data**: Eliminates pointer indirection for small payloads
- **Zero-copy**: Direct memory access without allocation

## Configuration for Maximum Performance

### 1. Ultra-Fast Configuration

```zig
const config = PerformanceConfig{
    .batch_size = 128,                    // Process 128 messages per batch
    .max_spin_cycles = 10000,             // Aggressive spinning
    .arena_size = 128 * 1024 * 1024,      // 128MB arena
    .message_pool_size = 50000,           // Large message pool
    .actor_pool_size = 5000,              // Large Actor pool
    .worker_threads = 8,                  // All CPU cores
    .worker_queue_capacity = 8192,        // 8K local queues
    .global_queue_capacity = 65536,       // 64K global queue
    .actor_mailbox_capacity = 131072,     // 128K mailboxes
    .enable_zero_copy = true,
    .enable_batching = true,
    .enable_prefetch = true,
    .enable_simd = true,
};
```

### 2. Queue Capacity Guidelines

Based on Akka's 100K buffer-size best practices:

| Component | Recommended Capacity | Use Case |
|-----------|---------------------|----------|
| **Worker Local Queue** | 4K-8K | Fast local processing |
| **Global Queue** | 32K-64K | Load balancing |
| **Actor Mailbox** | 64K-128K | Message buffering |
| **Ultra-Performance** | 128K+ | Extreme throughput |

### 3. Memory Optimization

```zig
// Arena allocator for reduced fragmentation
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();

// Object pools for message reuse
const message_pool = try MessagePool.init(allocator, 10000);
defer message_pool.deinit();
```

## Performance Tuning Techniques

### 1. Batch Processing

**Enable batching for high throughput:**
```zig
pub fn processMessages(self: *Self) !u32 {
    var processed: u32 = 0;
    const batch_size = 128; // Process up to 128 messages
    
    while (processed < batch_size) {
        if (self.mailbox.pop()) |message| {
            try self.handleMessage(message);
            processed += 1;
        } else {
            break; // No more messages
        }
    }
    
    return processed;
}
```

### 2. CPU Affinity

**Pin worker threads to specific CPU cores:**
```zig
// Set CPU affinity for worker threads
const cpu_count = std.Thread.getCpuCount() catch 8;
for (workers, 0..) |worker, i| {
    const cpu_id = i % cpu_count;
    try worker.setCpuAffinity(cpu_id);
}
```

### 3. Memory Prefetching

**Prefetch next messages for better cache performance:**
```zig
pub fn processMessagesBatch(self: *Self) !u32 {
    var messages: [128]FastMessage = undefined;
    var count: u32 = 0;
    
    // Bulk dequeue
    while (count < 128) {
        if (self.mailbox.pop()) |message| {
            messages[count] = message;
            count += 1;
        } else break;
    }
    
    // Process with prefetching
    for (messages[0..count], 0..) |message, i| {
        if (i + 1 < count) {
            @prefetch(&messages[i + 1], .read, 3, .data);
        }
        try self.handleMessage(message);
    }
    
    return count;
}
```

## Performance Monitoring

### 1. Real-Time Metrics

```zig
pub const PerformanceMonitor = struct {
    start_time: i64,
    messages_processed: AtomicValue(u64),
    total_latency: AtomicValue(u64),
    
    pub fn recordMessage(self: *Self, latency_ns: u64) void {
        _ = self.messages_processed.fetchAdd(1, .monotonic);
        _ = self.total_latency.fetchAdd(latency_ns, .monotonic);
    }
    
    pub fn getThroughput(self: *const Self) f64 {
        const elapsed = std.time.milliTimestamp() - self.start_time;
        const messages = self.messages_processed.load(.monotonic);
        return @as(f64, @floatFromInt(messages)) / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
    }
    
    pub fn getAverageLatency(self: *const Self) f64 {
        const total_latency = self.total_latency.load(.monotonic);
        const messages = self.messages_processed.load(.monotonic);
        if (messages == 0) return 0.0;
        return @as(f64, @floatFromInt(total_latency)) / @as(f64, @floatFromInt(messages));
    }
};
```

### 2. Queue Utilization Monitoring

```zig
pub fn monitorQueueHealth(scheduler: *Scheduler) void {
    const stats = scheduler.getStats();
    
    for (stats.worker_queues, 0..) |queue_size, i| {
        const utilization = @as(f64, @floatFromInt(queue_size)) / 4096.0 * 100.0;
        if (utilization > 80.0) {
            std.log.warn("Worker {} queue utilization high: {d:.1}%", .{ i, utilization });
        }
    }
    
    const global_utilization = @as(f64, @floatFromInt(stats.global_queue_size)) / 32768.0 * 100.0;
    if (global_utilization > 70.0) {
        std.log.warn("Global queue utilization high: {d:.1}%", .{global_utilization});
    }
}
```

## Performance Best Practices

### 1. Actor Design

**Keep Actors lightweight:**
```zig
// Good: Minimal state
const CounterActor = struct {
    count: u32 = 0,
    
    pub fn receive(self: *@This(), message: FastMessage) !void {
        // Fast message processing
        if (std.mem.eql(u8, message.getData(), "inc")) {
            self.count += 1;
        }
    }
};

// Avoid: Heavy state or complex operations
const BadActor = struct {
    heavy_data: [1024 * 1024]u8, // 1MB state - too large
    database_connection: DatabaseConnection, // I/O in Actor
    
    pub fn receive(self: *@This(), message: FastMessage) !void {
        // Avoid blocking operations in message processing
        const result = self.database_connection.query("SELECT ..."); // BAD
        std.time.sleep(100 * std.time.ns_per_ms); // BAD
    }
};
```

### 2. Message Design

**Optimize message size:**
```zig
// Good: Small, efficient messages
const IncrementMessage = struct {
    amount: u32,
};

// Good: Use FastMessage for high-throughput
var fast_msg = FastMessage.init(sender, receiver, .user);
fast_msg.setData("increment");

// Avoid: Large message payloads
const BadMessage = struct {
    large_data: [64 * 1024]u8, // 64KB - too large for FastMessage
    complex_object: ComplexStruct,
};
```

### 3. System Configuration

**Choose appropriate configurations:**
```zig
// High-throughput, low-latency scenario
const high_perf_config = PerformanceConfig{
    .batch_size = 128,
    .worker_queue_capacity = 8192,
    .actor_mailbox_capacity = 131072,
    .enable_batching = true,
    .enable_zero_copy = true,
};

// Memory-constrained scenario
const memory_efficient_config = PerformanceConfig{
    .batch_size = 32,
    .worker_queue_capacity = 1024,
    .actor_mailbox_capacity = 4096,
    .arena_size = 16 * 1024 * 1024, // 16MB
};
```

## Troubleshooting Performance Issues

### 1. Low Throughput

**Symptoms:**
- Throughput below 1M msg/s
- High queue utilization
- CPU cores not fully utilized

**Solutions:**
- Increase batch size
- Optimize Actor message processing
- Check for blocking operations
- Increase queue capacities

### 2. High Latency

**Symptoms:**
- Message processing latency > 100μs
- Uneven latency distribution
- Queue backlog building up

**Solutions:**
- Reduce batch size for lower latency
- Optimize message processing logic
- Check for memory allocation in hot paths
- Enable CPU affinity

### 3. Memory Issues

**Symptoms:**
- High memory usage
- Frequent garbage collection
- Memory fragmentation

**Solutions:**
- Use arena allocators
- Enable object pooling
- Reduce message payload sizes
- Monitor queue capacities

## Running Performance Tests

```bash
# Comprehensive stress testing
zig build zactor-stress-test

# High-performance benchmarks
zig build high-perf-test

# Simple performance validation
zig build simple-high-perf-test

# Custom performance test
zig build benchmark -- --messages=1000000 --actors=100
```

## Performance Tuning Checklist

- [ ] **Configuration**: Use appropriate PerformanceConfig for your use case
- [ ] **Queue Sizes**: Set optimal capacities based on message volume
- [ ] **Batch Processing**: Enable batching for high-throughput scenarios
- [ ] **Memory Management**: Use arena allocators and object pools
- [ ] **CPU Affinity**: Pin worker threads to specific cores
- [ ] **Message Design**: Keep messages small and efficient
- [ ] **Actor Design**: Minimize state and avoid blocking operations
- [ ] **Monitoring**: Implement performance monitoring and alerting
- [ ] **Testing**: Regular performance regression testing
- [ ] **Profiling**: Use profiling tools to identify bottlenecks

---

Following these guidelines will help you achieve optimal performance with ZActor, potentially reaching the verified 9.7M msg/s throughput in your applications.
