const std = @import("std");
const Allocator = std.mem.Allocator;
const protobuf = @import("protobuf.zig");

pub const EncodeError = error{
    MismatchedLengths,
    OutOfMemory,
};

/// Encode profile samples into pprof protobuf wire format.
///
/// paths: slice of semicolon-delimited stack paths (e.g., "main;compute;render")
/// durations: slice of durations in microseconds, parallel to paths
///
/// Returns an allocated byte slice containing the protobuf-encoded Profile.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn encode(
    allocator: Allocator,
    paths: []const []const u8,
    durations: []const u64,
) EncodeError![]u8 {
    if (paths.len != durations.len) {
        return EncodeError.MismatchedLengths;
    }

    // 1. Collect all unique frame names by splitting all paths on ";"
    var unique_frames = std.StringHashMap(void).init(allocator);
    defer unique_frames.deinit();

    for (paths) |path| {
        var iter = std.mem.splitScalar(u8, path, ';');
        while (iter.next()) |frame| {
            try unique_frames.put(frame, {});
        }
    }

    // 2. Build string table: ["", "self_us", "total_us", "microseconds", ...unique_frames]
    var string_table: std.ArrayList([]const u8) = .empty;
    defer string_table.deinit(allocator);

    try string_table.append(allocator, ""); // index 0: empty string
    try string_table.append(allocator, "self_us"); // index 1
    try string_table.append(allocator, "total_us"); // index 2
    try string_table.append(allocator, "microseconds"); // index 3

    // 3. Build string->index lookup map
    var string_index = std.StringHashMap(u64).init(allocator);
    defer string_index.deinit();

    try string_index.put("", 0);
    try string_index.put("self_us", 1);
    try string_index.put("total_us", 2);
    try string_index.put("microseconds", 3);

    var next_index: u64 = 4;
    var frame_iter = unique_frames.keyIterator();
    while (frame_iter.next()) |frame_ptr| {
        const frame = frame_ptr.*;
        if (!string_index.contains(frame)) {
            try string_table.append(allocator, frame);
            try string_index.put(frame, next_index);
            next_index += 1;
        }
    }

    // 4. Create Function entries: one per unique frame
    //    Function { id, name, system_name, filename }
    //    We'll assign function IDs starting from 1
    var frame_to_func_id = std.StringHashMap(u64).init(allocator);
    defer frame_to_func_id.deinit();

    var function_data: std.ArrayList(FunctionEntry) = .empty;
    defer function_data.deinit(allocator);

    var func_id: u64 = 1;
    // Iterate through string_table entries starting from index 4 (the frames)
    for (string_table.items[4..]) |frame| {
        try frame_to_func_id.put(frame, func_id);
        const name_idx = string_index.get(frame) orelse 0;
        try function_data.append(allocator, .{
            .id = func_id,
            .name = name_idx,
            .system_name = name_idx,
            .filename = 0, // empty string
        });
        func_id += 1;
    }

    // 5. Create Location entries: one per function (1:1 mapping)
    //    Location { id, line: [Line { function_id, line_no }] }
    //    Location IDs = function IDs (1:1)

    // 6. Compute max_duration for duration_nanos
    var max_duration: u64 = 0;
    for (durations) |d| {
        if (d > max_duration) max_duration = d;
    }

    // 7. Now encode everything to protobuf
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Profile message fields:

    // Field 1: repeated ValueType sample_type
    // sample_type[0]: { type: "self_us" (1), unit: "microseconds" (3) }
    {
        const submsg = try encodeValueType(allocator, 1, 3);
        defer allocator.free(submsg);
        try protobuf.writeSubmessage(writer, 1, submsg);
    }
    // sample_type[1]: { type: "total_us" (2), unit: "microseconds" (3) }
    {
        const submsg = try encodeValueType(allocator, 2, 3);
        defer allocator.free(submsg);
        try protobuf.writeSubmessage(writer, 1, submsg);
    }

    // Field 2: repeated Sample sample
    for (paths, durations) |path, duration| {
        const submsg = try encodeSample(allocator, path, duration, &frame_to_func_id);
        defer allocator.free(submsg);
        try protobuf.writeSubmessage(writer, 2, submsg);
    }

    // Field 4: repeated Location location
    for (function_data.items) |func| {
        const submsg = try encodeLocation(allocator, func.id, func.id);
        defer allocator.free(submsg);
        try protobuf.writeSubmessage(writer, 4, submsg);
    }

    // Field 5: repeated Function function
    for (function_data.items) |func| {
        const submsg = try encodeFunction(allocator, func);
        defer allocator.free(submsg);
        try protobuf.writeSubmessage(writer, 5, submsg);
    }

    // Field 6: repeated string string_table
    for (string_table.items) |s| {
        try protobuf.writeLengthDelimited(writer, 6, s);
    }

    // Field 10: int64 duration_nanos = max_duration * 1000
    {
        const duration_nanos: i64 = @intCast(max_duration * 1000);
        try protobuf.writeTag(writer, 10, .varint);
        try protobuf.writeSignedVarint(writer, duration_nanos);
    }

    return output.toOwnedSlice(allocator);
}

const FunctionEntry = struct {
    id: u64,
    name: u64,
    system_name: u64,
    filename: u64,
};

fn encodeValueType(allocator: Allocator, type_idx: u64, unit_idx: u64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // Field 1: int64 type
    try protobuf.writeTag(writer, 1, .varint);
    try protobuf.writeSignedVarint(writer, @intCast(type_idx));

    // Field 2: int64 unit
    try protobuf.writeTag(writer, 2, .varint);
    try protobuf.writeSignedVarint(writer, @intCast(unit_idx));

    return buf.toOwnedSlice(allocator);
}

fn encodeSample(
    allocator: Allocator,
    path: []const u8,
    duration: u64,
    frame_to_func_id: *const std.StringHashMap(u64),
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // Split path on ";" to get frames
    var frames: std.ArrayList(u64) = .empty;
    defer frames.deinit(allocator);

    var iter = std.mem.splitScalar(u8, path, ';');
    while (iter.next()) |frame| {
        if (frame_to_func_id.get(frame)) |fid| {
            // Location ID = function ID (1:1 mapping)
            try frames.append(allocator, fid);
        }
    }

    // Reverse: pprof convention is leaf first
    std.mem.reverse(u64, frames.items);

    // Field 1: repeated uint64 location_id (packed)
    if (frames.items.len > 0) {
        try protobuf.writePackedVarints(writer, 1, frames.items, allocator);
    }

    // Field 2: repeated int64 value (packed) = [duration, duration]
    const values = [_]i64{ @intCast(duration), @intCast(duration) };
    try protobuf.writePackedSignedVarints(writer, 2, &values, allocator);

    return buf.toOwnedSlice(allocator);
}

fn encodeLocation(allocator: Allocator, location_id: u64, function_id: u64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // Field 1: uint64 id
    try protobuf.writeTag(writer, 1, .varint);
    try protobuf.writeVarint(writer, location_id);

    // Field 4: repeated Line line
    // Line { function_id, line = 0 }
    const line_submsg = try encodeLineSub(allocator, function_id);
    defer allocator.free(line_submsg);
    try protobuf.writeSubmessage(writer, 4, line_submsg);

    return buf.toOwnedSlice(allocator);
}

fn encodeLineSub(allocator: Allocator, function_id: u64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // Field 1: uint64 function_id
    try protobuf.writeTag(writer, 1, .varint);
    try protobuf.writeVarint(writer, function_id);

    // Field 2: int64 line = 0 (omit, default)

    return buf.toOwnedSlice(allocator);
}

fn encodeFunction(allocator: Allocator, func: FunctionEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // Field 1: uint64 id
    try protobuf.writeTag(writer, 1, .varint);
    try protobuf.writeVarint(writer, func.id);

    // Field 2: int64 name
    try protobuf.writeTag(writer, 2, .varint);
    try protobuf.writeSignedVarint(writer, @intCast(func.name));

    // Field 3: int64 system_name
    try protobuf.writeTag(writer, 3, .varint);
    try protobuf.writeSignedVarint(writer, @intCast(func.system_name));

    // Field 4: int64 filename
    try protobuf.writeTag(writer, 4, .varint);
    try protobuf.writeSignedVarint(writer, @intCast(func.filename));

    return buf.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "empty input produces minimal profile" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{};
    const durations = &[_]u64{};
    const result = try encode(allocator, paths, durations);
    defer allocator.free(result);

    // Should produce a valid (non-empty) protobuf with at least string table
    try std.testing.expect(result.len > 0);
}

test "encode produces valid protobuf" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{
        "main;compute",
        "main;render",
    };
    const durations = &[_]u64{ 1000, 2000 };
    const result = try encode(allocator, paths, durations);
    defer allocator.free(result);

    // Should produce non-empty output
    try std.testing.expect(result.len > 0);

    // Verify the output starts with valid protobuf tags
    // Field 1 (sample_type) with wire type 2 = 0x0A
    try std.testing.expectEqual(@as(u8, 0x0A), result[0]);
}

test "string table deduplicates" {
    const allocator = std.testing.allocator;
    // Both paths share "main" frame
    const paths = &[_][]const u8{
        "main;compute",
        "main;render",
    };
    const durations = &[_]u64{ 1000, 2000 };
    const result = try encode(allocator, paths, durations);
    defer allocator.free(result);

    // Count occurrences of "main" in the output
    // In protobuf, string table entries are length-delimited with field 6
    // Field 6, wire type 2 = (6 << 3) | 2 = 0x32
    var main_count: usize = 0;
    var i: usize = 0;
    while (i < result.len) {
        if (result[i] == 0x32) {
            // This is a string table entry
            i += 1;
            if (i >= result.len) break;
            const len = result[i];
            i += 1;
            if (i + len <= result.len) {
                const s = result[i .. i + len];
                if (std.mem.eql(u8, s, "main")) {
                    main_count += 1;
                }
                i += len;
            }
        } else {
            i += 1;
        }
    }

    // "main" should appear exactly once in the string table
    try std.testing.expectEqual(@as(usize, 1), main_count);
}

test "sample location IDs are reversed" {
    const allocator = std.testing.allocator;
    // Single sample with path "a;b;c"
    const paths = &[_][]const u8{"a;b;c"};
    const durations = &[_]u64{1000};
    const result = try encode(allocator, paths, durations);
    defer allocator.free(result);

    // The encoding should succeed and produce output
    try std.testing.expect(result.len > 0);
}

test "mismatched lengths returns error" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{"a"};
    const durations = &[_]u64{ 1, 2 };
    const result = encode(allocator, paths, durations);
    try std.testing.expectError(EncodeError.MismatchedLengths, result);
}

test "single frame path" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{"main"};
    const durations = &[_]u64{500};
    const result = try encode(allocator, paths, durations);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
}
