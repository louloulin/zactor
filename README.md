# ZActor - High-Performance Actor System in Zig

ZActor是一个用Zig语言实现的高性能、低延迟Actor系统，灵感来源于Rust的Actix框架，专为系统编程和并发执行而设计。

## 🚀 特性

### 核心特性
- **高性能**: 无锁MPSC队列，亚微秒级消息传递延迟
- **低延迟**: 工作窃取调度器，线性扩展到可用CPU核心
- **内存安全**: 引用计数的内存管理，零拷贝消息传递
- **类型安全**: 编译时类型检查，类型安全的消息系统

### 架构特性
- **Actor模型**: 隔离的Actor与消息传递
- **邮箱系统**: 异步消息队列
- **监督树**: 容错和Actor生命周期管理
- **地址系统**: Actor引用和消息路由
- **上下文管理**: Actor执行上下文和状态

### 性能优化
- **无锁数据结构**: 基于FAA (Fetch-And-Add) 的MPSC队列
- **工作窃取**: 负载均衡的多线程调度
- **架构优化**: x86_64 FAA vs ARM64 CAS优化
- **内存效率**: 对象池和高效内存分配

## 📋 系统要求

- **Zig**: 0.14.0 或更高版本
- **操作系统**: Windows, Linux, macOS
- **架构**: x86_64, ARM64

## 🛠️ 安装

### 安装Zig

#### Windows (推荐使用Chocolatey)
```powershell
choco install zig
```

#### 手动安装
1. 从 [Zig官网](https://ziglang.org/download/) 下载对应平台的版本
2. 解压到目标目录
3. 将Zig可执行文件路径添加到PATH环境变量

### 验证安装
```bash
zig version
# 应该输出: 0.14.0 或更高版本
```

## 🏗️ 构建

```bash
# 构建库
zig build

# 运行测试
zig build test

# 运行基准测试
zig build benchmark
```

## 📖 快速开始

### 基本示例

```zig
const std = @import("std");
const zactor = @import("zactor");

// 定义一个简单的Counter Actor
const CounterActor = struct {
    const Self = @This();
    
    count: u32,
    name: []const u8,
    
    pub fn init(name: []const u8) Self {
        return Self{ .count = 0, .name = name };
    }
    
    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                if (std.mem.eql(u8, message.data.user.payload, "\"increment\"")) {
                    self.count += 1;
                    std.log.info("Counter '{}' incremented to: {}", .{ self.name, self.count });
                }
            },
            .system => {
                switch (message.data.system) {
                    .ping => std.log.info("Counter '{}' received ping", .{self.name}),
                    else => {},
                }
            },
            .control => {},
        }
    }
    
    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Counter '{}' starting", .{self.name});
    }
    
    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Counter '{}' stopping with count: {}", .{ self.name, self.count });
    }
    
    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("Counter '{}' restarting due to: {}", .{ self.name, reason });
    }
    
    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Counter '{}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // 初始化ZActor配置
    zactor.init(.{
        .max_actors = 100,
        .scheduler_threads = 4,
        .enable_work_stealing = true,
    });
    
    // 创建Actor系统
    var system = try zactor.ActorSystem.init("my-system", allocator);
    defer system.deinit();
    
    // 启动系统
    try system.start();
    
    // 生成Actor
    const counter = try system.spawn(CounterActor, CounterActor.init("Counter-1"));
    
    // 发送消息
    try counter.send([]const u8, "increment", allocator);
    try counter.sendSystem(.ping);
    
    // 等待消息处理
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // 获取系统统计
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();
    
    // 优雅关闭
    system.shutdown();
}
```

## 🏛️ 架构

### 核心组件

1. **ActorSystem** - 管理所有Actor的生命周期
2. **Actor** - 基本的计算单元，处理消息
3. **Mailbox** - 高性能的MPSC消息队列
4. **Scheduler** - 工作窃取的多线程调度器
5. **ActorRef** - Actor的安全引用
6. **Message** - 类型安全的消息系统

### 消息类型

- **User Messages**: 用户定义的业务消息
- **System Messages**: 系统控制消息 (start, stop, restart, ping, pong)
- **Control Messages**: 运行时控制消息 (shutdown, suspend, resume)

## 📊 性能

### 目标性能指标
- **延迟**: < 1μs 本地消息传递
- **吞吐量**: > 10M 消息/秒
- **内存**: < 1KB 每个Actor的开销
- **扩展性**: 线性扩展到可用CPU核心

### 基准测试

运行性能基准测试：
```bash
zig build benchmark
```

## 🧪 测试

```bash
# 运行所有测试
zig build test

# 运行特定模块测试
zig test src/mailbox.zig
zig test src/actor.zig
```

## 📚 示例

查看 `examples/` 目录中的更多示例：

- `basic.zig` - 基本Actor使用
- `ping_pong.zig` - Actor间通信示例

## 🤝 贡献

欢迎贡献代码！请确保：

1. 代码通过所有测试
2. 遵循Zig代码风格
3. 添加适当的测试覆盖
4. 更新相关文档

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件

## 🔗 相关项目

- [Actix](https://github.com/actix/actix) - Rust Actor框架
- [Akka](https://akka.io/) - JVM Actor系统
- [Erlang/OTP](https://www.erlang.org/) - Erlang Actor模型

## 📞 联系

如有问题或建议，请创建Issue或Pull Request。

---

**ZActor** - 为高性能系统编程而生的Actor框架 🚀
