const std = @import("std");

/// A single trace event packed into 32 bytes for cache-line-friendly ring buffer storage.
pub const TraceEntry = extern struct {
    /// 0=call, 1=return_to, 2=out, 3=in
    event_type: u8,
    /// Function arity (0-255)
    arity: u8,
    /// Alignment padding
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// Raw ERL_NIF_TERM value for module atom
    module: u64,
    /// Raw ERL_NIF_TERM value for function atom
    function: u64,
    /// Microsecond timestamp
    timestamp_us: u64,
};

comptime {
    if (@sizeOf(TraceEntry) != 32) {
        @compileError("TraceEntry must be exactly 32 bytes");
    }
}

pub const Stats = struct {
    write_pos: u64,
    read_pos: u64,
    capacity: u64,
    overflow_count: u64,
};

/// SPSC (single-producer, single-consumer) lock-free ring buffer for trace events.
///
/// The producer (BEAM scheduler thread calling trace/5) writes entries and advances
/// write_pos atomically. The consumer (TraceSession GenServer calling drain_buffer)
/// reads entries and advances read_pos atomically. No locks are needed because there
/// is exactly one producer and one consumer.
///
/// Overflow policy: when the buffer is full (write_pos - read_pos >= capacity),
/// write() returns false to drop the event. The enabled/3 callback checks fill_level
/// and returns :discard before this point to apply backpressure proactively.
pub const RingBuffer = struct {
    entries: [*]TraceEntry,
    capacity: u64,
    write_pos: std.atomic.Value(u64),
    read_pos: std.atomic.Value(u64),
    overflow_count: std.atomic.Value(u64),
    active: std.atomic.Value(u8),

    /// Allocate a ring buffer with the given capacity (number of entries).
    /// Uses std.heap.page_allocator for large, page-aligned allocations.
    pub fn create(capacity: usize) ?*RingBuffer {
        const allocator = std.heap.page_allocator;

        const buf = allocator.create(RingBuffer) catch return null;
        const entries = allocator.alloc(TraceEntry, capacity) catch {
            allocator.destroy(buf);
            return null;
        };

        buf.* = .{
            .entries = entries.ptr,
            .capacity = @intCast(capacity),
            .write_pos = std.atomic.Value(u64).init(0),
            .read_pos = std.atomic.Value(u64).init(0),
            .overflow_count = std.atomic.Value(u64).init(0),
            .active = std.atomic.Value(u8).init(1),
        };

        return buf;
    }

    /// Free the ring buffer and its backing storage.
    pub fn destroy(self: *RingBuffer) void {
        const allocator = std.heap.page_allocator;
        const entries_slice = self.entries[0..@intCast(self.capacity)];
        allocator.free(entries_slice);
        allocator.destroy(self);
    }

    /// Write a single entry to the ring buffer.
    /// Returns false if the buffer is full (backpressure / overflow).
    /// This is the producer-side function, called from trace/5.
    pub fn write(self: *RingBuffer, entry: TraceEntry) bool {
        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.monotonic);

        // Buffer full — drop the event
        if (wp - rp >= self.capacity) {
            _ = self.overflow_count.fetchAdd(1, .monotonic);
            return false;
        }

        const index: usize = @intCast(wp % self.capacity);
        self.entries[index] = entry;

        // Release store ensures the entry data is visible before the consumer
        // sees the updated write_pos.
        self.write_pos.store(wp + 1, .release);
        return true;
    }

    /// Read up to out.len entries from the ring buffer.
    /// Returns the number of entries actually read. Advances the read pointer.
    /// This is the consumer-side function, called from drain_buffer.
    pub fn read_batch(self: *RingBuffer, out: []TraceEntry) usize {
        const rp = self.read_pos.load(.monotonic);
        // Acquire load ensures we see the entry data written by the producer
        // before the write_pos update.
        const wp = self.write_pos.load(.acquire);

        const available: u64 = wp - rp;
        const to_read: usize = @intCast(@min(available, @as(u64, @intCast(out.len))));

        for (0..to_read) |i| {
            const index: usize = @intCast((rp + @as(u64, @intCast(i))) % self.capacity);
            out[i] = self.entries[index];
        }

        // Monotonic store is sufficient — only one consumer.
        self.read_pos.store(rp + @as(u64, @intCast(to_read)), .monotonic);
        return to_read;
    }

    /// Return buffer statistics for monitoring.
    pub fn stats(self: *RingBuffer) Stats {
        return .{
            .write_pos = self.write_pos.load(.monotonic),
            .read_pos = self.read_pos.load(.monotonic),
            .capacity = self.capacity,
            .overflow_count = self.overflow_count.load(.monotonic),
        };
    }

    /// Set the active flag. When false, enabled/3 returns :remove.
    pub fn set_active(self: *RingBuffer, active: bool) void {
        self.active.store(@intFromBool(active), .monotonic);
    }

    /// Check whether the buffer is active.
    pub fn is_active(self: *RingBuffer) bool {
        return self.active.load(.monotonic) != 0;
    }

    /// Return the fill ratio as a float between 0.0 and 1.0.
    pub fn fill_level(self: *RingBuffer) f32 {
        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.monotonic);
        const used = wp - rp;
        return @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(self.capacity));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TraceEntry is 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(TraceEntry));
}

test "create and destroy" {
    const buf = RingBuffer.create(64) orelse return error.SkipZigTest;
    defer buf.destroy();

    const s = buf.stats();
    try std.testing.expectEqual(@as(u64, 0), s.write_pos);
    try std.testing.expectEqual(@as(u64, 0), s.read_pos);
    try std.testing.expectEqual(@as(u64, 64), s.capacity);
    try std.testing.expectEqual(@as(u64, 0), s.overflow_count);
}

test "write one entry and read it back" {
    const buf = RingBuffer.create(64) orelse return error.SkipZigTest;
    defer buf.destroy();

    const entry = TraceEntry{
        .event_type = 0, // call
        .arity = 3,
        .module = 42,
        .function = 99,
        .timestamp_us = 1000000,
    };

    try std.testing.expect(buf.write(entry));

    var out: [1]TraceEntry = undefined;
    const count = buf.read_batch(&out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u8, 0), out[0].event_type);
    try std.testing.expectEqual(@as(u8, 3), out[0].arity);
    try std.testing.expectEqual(@as(u64, 42), out[0].module);
    try std.testing.expectEqual(@as(u64, 99), out[0].function);
    try std.testing.expectEqual(@as(u64, 1000000), out[0].timestamp_us);
}

test "fill buffer to capacity and verify full" {
    const cap: usize = 16;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Fill to capacity
    for (0..cap) |i| {
        const entry = TraceEntry{
            .event_type = 0,
            .arity = @intCast(i),
            .module = @intCast(i),
            .function = @intCast(i),
            .timestamp_us = @intCast(i * 1000),
        };
        try std.testing.expect(buf.write(entry));
    }

    // Buffer should be full
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), buf.fill_level(), 0.001);
}

test "write when full returns false" {
    const cap: usize = 8;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Fill buffer
    for (0..cap) |i| {
        const entry = TraceEntry{
            .event_type = 0,
            .arity = 0,
            .module = @intCast(i),
            .function = 0,
            .timestamp_us = 0,
        };
        try std.testing.expect(buf.write(entry));
    }

    // Should fail — buffer full
    const overflow_entry = TraceEntry{
        .event_type = 0,
        .arity = 0,
        .module = 999,
        .function = 0,
        .timestamp_us = 0,
    };
    try std.testing.expect(!buf.write(overflow_entry));

    // Overflow count should be 1
    const s = buf.stats();
    try std.testing.expectEqual(@as(u64, 1), s.overflow_count);
}

test "read batch reads correct count" {
    const cap: usize = 32;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Write 10 entries
    for (0..10) |i| {
        const entry = TraceEntry{
            .event_type = 0,
            .arity = @intCast(i),
            .module = @intCast(i),
            .function = @intCast(i),
            .timestamp_us = @intCast(i * 100),
        };
        try std.testing.expect(buf.write(entry));
    }

    // Read with a large output buffer — should get exactly 10
    var out: [32]TraceEntry = undefined;
    const count = buf.read_batch(&out);
    try std.testing.expectEqual(@as(usize, 10), count);

    // Verify ordering
    for (0..10) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), out[i].arity);
        try std.testing.expectEqual(@as(u64, @intCast(i * 100)), out[i].timestamp_us);
    }

    // Read again — should get 0 (all consumed)
    const count2 = buf.read_batch(&out);
    try std.testing.expectEqual(@as(usize, 0), count2);
}

test "read batch with smaller output buffer" {
    const cap: usize = 32;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Write 20 entries
    for (0..20) |i| {
        const entry = TraceEntry{
            .event_type = 0,
            .arity = @intCast(i),
            .module = 0,
            .function = 0,
            .timestamp_us = @intCast(i),
        };
        try std.testing.expect(buf.write(entry));
    }

    // Read with small buffer — should get exactly 5
    var out: [5]TraceEntry = undefined;
    const count = buf.read_batch(&out);
    try std.testing.expectEqual(@as(usize, 5), count);

    // Verify we got the first 5
    for (0..5) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), out[i].arity);
    }

    // Read remaining — should get 15
    var out2: [32]TraceEntry = undefined;
    const count2 = buf.read_batch(&out2);
    try std.testing.expectEqual(@as(usize, 15), count2);

    // First entry should be arity=5 (continuing from where we left off)
    try std.testing.expectEqual(@as(u8, 5), out2[0].arity);
}

test "SPSC interleaved writes and reads" {
    const cap: usize = 8;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    var out: [4]TraceEntry = undefined;

    // Write 4, read 4, write 4 more, read 4 — tests wrap-around
    for (0..4) |i| {
        const entry = TraceEntry{
            .event_type = 0,
            .arity = @intCast(i),
            .module = 0,
            .function = 0,
            .timestamp_us = @intCast(i),
        };
        try std.testing.expect(buf.write(entry));
    }

    var count = buf.read_batch(&out);
    try std.testing.expectEqual(@as(usize, 4), count);
    for (0..4) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), out[i].arity);
    }

    // Write 4 more (these will wrap around in the buffer)
    for (4..8) |i| {
        const entry = TraceEntry{
            .event_type = 1,
            .arity = @intCast(i),
            .module = 0,
            .function = 0,
            .timestamp_us = @intCast(i),
        };
        try std.testing.expect(buf.write(entry));
    }

    count = buf.read_batch(&out);
    try std.testing.expectEqual(@as(usize, 4), count);
    for (0..4) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 4)), out[i].arity);
        try std.testing.expectEqual(@as(u8, 1), out[i].event_type);
    }
}

test "stats report correct values" {
    const cap: usize = 16;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Initially empty
    var s = buf.stats();
    try std.testing.expectEqual(@as(u64, 0), s.write_pos);
    try std.testing.expectEqual(@as(u64, 0), s.read_pos);
    try std.testing.expectEqual(@as(u64, 16), s.capacity);
    try std.testing.expectEqual(@as(u64, 0), s.overflow_count);

    // Write 5
    for (0..5) |_| {
        _ = buf.write(TraceEntry{
            .event_type = 0,
            .arity = 0,
            .module = 0,
            .function = 0,
            .timestamp_us = 0,
        });
    }

    s = buf.stats();
    try std.testing.expectEqual(@as(u64, 5), s.write_pos);
    try std.testing.expectEqual(@as(u64, 0), s.read_pos);

    // Read 3
    var out: [3]TraceEntry = undefined;
    _ = buf.read_batch(&out);

    s = buf.stats();
    try std.testing.expectEqual(@as(u64, 5), s.write_pos);
    try std.testing.expectEqual(@as(u64, 3), s.read_pos);
}

test "active flag works" {
    const buf = RingBuffer.create(8) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Default: active
    try std.testing.expect(buf.is_active());

    // Deactivate
    buf.set_active(false);
    try std.testing.expect(!buf.is_active());

    // Re-activate
    buf.set_active(true);
    try std.testing.expect(buf.is_active());
}

test "fill_level reports correct ratio" {
    const cap: usize = 100;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Empty
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf.fill_level(), 0.001);

    // Write 50 entries → 50%
    for (0..50) |_| {
        _ = buf.write(TraceEntry{
            .event_type = 0,
            .arity = 0,
            .module = 0,
            .function = 0,
            .timestamp_us = 0,
        });
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buf.fill_level(), 0.01);

    // Read 25 → 25%
    var out: [25]TraceEntry = undefined;
    _ = buf.read_batch(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), buf.fill_level(), 0.01);
}

test "multiple overflow increments" {
    const cap: usize = 4;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Fill buffer
    for (0..4) |_| {
        _ = buf.write(TraceEntry{
            .event_type = 0,
            .arity = 0,
            .module = 0,
            .function = 0,
            .timestamp_us = 0,
        });
    }

    // Try 3 more writes — all should fail
    for (0..3) |_| {
        try std.testing.expect(!buf.write(TraceEntry{
            .event_type = 0,
            .arity = 0,
            .module = 0,
            .function = 0,
            .timestamp_us = 0,
        }));
    }

    try std.testing.expectEqual(@as(u64, 3), buf.stats().overflow_count);
}

test "wrap-around preserves data integrity" {
    const cap: usize = 4;
    const buf = RingBuffer.create(cap) orelse return error.SkipZigTest;
    defer buf.destroy();

    // Do multiple rounds of fill-and-drain to exercise wrap-around
    for (0..5) |round| {
        for (0..cap) |i| {
            const entry = TraceEntry{
                .event_type = @intCast(round % 4),
                .arity = @intCast(i),
                .module = @intCast(round * 100 + i),
                .function = @intCast(round * 1000 + i),
                .timestamp_us = @intCast(round * 10000 + i),
            };
            try std.testing.expect(buf.write(entry));
        }

        var out: [4]TraceEntry = undefined;
        const count = buf.read_batch(&out);
        try std.testing.expectEqual(cap, count);

        for (0..cap) |i| {
            try std.testing.expectEqual(@as(u8, @intCast(i)), out[i].arity);
            try std.testing.expectEqual(@as(u64, @intCast(round * 100 + i)), out[i].module);
        }
    }
}
