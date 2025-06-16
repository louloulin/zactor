const std = @import("std");
const zactor = @import("src/zactor.zig");
const Mailbox = @import("src/mailbox.zig").Mailbox;
const Message = @import("src/message.zig").Message;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🧪 === Mailbox Test ===", .{});

    // Test basic mailbox functionality
    var mailbox = try Mailbox.init(allocator);
    defer mailbox.deinit();

    std.log.info("Initial mailbox empty: {}", .{mailbox.isEmpty()});
    std.log.info("Initial mailbox size: {}", .{mailbox.size()});

    // Send some messages
    const num_messages = 10;
    for (0..num_messages) |i| {
        const msg = Message.createSystem(.ping, @intCast(i));
        mailbox.send(msg) catch |err| {
            std.log.err("Failed to send message {}: {}", .{ i, err });
            break;
        };
        std.log.info("Sent message {}, mailbox size: {}", .{ i, mailbox.size() });
    }

    std.log.info("After sending {} messages:", .{num_messages});
    std.log.info("Mailbox empty: {}", .{mailbox.isEmpty()});
    std.log.info("Mailbox size: {}", .{mailbox.size()});

    // Receive all messages
    var received_count: u32 = 0;
    while (mailbox.receive()) |msg| {
        std.log.info("Received message {}: type={}, system={}", .{ received_count, msg.message_type, msg.data.system });
        received_count += 1;
        msg.deinit(allocator);
    }

    std.log.info("Received {} messages", .{received_count});
    std.log.info("Final mailbox empty: {}", .{mailbox.isEmpty()});
    std.log.info("Final mailbox size: {}", .{mailbox.size()});

    std.log.info("✅ === Mailbox Test Complete ===", .{});
}
