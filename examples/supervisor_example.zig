const std = @import("std");
const zactor = @import("zactor");

// A worker actor that can fail randomly
const WorkerActor = struct {
    const Self = @This();

    id: u32,
    work_count: u32,
    failure_rate: f32, // 0.0 to 1.0

    pub fn init(id: u32, failure_rate: f32) Self {
        return Self{
            .id = id,
            .work_count = 0,
            .failure_rate = failure_rate,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.data) {
            .user => |user_msg| {
                const parsed = try user_msg.get([]const u8, context.allocator);
                defer parsed.deinit();
                const data = parsed.value;

                if (std.mem.eql(u8, data, "work")) {
                    try self.doWork();
                } else if (std.mem.eql(u8, data, "status")) {
                    std.log.info("Worker {}: Completed {} tasks", .{ self.id, self.work_count });
                }
            },
            .system => |sys_msg| {
                switch (sys_msg) {
                    .start => std.log.info("Worker {} started", .{self.id}),
                    .stop => std.log.info("Worker {} stopped", .{self.id}),
                    .restart => {
                        std.log.info("Worker {} restarted, resetting work count", .{self.id});
                        self.work_count = 0;
                    },
                    else => {},
                }
            },
            .control => {},
        }
    }

    fn doWork(self: *Self) !void {
        // Simulate work
        std.time.sleep(10 * std.time.ns_per_ms);

        // Random failure simulation
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = prng.random();

        if (random.float(f32) < self.failure_rate) {
            std.log.err("Worker {} failed during work!", .{self.id});
            return error.WorkerFailed;
        }

        self.work_count += 1;
        std.log.info("Worker {} completed task #{}", .{ self.id, self.work_count });
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Worker {} starting", .{self.id});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Worker {} stopped", .{self.id});
    }

    pub fn preStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Worker {} stopping, completed {} tasks", .{ self.id, self.work_count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.warn("Worker {} restarting due to: {}", .{ self.id, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Worker {} restarted successfully", .{self.id});
    }
};

// A supervisor actor that manages workers
const SupervisorActor = struct {
    const Self = @This();

    name: []const u8,
    worker_count: u32,
    workers: std.ArrayList(zactor.ActorRef),
    allocator: std.mem.Allocator,

    pub fn init(name: []const u8, worker_count: u32, allocator: std.mem.Allocator) Self {
        return Self{
            .name = name,
            .worker_count = worker_count,
            .workers = std.ArrayList(zactor.ActorRef).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.workers.deinit();
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.data) {
            .user => |user_msg| {
                const parsed = try user_msg.get([]const u8, context.allocator);
                defer parsed.deinit();
                const data = parsed.value;

                if (std.mem.eql(u8, data, "start_workers")) {
                    try self.startWorkers(context);
                } else if (std.mem.eql(u8, data, "distribute_work")) {
                    try self.distributeWork();
                } else if (std.mem.eql(u8, data, "status")) {
                    try self.reportStatus();
                }
            },
            .system => |sys_msg| {
                switch (sys_msg) {
                    .start => std.log.info("Supervisor '{s}' started", .{self.name}),
                    .stop => {
                        std.log.info("Supervisor '{s}' stopping", .{self.name});
                        try self.stopAllWorkers();
                    },
                    else => {},
                }
            },
            .control => {},
        }
    }

    fn startWorkers(self: *Self, context: *zactor.ActorContext) !void {
        std.log.info("Supervisor '{s}': Starting {} workers", .{ self.name, self.worker_count });

        for (0..self.worker_count) |i| {
            const worker_id = @as(u32, @intCast(i + 1));
            const failure_rate: f32 = if (i % 3 == 0) 0.2 else 0.05; // Some workers more prone to failure

            const worker = WorkerActor.init(worker_id, failure_rate);
            const worker_ref = try context.system.spawn(WorkerActor, worker);

            try self.workers.append(worker_ref);
            std.log.info("Supervisor '{s}': Started worker {}", .{ self.name, worker_id });
        }
    }

    fn distributeWork(self: *Self) !void {
        std.log.info("Supervisor '{s}': Distributing work to {} workers", .{ self.name, self.workers.items.len });

        for (self.workers.items) |worker_ref| {
            try worker_ref.send([]const u8, "work", self.allocator);
        }
    }

    fn reportStatus(self: *Self) !void {
        std.log.info("Supervisor '{s}': Requesting status from {} workers", .{ self.name, self.workers.items.len });

        for (self.workers.items) |worker_ref| {
            try worker_ref.send([]const u8, "status", self.allocator);
        }
    }

    fn stopAllWorkers(self: *Self) !void {
        std.log.info("Supervisor '{s}': Stopping all workers", .{self.name});

        for (self.workers.items) |worker_ref| {
            try worker_ref.sendSystem(.stop);
        }

        self.workers.clearAndFree();
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Supervisor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Supervisor '{s}' stopped", .{self.name});
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.warn("Supervisor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Supervisor '{s}' restarted", .{self.name});
    }

    pub fn preStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("Supervisor '{s}' stopping", .{self.name});
        try self.stopAllWorkers();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZActor Supervisor Tree Example ===", .{});

    // Initialize ZActor with supervision-friendly configuration
    zactor.init(.{
        .max_actors = 50,
        .scheduler_threads = 2,
        .enable_work_stealing = true,
    });

    // Create actor system with custom supervisor configuration
    var system = try zactor.ActorSystem.init("supervisor-example", allocator);
    defer system.deinit();

    // Configure supervision strategy
    system.setSupervisorConfig(.{
        .strategy = .restart,
        .max_restarts = 5,
        .restart_window_seconds = 30,
        .backoff_initial_ms = 200,
        .backoff_max_ms = 2000,
        .backoff_multiplier = 1.5,
    });

    try system.start();

    // Create supervisor actor
    const supervisor_actor = SupervisorActor.init("WorkerSupervisor", 5, allocator);
    const supervisor_ref = try system.spawn(SupervisorActor, supervisor_actor);

    // Start the workers
    try supervisor_ref.send([]const u8, "start_workers", allocator);
    std.time.sleep(100 * std.time.ns_per_ms); // Let workers start

    // Simulate work cycles with potential failures
    for (0..10) |cycle| {
        std.log.info("\n--- Work Cycle {} ---", .{cycle + 1});

        // Distribute work
        try supervisor_ref.send([]const u8, "distribute_work", allocator);

        // Wait for work to complete (and potential failures)
        std.time.sleep(500 * std.time.ns_per_ms);

        // Get status
        try supervisor_ref.send([]const u8, "status", allocator);
        std.time.sleep(100 * std.time.ns_per_ms);

        // Print system metrics
        std.log.info("\n--- System Metrics ---", .{});
        zactor.metrics.print();

        // Print supervisor stats
        const supervisor_stats = system.getSupervisorStats();
        supervisor_stats.print();

        std.time.sleep(200 * std.time.ns_per_ms);
    }

    std.log.info("\n=== Shutting Down ===", .{});

    // Graceful shutdown
    try supervisor_ref.sendSystem(.stop);
    std.time.sleep(200 * std.time.ns_per_ms);

    // Final metrics
    std.log.info("\n--- Final Metrics ---", .{});
    zactor.metrics.print();

    const final_supervisor_stats = system.getSupervisorStats();
    final_supervisor_stats.print();

    system.shutdown();

    std.log.info("=== Example Complete ===", .{});
}
