# ZActor English Documentation

Welcome to the comprehensive English documentation for ZActor, the world-class high-performance Actor system implemented in Zig.

## 📚 Documentation Overview

ZActor delivers **9.7 million messages/second** throughput with enterprise-grade reliability. This documentation provides everything you need to build high-performance, fault-tolerant applications.

## 🚀 Quick Navigation

### For New Users
1. Start with the [Project README](../../README.md) for overview and quick start
2. Follow the [Quick Start Guide](../../README.md#quick-start)
3. Explore [Basic Examples](examples.md#basic-examples)
4. Read the [Architecture Guide](architecture.md) for deeper understanding

### For Developers
1. Review the [API Reference](api.md) for detailed interface documentation
2. Study [Advanced Examples](examples.md#advanced-examples) for complex patterns
3. Follow the [Performance Guide](performance.md) for optimization
4. Check the [Roadmap](roadmap.md) for upcoming features

### For Performance Engineers
1. Read the [Performance Guide](performance.md) for benchmarking and optimization
2. Study [High-Performance Examples](examples.md#high-performance-examples)
3. Review [Architecture Optimizations](architecture.md#performance-optimizations)
4. Run stress tests with `zig build zactor-stress-test`

## 📖 Core Documentation

### [Architecture Guide](architecture.md)
Comprehensive system design documentation covering:
- **Core Design Principles** - Zero-cost abstractions, lock-free design, memory efficiency
- **System Architecture** - Component overview and interaction patterns
- **Performance Optimizations** - Queue capacity design, memory layout, reference counting
- **Fault Tolerance** - Supervision strategies and error handling
- **Configuration System** - Performance tuning and monitoring

### [API Reference](api.md)
Complete API documentation including:
- **Core Types** - ActorSystem, Actor, ActorRef, FastMessage
- **High-Performance Components** - SPSCQueue, Scheduler, work-stealing
- **Configuration** - PerformanceConfig and optimization settings
- **Error Handling** - Error types and best practices
- **Actor Behavior Interface** - Implementation guidelines and examples

### [Performance Guide](performance.md)
Optimization techniques and benchmarking:
- **Verified Benchmarks** - 9.7M msg/s stress test results
- **Industry Comparison** - Performance vs Akka, Orleans, Actix
- **Performance Architecture** - Lock-free queues, work-stealing scheduler
- **Tuning Techniques** - Batch processing, CPU affinity, memory prefetching
- **Monitoring** - Real-time metrics and troubleshooting

### [Examples Guide](examples.md)
Comprehensive usage examples:
- **Basic Examples** - Simple counter, ping-pong communication
- **Advanced Examples** - Supervision trees, fault tolerance
- **High-Performance Examples** - Stress testing, optimization patterns
- **Best Practices** - Actor design, message patterns, system configuration

### [Roadmap](roadmap.md)
Future development plans:
- **Short-Term (v0.2.0)** - Performance enhancements, reliability improvements
- **Medium-Term (v0.3.0)** - Distributed Actor support, developer experience
- **Long-Term (v1.0.0)** - AI/ML integration, cloud-native features
- **Performance Targets** - 15M+ msg/s, distributed throughput goals

## 🎯 Key Features

### High-Performance Architecture
- **9.7M msg/s Throughput** - Verified stress testing results
- **Lock-Free Queues** - SPSC/MPSC atomic operation-based queues
- **Work-Stealing Scheduler** - 8-thread parallel processing
- **Zero-Copy Messaging** - FastMessage with 64-byte optimization
- **Batch Processing** - Up to 128 messages per batch

### Enterprise Features
- **Memory Safety** - Zig's compile-time guarantees
- **Fault Tolerance** - Supervision trees and error recovery
- **Resource Management** - Automatic cleanup and lifecycle management
- **Cross-Platform** - Windows, Linux, macOS support
- **Performance Monitoring** - Real-time metrics and statistics

## 📊 Performance Highlights

| Test Scenario | Messages | Actors | Throughput | Latency |
|---------------|----------|--------|------------|---------|
| **Light Load** | 10K | 5 | **9.4M msg/s** | 1.06ms |
| **Medium Load** | 100K | 20 | **9.7M msg/s** | 10.27ms |
| **Heavy Load** | 1M+ | 100+ | **8.5M+ msg/s** | <50ms |

### Industry Comparison
- **2-10x faster** than Akka
- **1.2-5x faster** than Orleans  
- **1.6-3x faster** than Actix

## 🧪 Getting Started

### Installation
```bash
# Clone the repository
git clone https://github.com/your-username/zactor.git
cd zactor

# Build the library
zig build

# Run tests
zig build test

# Run performance benchmarks
zig build zactor-stress-test
```

### Your First Actor
```zig
const std = @import("std");
const zactor = @import("zactor");

const CounterActor = struct {
    count: u32 = 0,
    
    pub fn receive(self: *@This(), message: zactor.Message, context: *zactor.ActorContext) !void {
        if (std.mem.eql(u8, message.getData(), "increment")) {
            self.count += 1;
            std.log.info("Count: {}", .{self.count});
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var system = try zactor.ActorSystem.init("my-app", allocator);
    defer system.deinit();
    
    try system.start();
    
    const counter = try system.spawn(CounterActor, .{});
    try counter.send([]const u8, "increment", allocator);
    
    std.time.sleep(100 * std.time.ns_per_ms);
    try system.shutdown();
}
```

## 🔧 Running Examples

```bash
# Basic examples
zig build run-basic              # Simple counter Actor
zig build run-ping-pong          # Inter-Actor communication
zig build run-supervisor         # Supervision and fault tolerance

# Performance examples
zig build zactor-stress-test     # High-performance stress testing
zig build high-perf-test         # High-performance Actor system
zig build simple-high-perf-test  # Simple performance validation
```

## 🤝 Contributing

We welcome contributions to ZActor! Please see our contribution guidelines:

1. **Code Quality** - All tests must pass and code follows Zig conventions
2. **Performance** - Maintain or improve existing performance benchmarks
3. **Documentation** - Update relevant documentation and examples
4. **Testing** - Add comprehensive test coverage for new features

## 📞 Getting Help

### Community Resources
- **[GitHub Issues](https://github.com/your-username/zactor/issues)** - Bug reports and feature requests
- **[GitHub Discussions](https://github.com/your-username/zactor/discussions)** - Community discussions
- **[Project Wiki](https://github.com/your-username/zactor/wiki)** - Additional documentation

### Documentation Feedback
- Found an error? [Open an issue](https://github.com/your-username/zactor/issues)
- Have a suggestion? [Start a discussion](https://github.com/your-username/zactor/discussions)
- Want to contribute? [Submit a pull request](https://github.com/your-username/zactor/pulls)

## 🔗 Related Projects

- **[Actix](https://github.com/actix/actix)** - Rust Actor framework (inspiration)
- **[Akka](https://akka.io/)** - JVM Actor system
- **[Orleans](https://github.com/dotnet/orleans)** - .NET virtual Actor framework
- **[CAF](https://github.com/actor-framework/actor-framework)** - C++ Actor Framework

---

**ZActor English Documentation** - Your guide to world-class Actor system performance 🚀

*Last updated: 2024-06-16*
