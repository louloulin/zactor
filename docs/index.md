# ZActor Documentation Index

Welcome to the comprehensive documentation for ZActor, the world-class high-performance Actor system implemented in Zig.

## 📚 Documentation Overview

### Getting Started
- **[README](../README.md)** - Project overview, quick start, and basic usage
- **[README-zh](../README-zh.md)** - 中文版项目概述和快速开始

### Core Documentation

#### English Documentation
- **[English Documentation Index](en/)** - Complete English documentation
- **[Architecture Guide](en/architecture.md)** - System design, components, and performance optimizations
- **[API Reference](en/api.md)** - Complete API documentation with examples
- **[Performance Guide](en/performance.md)** - Optimization techniques and benchmarking
- **[Examples Guide](en/examples.md)** - Comprehensive usage examples and patterns
- **[Roadmap](en/roadmap.md)** - Future development plans and feature roadmap

#### Chinese Documentation (中文文档)
- **[中文文档索引](zh/)** - 完整中文文档
- **[架构指南](zh/architecture.md)** - 系统设计、组件和性能优化
- **[API参考](zh/api.md)** - 完整的API文档和示例

## 🚀 Quick Navigation

### For New Users
1. Start with the [README](../README.md) for project overview
2. Follow the [Quick Start](../README.md#quick-start) guide
3. Explore [Basic Examples](en/examples.md#basic-examples)
4. Read the [Architecture Guide](en/architecture.md) for deeper understanding

### For Developers
1. Review the [API Reference](en/api.md) for detailed interface documentation
2. Study [Advanced Examples](en/examples.md#advanced-examples) for complex patterns
3. Follow the [Performance Guide](en/performance.md) for optimization
4. Check the [Roadmap](en/roadmap.md) for upcoming features

### For Performance Engineers
1. Read the [Performance Guide](en/performance.md) for benchmarking and optimization
2. Study [High-Performance Examples](en/examples.md#high-performance-examples)
3. Review [Architecture Optimizations](en/architecture.md#performance-optimizations)
4. Run stress tests with `zig build zactor-stress-test`

## 📖 Documentation Structure

### English Documentation Structure
```
docs/en/
├── index.md            # English documentation index
├── architecture.md     # System design and components
├── api.md             # Complete API reference
├── performance.md     # Performance optimization guide
├── examples.md        # Usage examples and patterns
└── roadmap.md         # Future development plans
```

### Chinese Documentation Structure
```
docs/zh/
├── index.md           # 中文文档索引
├── architecture.md    # 系统设计和组件
└── api.md            # 完整API参考
```

### Project Documentation
```
docs/
└── index.md          # This documentation index
```

## 🎯 Key Features Covered

### Core Actor System
- **Actor Lifecycle Management** - Creation, supervision, and termination
- **Type-Safe Messaging** - Compile-time verified message system
- **Fault Tolerance** - Supervision trees and error recovery
- **Location Transparency** - ActorRef with network transparency

### High-Performance Features
- **9.7M msg/s Throughput** - Verified stress testing results
- **Lock-Free Queues** - SPSC/MPSC atomic operation-based queues
- **Work-Stealing Scheduler** - 8-thread parallel processing
- **Zero-Copy Messaging** - FastMessage optimization
- **Batch Processing** - Up to 128 messages per batch

### Enterprise Features
- **Memory Safety** - Zig's compile-time guarantees
- **Resource Management** - Automatic cleanup and lifecycle management
- **Cross-Platform** - Windows, Linux, macOS support
- **Performance Monitoring** - Real-time metrics and statistics

## 🔧 Code Examples

### Basic Actor Usage
```zig
// Create Actor system
var system = try zactor.ActorSystem.init("my-app", allocator);
defer system.deinit();

try system.start();

// Spawn an Actor
const counter = try system.spawn(CounterActor, CounterActor.init("MyCounter"));

// Send messages
try counter.send([]const u8, "increment", allocator);

// Graceful shutdown
try system.shutdown();
```

### High-Performance Configuration
```zig
const config = PerformanceConfig{
    .batch_size = 128,
    .worker_queue_capacity = 8192,
    .actor_mailbox_capacity = 131072,
    .enable_zero_copy = true,
    .enable_batching = true,
};
```

## 📊 Performance Benchmarks

| Test Scenario | Messages | Actors | Throughput | Latency |
|---------------|----------|--------|------------|---------|
| **Light Load** | 10K | 5 | **9.4M msg/s** | 1.06ms |
| **Medium Load** | 100K | 20 | **9.7M msg/s** | 10.27ms |
| **Heavy Load** | 1M+ | 100+ | **8.5M+ msg/s** | <50ms |

### Industry Comparison
- **2-10x faster** than Akka
- **1.2-5x faster** than Orleans  
- **1.6-3x faster** than Actix

## 🧪 Testing and Examples

### Running Examples
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

### Testing
```bash
# Run all tests
zig build test

# Run specific test suites
zig build test-integration
zig build test-performance
zig build test-ultra-performance
```

## 🤝 Contributing to Documentation

We welcome contributions to improve our documentation:

### Documentation Guidelines
1. **Clarity**: Write clear, concise explanations
2. **Examples**: Include practical code examples
3. **Accuracy**: Ensure technical accuracy
4. **Completeness**: Cover all relevant aspects

### How to Contribute
1. **Issues**: Report documentation issues on GitHub
2. **Pull Requests**: Submit improvements and additions
3. **Translations**: Help translate documentation to other languages
4. **Examples**: Contribute new examples and use cases

### Documentation Standards
- Use clear, professional language
- Include code examples for all features
- Maintain consistency across documents
- Update examples when APIs change

## 📞 Getting Help

### Community Resources
- **[GitHub Issues](https://github.com/louloulin/zactor/issues)** - Bug reports and feature requests
- **[GitHub Discussions](https://github.com/louloulin/zactor/discussions)** - Community discussions
- **[Project Wiki](https://github.com/louloulin/zactor/wiki)** - Additional documentation

### Documentation Feedback
- Found an error? [Open an issue](https://github.com/louloulin/zactor/issues)
- Have a suggestion? [Start a discussion](https://github.com/louloulin/zactor/discussions)
- Want to contribute? [Submit a pull request](https://github.com/louloulin/zactor/pulls)

## 🔗 External Resources

### Related Projects
- **[Actix](https://github.com/actix/actix)** - Rust Actor framework (inspiration)
- **[Akka](https://akka.io/)** - JVM Actor system
- **[Orleans](https://github.com/dotnet/orleans)** - .NET virtual Actor framework

### Learning Resources
- **[Actor Model](https://en.wikipedia.org/wiki/Actor_model)** - Wikipedia overview
- **[Zig Language](https://ziglang.org/)** - Official Zig documentation
- **[Concurrent Programming](https://en.wikipedia.org/wiki/Concurrent_computing)** - Concurrency concepts

---

**ZActor Documentation** - Comprehensive guide to world-class Actor system performance 🚀

*Last updated: 2024-06-16*
