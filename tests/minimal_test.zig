const std = @import("std");

// Test the mailbox directly
const Message = @import("src/message.zig").Message;
const Mailbox = @import("src/mailbox.zig").Mailbox;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== Minimal Mailbox Test ===", .{});
    
    // Test mailbox directly
    var mailbox = try Mailbox.init(allocator);
    defer mailbox.deinit();
    
    std.log.info("Mailbox created, isEmpty: {}", .{mailbox.isEmpty()});
    
    // Create and send a message
    const msg = Message.createSystem(.ping, 123);
    try mailbox.send(msg);
    
    std.log.info("Message sent, isEmpty: {}, size: {}", .{ mailbox.isEmpty(), mailbox.size() });
    
    // Receive the message
    if (mailbox.receive()) |received_msg| {
        std.log.info("Message received: type={}, system={}", .{ received_msg.message_type, received_msg.data.system });
    } else {
        std.log.info("No message received", .{});
    }
    
    std.log.info("After receive, isEmpty: {}, size: {}", .{ mailbox.isEmpty(), mailbox.size() });
    
    std.log.info("=== Mailbox Test Complete ===", .{});
}
