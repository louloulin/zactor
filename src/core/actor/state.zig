//! Actor状态定义
//! 定义了Actor在其生命周期中的各种状态

const std = @import("std");

/// Actor状态枚举
/// 表示Actor在其生命周期中的不同阶段
pub const ActorState = enum {
    /// 已创建但未启动
    created,
    /// 正在启动
    starting,
    /// 正在运行
    running,
    /// 正在停止
    stopping,
    /// 已停止
    stopped,
    /// 正在重启
    restarting,
    /// 发生错误
    error_state,
    /// 已终止
    terminated,

    /// 检查状态是否为活跃状态
    pub fn isActive(self: ActorState) bool {
        return switch (self) {
            .running, .starting, .restarting => true,
            else => false,
        };
    }

    /// 检查状态是否为终止状态
    pub fn isTerminated(self: ActorState) bool {
        return switch (self) {
            .stopped, .terminated => true,
            else => false,
        };
    }

    /// 检查是否可以转换到目标状态
    pub fn canTransitionTo(self: ActorState, target: ActorState) bool {
        return switch (self) {
            .created => switch (target) {
                .starting, .terminated => true,
                else => false,
            },
            .starting => switch (target) {
                .running, .error_state, .stopping => true,
                else => false,
            },
            .running => switch (target) {
                .stopping, .restarting, .error_state => true,
                else => false,
            },
            .stopping => switch (target) {
                .stopped, .error_state => true,
                else => false,
            },
            .stopped => switch (target) {
                .starting, .terminated => true,
                else => false,
            },
            .restarting => switch (target) {
                .starting, .error_state, .terminated => true,
                else => false,
            },
            .error_state => switch (target) {
                .stopping, .terminated => true,
                else => false,
            },
            .terminated => false, // 终止状态不能转换到其他状态
        };
    }
};

// 测试
test "ActorState basic functionality" {
    const testing = std.testing;
    
    // 测试基本状态
    const created = ActorState.created;
    const running = ActorState.running;
    const stopped = ActorState.stopped;
    
    try testing.expect(created == .created);
    try testing.expect(running == .running);
    try testing.expect(stopped == .stopped);
}

test "ActorState isActive" {
    const testing = std.testing;
    
    try testing.expect(ActorState.running.isActive());
    try testing.expect(ActorState.starting.isActive());
    try testing.expect(ActorState.restarting.isActive());
    
    try testing.expect(!ActorState.created.isActive());
    try testing.expect(!ActorState.stopped.isActive());
    try testing.expect(!ActorState.terminated.isActive());
}

test "ActorState isTerminated" {
    const testing = std.testing;
    
    try testing.expect(ActorState.stopped.isTerminated());
    try testing.expect(ActorState.terminated.isTerminated());
    
    try testing.expect(!ActorState.running.isTerminated());
    try testing.expect(!ActorState.created.isTerminated());
}

test "ActorState transitions" {
    const testing = std.testing;
    
    // 测试有效转换
    try testing.expect(ActorState.created.canTransitionTo(.starting));
    try testing.expect(ActorState.starting.canTransitionTo(.running));
    try testing.expect(ActorState.running.canTransitionTo(.stopping));
    try testing.expect(ActorState.stopping.canTransitionTo(.stopped));
    
    // 测试无效转换
    try testing.expect(!ActorState.created.canTransitionTo(.running));
    try testing.expect(!ActorState.terminated.canTransitionTo(.running));
    try testing.expect(!ActorState.stopped.canTransitionTo(.running));
}