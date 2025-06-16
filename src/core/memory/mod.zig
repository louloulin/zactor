//! 内存管理模块
//! 提供高性能的内存分配和管理功能

// Actor专用高性能内存分配器
pub const ActorMemoryAllocator = @import("actor_allocator.zig").ActorMemoryAllocator;
pub const ThreadLocalPool = @import("actor_allocator.zig").ThreadLocalPool;
pub const SizeClassPool = @import("actor_allocator.zig").SizeClassPool;
