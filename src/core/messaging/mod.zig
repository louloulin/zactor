//! 高性能消息传递模块
//! 包含Ring Buffer、批处理器等高性能消息传递组件

pub const RingBuffer = @import("ring_buffer.zig").RingBuffer;
pub const RingBufferConfig = @import("ring_buffer.zig").RingBufferConfig;
pub const RingBufferFactory = @import("ring_buffer.zig").RingBufferFactory;

pub const BatchProcessor = @import("batch_processor.zig").BatchProcessor;
pub const BatchConfig = @import("batch_processor.zig").BatchConfig;
pub const BatchStats = @import("batch_processor.zig").BatchStats;
pub const AdaptiveBatcher = @import("batch_processor.zig").AdaptiveBatcher;
pub const MessageProcessingLoop = @import("batch_processor.zig").MessageProcessingLoop;

// 零拷贝消息传递
pub const ZeroCopyMessage = @import("zero_copy.zig").ZeroCopyMessage;
pub const ZeroCopyMessageHeader = @import("zero_copy.zig").ZeroCopyMessageHeader;
pub const ZeroCopyMemoryPool = @import("zero_copy.zig").ZeroCopyMemoryPool;
pub const ZeroCopyMessenger = @import("zero_copy.zig").ZeroCopyMessenger;

// 超高性能消息传递核心
pub const UltraFastMessageCore = @import("ultra_fast_core.zig").UltraFastMessageCore;
pub const LockFreeRingBuffer = @import("ultra_fast_core.zig").LockFreeRingBuffer;
pub const PreAllocatedArena = @import("ultra_fast_core.zig").PreAllocatedArena;
