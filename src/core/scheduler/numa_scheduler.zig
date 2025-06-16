//! NUMA感知调度器
//! 基于NUMA拓扑优化Actor调度和内存分配

const std = @import("std");
const Allocator = std.mem.Allocator;
const Actor = @import("../actor/actor.zig").Actor;

/// NUMA节点信息
pub const NumaNode = struct {
    id: u32,
    cpu_cores: []u32,
    memory_size: u64,
    current_load: std.atomic.Value(u32),
    actor_count: std.atomic.Value(u32),

    pub fn init(id: u32, cpu_cores: []u32, memory_size: u64) NumaNode {
        return NumaNode{
            .id = id,
            .cpu_cores = cpu_cores,
            .memory_size = memory_size,
            .current_load = std.atomic.Value(u32).init(0),
            .actor_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn getLoadFactor(self: *const NumaNode) f32 {
        const load = self.current_load.load(.acquire);
        const actors = self.actor_count.load(.acquire);
        if (actors == 0) return 0.0;
        return @as(f32, @floatFromInt(load)) / @as(f32, @floatFromInt(actors));
    }

    pub fn addActor(self: *NumaNode) void {
        _ = self.actor_count.fetchAdd(1, .acq_rel);
    }

    pub fn removeActor(self: *NumaNode) void {
        _ = self.actor_count.fetchSub(1, .acq_rel);
    }

    pub fn updateLoad(self: *NumaNode, load: u32) void {
        self.current_load.store(load, .release);
    }
};

/// NUMA拓扑检测器
pub const NumaTopology = struct {
    const Self = @This();

    nodes: []NumaNode,
    allocator: Allocator,
    total_cores: u32,

    pub fn detect(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);

        // 简化的NUMA检测 - 在实际实现中应该使用系统API
        const num_cores = try std.Thread.getCpuCount();
        const nodes_per_system: usize = if (num_cores > 8) 2 else 1; // 简单启发式

        const nodes = try allocator.alloc(NumaNode, nodes_per_system);
        const cores_per_node: usize = num_cores / nodes_per_system;

        for (nodes, 0..) |*node, i| {
            const start_core = @as(u32, @intCast(i * cores_per_node));
            const end_core = if (i == nodes_per_system - 1)
                @as(u32, @intCast(num_cores))
            else
                @as(u32, @intCast((i + 1) * cores_per_node));

            const cpu_cores = try allocator.alloc(u32, end_core - start_core);
            for (cpu_cores, 0..) |*core, j| {
                core.* = start_core + @as(u32, @intCast(j));
            }

            node.* = NumaNode.init(
                @intCast(i),
                cpu_cores,
                1024 * 1024 * 1024, // 1GB per node (简化)
            );
        }

        self.* = Self{
            .nodes = nodes,
            .allocator = allocator,
            .total_cores = @intCast(num_cores),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.nodes) |*node| {
            self.allocator.free(node.cpu_cores);
        }
        self.allocator.free(self.nodes);
        self.allocator.destroy(self);
    }

    pub fn getBestNode(self: *Self) *NumaNode {
        var best_node = &self.nodes[0];
        var min_load = best_node.getLoadFactor();

        for (self.nodes[1..]) |*node| {
            const load = node.getLoadFactor();
            if (load < min_load) {
                min_load = load;
                best_node = node;
            }
        }

        return best_node;
    }

    pub fn getNodeForCore(self: *Self, core_id: u32) ?*NumaNode {
        for (self.nodes) |*node| {
            for (node.cpu_cores) |core| {
                if (core == core_id) {
                    return node;
                }
            }
        }
        return null;
    }

    const NodeStats = struct { id: u32, actors: u32, load: f32 };

    pub fn getStats(self: *const Self, allocator: Allocator) !struct {
        total_nodes: usize,
        total_cores: u32,
        nodes: []NodeStats,
    } {
        const node_stats = try allocator.alloc(NodeStats, self.nodes.len);

        for (self.nodes, 0..) |*node, i| {
            node_stats[i] = .{
                .id = node.id,
                .actors = node.actor_count.load(.acquire),
                .load = node.getLoadFactor(),
            };
        }

        return .{
            .total_nodes = self.nodes.len,
            .total_cores = self.total_cores,
            .nodes = node_stats,
        };
    }

    pub fn freeStats(allocator: Allocator, stats: anytype) void {
        allocator.free(stats.nodes);
    }
};

/// CPU亲和性管理器
pub const AffinityManager = struct {
    const Self = @This();

    topology: *NumaTopology,

    pub fn init(topology: *NumaTopology) Self {
        return Self{
            .topology = topology,
        };
    }

    /// 绑定线程到特定CPU核心
    pub fn bindToCore(self: *Self, thread_id: std.Thread.Id, core_id: u32) !void {
        _ = self;
        _ = thread_id;

        // 在Windows上的实现
        if (std.builtin.os.tag == .windows) {
            // 使用Windows API设置线程亲和性
            // 这里需要调用SetThreadAffinityMask
            // 由于Zig标准库限制，这里只是占位符
            std.log.info("Setting thread affinity to core {} (Windows)", .{core_id});
        } else {
            // 在Linux上的实现
            // 使用pthread_setaffinity_np或sched_setaffinity
            std.log.info("Setting thread affinity to core {} (Linux)", .{core_id});
        }
    }

    /// 绑定线程到NUMA节点
    pub fn bindToNode(self: *Self, thread_id: std.Thread.Id, node: *NumaNode) !void {
        if (node.cpu_cores.len > 0) {
            // 选择节点中负载最低的核心
            const core_id = node.cpu_cores[0]; // 简化实现
            try self.bindToCore(thread_id, core_id);
        }
    }

    /// 获取当前线程的CPU核心
    pub fn getCurrentCore(self: *Self) u32 {
        _ = self;
        // 简化实现 - 实际应该使用系统API获取
        return 0;
    }
};

/// NUMA感知调度器
pub const NumaScheduler = struct {
    const Self = @This();

    topology: *NumaTopology,
    affinity_manager: AffinityManager,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        const topology = try NumaTopology.detect(allocator);

        self.* = Self{
            .topology = topology,
            .affinity_manager = AffinityManager.init(topology),
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.topology.deinit();
        self.allocator.destroy(self);
    }

    /// 为Actor选择最优的NUMA节点
    pub fn scheduleActor(self: *Self, actor: *Actor) *NumaNode {
        _ = actor; // 在实际实现中可以根据Actor的数据局部性选择节点

        const best_node = self.topology.getBestNode();
        best_node.addActor();
        return best_node;
    }

    /// 移除Actor调度
    pub fn unscheduleActor(self: *Self, actor: *Actor, node: *NumaNode) void {
        _ = self;
        _ = actor;
        node.removeActor();
    }

    /// 绑定工作线程到最优核心
    pub fn bindWorkerThread(self: *Self, thread_id: std.Thread.Id, preferred_node_id: ?u32) !void {
        const node = if (preferred_node_id) |id|
            if (id < self.topology.nodes.len) &self.topology.nodes[id] else self.topology.getBestNode()
        else
            self.topology.getBestNode();

        try self.affinity_manager.bindToNode(thread_id, node);
    }

    /// 获取调度统计信息
    pub fn getStats(self: *const Self, allocator: Allocator) !struct {
        topology: struct {
            total_nodes: usize,
            total_cores: u32,
            nodes: []NumaTopology.NodeStats,
        },
    } {
        const topo_stats = try self.topology.getStats(allocator);
        return .{
            .topology = .{
                .total_nodes = topo_stats.total_nodes,
                .total_cores = topo_stats.total_cores,
                .nodes = topo_stats.nodes,
            },
        };
    }

    pub fn freeStats(self: *const Self, allocator: Allocator, stats: anytype) void {
        NumaTopology.freeStats(allocator, stats.topology);
        _ = self;
    }

    /// 更新节点负载信息
    pub fn updateNodeLoad(self: *Self, node_id: u32, load: u32) void {
        if (node_id < self.topology.nodes.len) {
            self.topology.nodes[node_id].updateLoad(load);
        }
    }
};

// 测试
test "NumaTopology detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const topology = try NumaTopology.detect(allocator);
    defer topology.deinit();

    try testing.expect(topology.nodes.len > 0);
    try testing.expect(topology.total_cores > 0);

    const stats = topology.getStats();
    try testing.expect(stats.total_nodes == topology.nodes.len);
    try testing.expect(stats.total_cores == topology.total_cores);
}

test "NumaScheduler basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const scheduler = try NumaScheduler.init(allocator);
    defer scheduler.deinit();

    // 测试获取统计信息
    const stats = scheduler.getStats();
    try testing.expect(stats.topology.total_nodes > 0);
}
