const std = @import("std");

var mutex = std.Thread.Mutex{};
var cond = std.Thread.Condition{};
var ready = false;

fn worker() void {
    std.log.info("Worker: Starting, acquiring lock", .{});
    mutex.lock();
    defer mutex.unlock();

    std.log.info("Worker: Lock acquired, checking ready status", .{});
    while (!ready) {
        std.log.info("Worker: Ready is false, waiting on condition", .{});
        cond.wait(&mutex);
        std.log.info("Worker: Woke up from condition wait", .{});
    }

    std.log.info("Worker: Ready is true, proceeding", .{});
}

pub fn main() !void {
    std.log.info("Main: Starting condition variable test", .{});

    const thread = try std.Thread.spawn(.{}, worker, .{});

    std.log.info("Main: Sleeping for 2 seconds", .{});
    std.time.sleep(2 * std.time.ns_per_s);

    {
        std.log.info("Main: Acquiring lock to set ready", .{});
        mutex.lock();
        defer mutex.unlock();

        std.log.info("Main: Setting ready to true", .{});
        ready = true;

        std.log.info("Main: Signaling condition", .{});
        cond.signal();
    }

    std.log.info("Main: Waiting for worker thread to join", .{});
    thread.join();

    std.log.info("Main: Test completed successfully", .{});
}
