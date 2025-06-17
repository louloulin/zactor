# ZActor 中文文档

欢迎来到ZActor的完整中文文档，这是一个用Zig语言实现的世界级高性能Actor系统。

## 📚 文档概览

ZActor实现了**970万消息/秒**的吞吐量和企业级可靠性。本文档提供了构建高性能、容错应用程序所需的一切信息。

## 🚀 快速导航

### 新手用户
1. 从[项目README](../../README-zh.md)开始了解概览和快速开始
2. 按照[快速开始指南](../../README-zh.md#快速开始)操作
3. 探索基础示例(计划中)
4. 阅读[架构指南](architecture.md)深入理解

### 开发者
1. 查看[API参考](api.md)获取详细接口文档
2. 学习高级示例(计划中)了解复杂模式
3. 遵循性能指南(计划中)进行优化
4. 查看路线图(计划中)了解即将推出的功能

### 性能工程师
1. 阅读性能指南(计划中)进行基准测试和优化
2. 学习高性能示例(计划中)
3. 查看[架构优化](architecture.md#性能优化)
4. 运行压力测试 `zig build zactor-stress-test`

## 📖 核心文档

### [架构指南](architecture.md)
全面的系统设计文档，涵盖：
- **核心设计原则** - 零成本抽象、无锁设计、内存效率
- **系统架构** - 组件概览和交互模式
- **性能优化** - 队列容量设计、内存布局、引用计数
- **容错机制** - 监督策略和错误处理
- **配置系统** - 性能调优和监控

### [API参考](api.md)
完整的API文档，包括：
- **核心类型** - ActorSystem、Actor、ActorRef、FastMessage
- **高性能组件** - SPSCQueue、Scheduler、工作窃取
- **配置** - PerformanceConfig和优化设置
- **错误处理** - 错误类型和最佳实践
- **Actor行为接口** - 实现指南和示例

### 性能指南 (计划中)
优化技术和基准测试：
- **验证基准测试** - 970万msg/s压力测试结果
- **行业对比** - 与Akka、Orleans、Actix的性能对比
- **性能架构** - 无锁队列、工作窃取调度器
- **调优技术** - 批处理、CPU亲和性、内存预取
- **监控** - 实时指标和故障排除

### 示例指南 (计划中)
全面的使用示例：
- **基础示例** - 简单计数器、ping-pong通信
- **高级示例** - 监督树、容错机制
- **高性能示例** - 压力测试、优化模式
- **最佳实践** - Actor设计、消息模式、系统配置

### 路线图 (计划中)
未来发展计划：
- **短期(v0.2.0)** - 性能增强、可靠性改进
- **中期(v0.3.0)** - 分布式Actor支持、开发者体验
- **长期(v1.0.0)** - AI/ML集成、云原生特性
- **性能目标** - 1500万+msg/s、分布式吞吐量目标

## 🎯 关键特性

### 高性能架构
- **970万msg/s吞吐量** - 压力测试验证结果
- **无锁队列** - 基于原子操作的SPSC/MPSC队列
- **工作窃取调度器** - 8线程并行处理
- **零拷贝消息** - 64字节优化的FastMessage
- **批处理** - 每批最多128条消息

### 企业级特性
- **内存安全** - Zig的编译时保证
- **容错机制** - 监督树和错误恢复
- **资源管理** - 自动清理和生命周期管理
- **跨平台** - Windows、Linux、macOS支持
- **性能监控** - 实时指标和统计

## 📊 性能亮点

| 测试场景 | 消息数 | Actor数 | 吞吐量 | 延迟 |
|----------|--------|---------|--------|------|
| **轻量负载** | 1万 | 5 | **940万 msg/s** | 1.06ms |
| **中等负载** | 10万 | 20 | **970万 msg/s** | 10.27ms |
| **重负载** | 100万+ | 100+ | **850万+ msg/s** | <50ms |

### 行业对比
- 比Akka **快2-10倍**
- 比Orleans **快1.2-5倍**
- 比Actix **快1.6-3倍**

## 🧪 快速开始

### 安装
```bash
# 克隆仓库
git clone https://github.com/your-username/zactor.git
cd zactor

# 构建库
zig build

# 运行测试
zig build test

# 运行性能基准测试
zig build zactor-stress-test
```

### 第一个Actor
```zig
const std = @import("std");
const zactor = @import("zactor");

const CounterActor = struct {
    count: u32 = 0,
    
    pub fn receive(self: *@This(), message: zactor.Message, context: *zactor.ActorContext) !void {
        if (std.mem.eql(u8, message.getData(), "increment")) {
            self.count += 1;
            std.log.info("计数: {}", .{self.count});
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

## 🔧 运行示例

```bash
# 基础示例
zig build run-basic              # 简单计数器Actor
zig build run-ping-pong          # Actor间通信
zig build run-supervisor         # 监督和容错

# 性能示例
zig build zactor-stress-test     # 高性能压力测试
zig build high-perf-test         # 高性能Actor系统
zig build simple-high-perf-test  # 简单性能验证
```

## 🤝 贡献

我们欢迎对ZActor的贡献！请查看我们的贡献指南：

1. **代码质量** - 所有测试必须通过，代码遵循Zig约定
2. **性能** - 维持或改进现有性能基准
3. **文档** - 更新相关文档和示例
4. **测试** - 为新功能添加全面的测试覆盖

## 📞 获取帮助

### 社区资源
- **[GitHub Issues](https://github.com/your-username/zactor/issues)** - 错误报告和功能请求
- **[GitHub Discussions](https://github.com/your-username/zactor/discussions)** - 社区讨论
- **[项目Wiki](https://github.com/your-username/zactor/wiki)** - 额外文档

### 文档反馈
- 发现错误？[提交issue](https://github.com/your-username/zactor/issues)
- 有建议？[开始讨论](https://github.com/your-username/zactor/discussions)
- 想要贡献？[提交pull request](https://github.com/your-username/zactor/pulls)

## 🔗 相关项目

- **[Actix](https://github.com/actix/actix)** - Rust Actor框架(灵感来源)
- **[Akka](https://akka.io/)** - JVM Actor系统
- **[Orleans](https://github.com/dotnet/orleans)** - .NET虚拟Actor框架
- **[CAF](https://github.com/actor-framework/actor-framework)** - C++ Actor框架

---

**ZActor 中文文档** - 您的世界级Actor系统性能指南 🚀

*最后更新: 2024-06-16*
