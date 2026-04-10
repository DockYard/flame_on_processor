const std = @import("std");
const Allocator = std.mem.Allocator;

const profile_filter = @import("profile_filter.zig");
const pprof_encoder = @import("pprof_encoder.zig");

pub const ProcessError = profile_filter.FilterError || pprof_encoder.EncodeError;

/// Process profile data: filter small functions, then encode to pprof protobuf format.
///
/// paths: slice of semicolon-delimited stack paths
/// durations: slice of durations in microseconds, parallel to paths
/// threshold: fraction of total time below which functions are filtered (default 0.01)
///
/// Returns an allocated byte slice containing the protobuf-encoded Profile.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn process(
    allocator: Allocator,
    paths: []const []const u8,
    durations: []const u64,
    threshold: f64,
) ProcessError![]u8 {
    // 1. Filter
    const filtered = try profile_filter.filter(allocator, paths, durations, threshold);
    defer filtered.deinit(allocator);

    // 2. Encode to pprof
    const encoded = try pprof_encoder.encode(allocator, filtered.paths, filtered.durations);
    return encoded;
}

// ============================================================================
// Tests
// ============================================================================

test "process empty input" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{};
    const durations = &[_]u64{};
    const result = try process(allocator, paths, durations, 0.01);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
}

test "process single sample" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{"main;compute"};
    const durations = &[_]u64{5000};
    const result = try process(allocator, paths, durations, 0.01);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
}

test "process filters and encodes" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{
        "main;big_func",
        "small_root;child1",
        "small_root;child2",
    };
    const durations = &[_]u64{ 10000, 1, 1 };
    const result = try process(allocator, paths, durations, 0.01);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
}

test "process mismatched lengths" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{"a"};
    const durations = &[_]u64{ 1, 2 };
    const result = process(allocator, paths, durations, 0.01);
    try std.testing.expectError(ProcessError.MismatchedLengths, result);
}

test "process with multiple samples and hierarchy" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{
        "Elixir.MyApp;handle_call;compute",
        "Elixir.MyApp;handle_call;render",
        "Elixir.MyApp;init",
    };
    const durations = &[_]u64{ 3000, 4000, 1000 };
    const result = try process(allocator, paths, durations, 0.01);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
}
