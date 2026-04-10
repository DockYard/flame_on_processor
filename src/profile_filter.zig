const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Sample = struct {
    path: []const u8,
    duration_us: u64,
};

pub const FilterResult = struct {
    paths: [][]const u8,
    durations: []u64,

    pub fn deinit(self: FilterResult, allocator: Allocator) void {
        allocator.free(self.paths);
        allocator.free(self.durations);
    }
};

pub const FilterError = error{
    MismatchedLengths,
    OutOfMemory,
};

const min_threshold: f64 = 0.005;

/// Filter profile samples by removing functions whose inclusive time is below
/// the given threshold fraction of total time. Small top-level blocks are
/// consolidated into placeholder entries.
///
/// The caller owns the returned slices and must free them with the same allocator.
/// The returned paths are slices into the original input strings (no copies).
pub fn filter(
    allocator: Allocator,
    paths: []const []const u8,
    durations: []const u64,
    function_length_threshold: f64,
) FilterError!FilterResult {
    if (paths.len != durations.len) {
        return FilterError.MismatchedLengths;
    }

    if (paths.len == 0) {
        const empty_paths = try allocator.alloc([]const u8, 0);
        const empty_durations = try allocator.alloc(u64, 0);
        return FilterResult{
            .paths = empty_paths,
            .durations = empty_durations,
        };
    }

    // 1. Compute total time
    var total_time: u64 = 0;
    for (durations) |d| {
        total_time += d;
    }

    // 2. Compute threshold
    const effective_threshold = @max(function_length_threshold, min_threshold);
    const threshold_us: u64 = @intFromFloat(@as(f64, @floatFromInt(total_time)) * effective_threshold);

    // 3. Build inclusive_times using a HashMap
    //    For each sample path, find all ";" positions and accumulate durations
    //    for each prefix (sub-path).
    var inclusive_times = std.StringHashMap(u64).init(allocator);
    defer inclusive_times.deinit();

    for (paths, durations) |path, duration| {
        // Accumulate for the full path
        const full_entry = try inclusive_times.getOrPut(path);
        if (full_entry.found_existing) {
            full_entry.value_ptr.* += duration;
        } else {
            full_entry.value_ptr.* = duration;
        }

        // Accumulate for each prefix (up to each ";")
        var pos: usize = 0;
        while (pos < path.len) {
            if (std.mem.indexOfScalarPos(u8, path, pos, ';')) |semi_pos| {
                const prefix = path[0..semi_pos];
                const prefix_entry = try inclusive_times.getOrPut(prefix);
                if (prefix_entry.found_existing) {
                    prefix_entry.value_ptr.* += duration;
                } else {
                    prefix_entry.value_ptr.* = duration;
                }
                pos = semi_pos + 1;
            } else {
                break;
            }
        }
    }

    // 4. Identify small blocks (inclusive time < threshold)
    var small_blocks = std.StringHashMap(void).init(allocator);
    defer small_blocks.deinit();

    var it = inclusive_times.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* < threshold_us) {
            try small_blocks.put(entry.key_ptr.*, {});
        }
    }

    // 5. Filter samples: keep those that don't have a small ancestor
    var result_paths: std.ArrayList([]const u8) = .empty;
    defer result_paths.deinit(allocator);
    var result_durations: std.ArrayList(u64) = .empty;
    defer result_durations.deinit(allocator);

    for (paths, durations) |path, duration| {
        if (!hasSmallAncestor(path, &small_blocks)) {
            try result_paths.append(allocator, path);
            try result_durations.append(allocator, duration);
        }
    }

    // 6. Consolidate: add entries for top-level small blocks
    //    A top-level small block is one where no proper prefix of it is also small.
    var top_level_small = std.StringHashMap(u64).init(allocator);
    defer top_level_small.deinit();

    var small_it = small_blocks.iterator();
    while (small_it.next()) |entry| {
        const block = entry.key_ptr.*;
        if (!hasSmallAncestor(block, &small_blocks)) {
            // This is a top-level small block; get its inclusive time
            if (inclusive_times.get(block)) |time| {
                const tls_entry = try top_level_small.getOrPut(block);
                if (tls_entry.found_existing) {
                    tls_entry.value_ptr.* += time;
                } else {
                    tls_entry.value_ptr.* = time;
                }
            }
        }
    }

    var tls_it = top_level_small.iterator();
    while (tls_it.next()) |entry| {
        try result_paths.append(allocator, entry.key_ptr.*);
        try result_durations.append(allocator, entry.value_ptr.*);
    }

    return FilterResult{
        .paths = try result_paths.toOwnedSlice(allocator),
        .durations = try result_durations.toOwnedSlice(allocator),
    };
}

/// Check whether a path has a proper prefix (ancestor) that is in the small_blocks set.
fn hasSmallAncestor(path: []const u8, small_blocks: *const std.StringHashMap(void)) bool {
    var pos: usize = 0;
    while (pos < path.len) {
        if (std.mem.indexOfScalarPos(u8, path, pos, ';')) |semi_pos| {
            const prefix = path[0..semi_pos];
            if (small_blocks.contains(prefix)) {
                return true;
            }
            pos = semi_pos + 1;
        } else {
            break;
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "empty input returns empty output" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{};
    const durations = &[_]u64{};
    const result = try filter(allocator, paths, durations, 0.01);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.paths.len);
    try std.testing.expectEqual(@as(usize, 0), result.durations.len);
}

test "single sample passes through" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{"main"};
    const durations = &[_]u64{1000};
    const result = try filter(allocator, paths, durations, 0.01);
    defer result.deinit(allocator);

    // Single sample with 100% of time should pass through
    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("main", result.paths[0]);
    try std.testing.expectEqual(@as(u64, 1000), result.durations[0]);
}

test "filter preserves large functions" {
    const allocator = std.testing.allocator;
    // All samples have significant time, none should be filtered
    const paths = &[_][]const u8{
        "main;compute",
        "main;render",
    };
    const durations = &[_]u64{ 5000, 5000 };
    const result = try filter(allocator, paths, durations, 0.01);
    defer result.deinit(allocator);

    // Both should pass through since they're 50% each
    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
}

test "filter removes small functions under small root" {
    const allocator = std.testing.allocator;
    // "tiny_root" is a top-level function with very little time.
    // Its children should be filtered and consolidated.
    const paths = &[_][]const u8{
        "main;compute",
        "tiny_root;child_a",
        "tiny_root;child_b",
    };
    const durations = &[_]u64{ 10000, 3, 2 };
    const result = try filter(allocator, paths, durations, 0.01);
    defer result.deinit(allocator);

    // total = 10005, threshold = ~100 (1%)
    // inclusive_times: "main;compute" = 10000, "main" = 10000,
    //   "tiny_root;child_a" = 3, "tiny_root;child_b" = 2, "tiny_root" = 5
    // small_blocks: tiny_root (5), tiny_root;child_a (3), tiny_root;child_b (2)
    //
    // Filter: "main;compute" stays (ancestor "main" not small)
    //   "tiny_root;child_a" removed (ancestor "tiny_root" is small)
    //   "tiny_root;child_b" removed (ancestor "tiny_root" is small)
    //
    // Consolidate: "tiny_root" is top-level small (no small ancestor) -> added with time 5
    //
    // Result: 2 entries
    try std.testing.expectEqual(@as(usize, 2), result.paths.len);

    var found_big = false;
    var found_consolidated = false;
    for (result.paths, result.durations) |p, d| {
        if (std.mem.eql(u8, p, "main;compute") and d == 10000) found_big = true;
        if (std.mem.eql(u8, p, "tiny_root") and d == 5) found_consolidated = true;
    }
    try std.testing.expect(found_big);
    try std.testing.expect(found_consolidated);
}

test "filter removes samples under small ancestor" {
    const allocator = std.testing.allocator;
    // "small_func" accumulates very little total time
    // Children under it should be removed
    const paths = &[_][]const u8{
        "main;big_func",
        "small_func;child1",
        "small_func;child2",
    };
    // big_func takes most of the time; small_func tree is tiny
    const durations = &[_]u64{ 10000, 1, 1 };
    const result = try filter(allocator, paths, durations, 0.01);
    defer result.deinit(allocator);

    // total = 10002, threshold = 100 (1%)
    // inclusive_times:
    //   "main;big_func" = 10000
    //   "main" = 10000
    //   "small_func;child1" = 1
    //   "small_func;child2" = 1
    //   "small_func" = 2
    // small_blocks: "small_func;child1" (1 < 100), "small_func;child2" (1 < 100), "small_func" (2 < 100)
    //
    // Filter:
    //   "main;big_func": ancestor "main" not small -> KEEP
    //   "small_func;child1": ancestor "small_func" IS small -> REMOVE
    //   "small_func;child2": ancestor "small_func" IS small -> REMOVE
    //
    // Consolidate top-level small blocks:
    //   "small_func" has no small ancestor -> top-level small block with time 2
    //   "small_func;child1" has small ancestor "small_func" -> not top-level
    //   "small_func;child2" has small ancestor "small_func" -> not top-level

    // Result: "main;big_func" (10000) + "small_func" (2)
    try std.testing.expectEqual(@as(usize, 2), result.paths.len);

    // Find the consolidated entry
    var found_big = false;
    var found_consolidated = false;
    for (result.paths, result.durations) |p, d| {
        if (std.mem.eql(u8, p, "main;big_func") and d == 10000) found_big = true;
        if (std.mem.eql(u8, p, "small_func") and d == 2) found_consolidated = true;
    }
    try std.testing.expect(found_big);
    try std.testing.expect(found_consolidated);
}

test "filter consolidates small blocks" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{
        "main;big",
        "main;small_root;a",
        "main;small_root;b",
    };
    const durations = &[_]u64{ 10000, 2, 3 };
    const result = try filter(allocator, paths, durations, 0.01);
    defer result.deinit(allocator);

    // total = 10005, threshold = ~100
    // inclusive_times:
    //   "main;big" = 10000
    //   "main;small_root;a" = 2
    //   "main;small_root;b" = 3
    //   "main;small_root" = 5
    //   "main" = 10005
    // small_blocks: "main;small_root;a" (2), "main;small_root;b" (3), "main;small_root" (5)
    //
    // Samples after filter:
    //   "main;big": ancestor "main" not small -> KEEP
    //   "main;small_root;a": ancestors "main" (not small), "main;small_root" (small) -> REMOVE
    //   "main;small_root;b": ancestors "main" (not small), "main;small_root" (small) -> REMOVE
    //
    // Top-level small blocks:
    //   "main;small_root": ancestors = ["main"] which is not small -> top-level, time = 5
    //   "main;small_root;a": ancestor "main;small_root" is small -> not top-level
    //   "main;small_root;b": ancestor "main;small_root" is small -> not top-level

    // Result: "main;big" + consolidated "main;small_root"
    try std.testing.expectEqual(@as(usize, 2), result.paths.len);

    var found_big = false;
    var found_consolidated = false;
    for (result.paths, result.durations) |p, d| {
        if (std.mem.eql(u8, p, "main;big") and d == 10000) found_big = true;
        if (std.mem.eql(u8, p, "main;small_root") and d == 5) found_consolidated = true;
    }
    try std.testing.expect(found_big);
    try std.testing.expect(found_consolidated);
}

test "mismatched lengths returns error" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{"a"};
    const durations = &[_]u64{ 1, 2 };
    const result = filter(allocator, paths, durations, 0.01);
    try std.testing.expectError(FilterError.MismatchedLengths, result);
}

test "threshold below minimum is clamped" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{"main"};
    const durations = &[_]u64{1000};
    // Passing threshold 0.001, below the minimum of 0.005
    const result = try filter(allocator, paths, durations, 0.001);
    defer result.deinit(allocator);

    // Should still work, just using 0.005 as the effective threshold
    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
}
