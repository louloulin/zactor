const std = @import("std");

var semaphore = std.Thread.Semaphore{};
var worker_done = false;

fn worker() void {
    std.log.info("Worker: Starting, waiting on semaphore", .{});
    semaphore.wait();
    std.log.info("Worker: Got semaphore signal, proceeding", .{});
    worker_done = true;
}

pub fn main() !void {
    std.log.info("Main: Starting semaphore test", .{});
    
    const thread = try std.Thread.spawn(.{}, worker, .{});
    
    std.log.info("Main: Sleeping for 2 seconds", .{});
    std.time.sleep(2 * std.time.ns_per_s);
    
    std.log.info("Main: Posting to semaphore", .{});
    semaphore.post();
    
    std.log.info("Main: Waiting for worker thread to join", .{});
    thread.join();
    
    if (worker_done) {
        std.log.info("Main: Test completed successfully", .{});
    } else {
        std.log.err("Main: Test failed - worker did not complete", .{});
    }
}
