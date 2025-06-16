const std = @import("std");
const FastMessage = @import("src/message_pool.zig").FastMessage;
const MessagePool = @import("src/message_pool.zig").MessagePool;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🔒 === 消息类型安全性验证 ===", .{});

    // 创建消息池
    var pool = try MessagePool.init(allocator);
    defer pool.deinit();

    // 测试1: 验证不同类型消息的创建和访问
    std.log.info("\n📝 测试1: 消息类型创建和安全访问", .{});
    
    // 创建字符串消息
    const str_msg = FastMessage.createUserString(1, 0, 1, "Hello World");
    std.log.info("字符串消息: type={}, valid={}", .{ str_msg.msg_type, str_msg.validate() });
    std.log.info("  isString={}, getString='{s}'", .{ str_msg.isString(), str_msg.getString() });
    std.log.info("  isInt={}, getInt={}", .{ str_msg.isInt(), str_msg.getInt() }); // 应该安全返回0
    
    // 创建整数消息
    const int_msg = FastMessage.createUserInt(2, 0, 2, 42);
    std.log.info("整数消息: type={}, valid={}", .{ int_msg.msg_type, int_msg.validate() });
    std.log.info("  isInt={}, getInt={}", .{ int_msg.isInt(), int_msg.getInt() });
    std.log.info("  isString={}, getString='{s}'", .{ int_msg.isString(), int_msg.getString() }); // 应该安全返回""
    
    // 创建浮点数消息
    const float_msg = FastMessage.createUserFloat(3, 0, 3, 3.14159);
    std.log.info("浮点数消息: type={}, valid={}", .{ float_msg.msg_type, float_msg.validate() });
    std.log.info("  isFloat={}, getFloat={d:.5}", .{ float_msg.isFloat(), float_msg.getFloat() });
    std.log.info("  isString={}, getString='{s}'", .{ float_msg.isString(), float_msg.getString() }); // 应该安全返回""
    
    // 创建系统消息
    const ping_msg = FastMessage.createSystemPing(4, 0, 4);
    std.log.info("系统消息: type={}, valid={}", .{ ping_msg.msg_type, ping_msg.validate() });
    std.log.info("  isSystem={}, isString={}", .{ ping_msg.isSystem(), ping_msg.isString() });
    std.log.info("  getString='{s}', getInt={}", .{ ping_msg.getString(), ping_msg.getInt() }); // 都应该安全返回默认值

    // 测试2: 验证消息池的获取和释放
    std.log.info("\n🔄 测试2: 消息池获取和释放安全性", .{});
    
    var acquired_messages: [5]*FastMessage = undefined;
    var acquired_count: u32 = 0;
    
    // 获取多个消息
    for (0..5) |i| {
        if (pool.acquire()) |msg| {
            acquired_messages[acquired_count] = msg;
            acquired_count += 1;
            
            // 设置不同类型的消息
            switch (i % 4) {
                0 => msg.* = FastMessage.createUserString(@intCast(i), 0, i, "test"),
                1 => msg.* = FastMessage.createUserInt(@intCast(i), 0, i, @intCast(i * 10)),
                2 => msg.* = FastMessage.createUserFloat(@intCast(i), 0, i, @as(f64, @floatFromInt(i)) * 0.5),
                3 => msg.* = FastMessage.createSystemPing(@intCast(i), 0, i),
                else => unreachable,
            }
            
            std.log.info("消息{}: type={}, valid={}", .{ i, msg.msg_type, msg.validate() });
        }
    }
    
    std.log.info("成功获取 {} 个消息", .{acquired_count});
    
    // 安全地访问每个消息
    for (acquired_messages[0..acquired_count], 0..) |msg, i| {
        std.log.info("处理消息{}: ", .{i});
        
        if (msg.isString()) {
            std.log.info("  字符串: '{s}'", .{msg.getString()});
        } else if (msg.isInt()) {
            std.log.info("  整数: {}", .{msg.getInt()});
        } else if (msg.isFloat()) {
            std.log.info("  浮点数: {d:.2}", .{msg.getFloat()});
        } else if (msg.isSystem()) {
            std.log.info("  系统消息: {}", .{msg.msg_type});
        } else {
            std.log.info("  其他类型: {}", .{msg.msg_type});
        }
    }
    
    // 释放所有消息
    for (acquired_messages[0..acquired_count]) |msg| {
        pool.release(msg);
    }
    
    std.log.info("所有消息已释放", .{});
    
    // 测试3: 验证释放后重新获取的消息状态
    std.log.info("\n♻️  测试3: 消息重用安全性", .{});
    
    for (0..3) |i| {
        if (pool.acquire()) |msg| {
            std.log.info("重用消息{}: type={}, valid={}, isString={}", .{ 
                i, msg.msg_type, msg.validate(), msg.isString() 
            });
            
            // 验证重置后的消息可以安全访问
            const str_val = msg.getString();
            const int_val = msg.getInt();
            const float_val = msg.getFloat();
            
            std.log.info("  安全访问: str='{s}', int={}, float={d:.2}", .{ str_val, int_val, float_val });
            
            pool.release(msg);
        }
    }
    
    // 测试4: 边界条件测试
    std.log.info("\n🎯 测试4: 边界条件", .{});
    
    // 测试最大长度字符串
    const max_str = "x" ** 32;
    const max_str_msg = FastMessage.createUserString(99, 0, 99, max_str);
    std.log.info("最大字符串: len={}, valid={}", .{ max_str_msg.payload_len, max_str_msg.validate() });
    std.log.info("  内容: '{s}'", .{max_str_msg.getString()});
    
    // 测试极值整数
    const max_int_msg = FastMessage.createUserInt(100, 0, 100, std.math.maxInt(i64));
    const min_int_msg = FastMessage.createUserInt(101, 0, 101, std.math.minInt(i64));
    std.log.info("最大整数: {}, valid={}", .{ max_int_msg.getInt(), max_int_msg.validate() });
    std.log.info("最小整数: {}, valid={}", .{ min_int_msg.getInt(), min_int_msg.validate() });
    
    // 获取池统计
    const stats = pool.getStats();
    std.log.info("\n📊 消息池统计:", .{});
    std.log.info("  总消息数: {}", .{stats.total_messages});
    std.log.info("  可用消息: {}", .{stats.available_messages});
    std.log.info("  使用中消息: {}", .{stats.used_messages});
    
    std.log.info("\n✅ === 消息类型安全性验证完成 ===", .{});
}
