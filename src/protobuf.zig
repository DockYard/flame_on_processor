const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WireType = enum(u3) {
    varint = 0,
    // i64 = 1, // not used
    length_delimited = 2,
    // start_group = 3, // deprecated
    // end_group = 4,   // deprecated
    // i32 = 5, // not used
};

/// Encode a u64 as LEB128 varint.
pub fn writeVarint(writer: anytype, value: u64) !void {
    var v = value;
    while (v > 0x7F) {
        try writer.writeByte(@as(u8, @truncate(v & 0x7F)) | 0x80);
        v >>= 7;
    }
    try writer.writeByte(@as(u8, @truncate(v)));
}

/// Encode an i64 as varint (using standard two's-complement encoding for negative values).
pub fn writeSignedVarint(writer: anytype, value: i64) !void {
    const unsigned: u64 = @bitCast(value);
    try writeVarint(writer, unsigned);
}

/// Write a field tag (field_number << 3 | wire_type).
pub fn writeTag(writer: anytype, field_number: u32, wire_type: WireType) !void {
    const tag: u64 = (@as(u64, field_number) << 3) | @intFromEnum(wire_type);
    try writeVarint(writer, tag);
}

/// Write a length-delimited field: tag + length + bytes.
pub fn writeLengthDelimited(writer: anytype, field_number: u32, data: []const u8) !void {
    try writeTag(writer, field_number, .length_delimited);
    try writeVarint(writer, data.len);
    try writer.writeAll(data);
}

/// Write a packed repeated varint field.
pub fn writePackedVarints(writer: anytype, field_number: u32, values: []const u64, allocator: Allocator) !void {
    // First, encode the values to a temporary buffer to get the length.
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);

    for (values) |v| {
        try writeVarint(tmp.writer(allocator), v);
    }

    try writeTag(writer, field_number, .length_delimited);
    try writeVarint(writer, tmp.items.len);
    try writer.writeAll(tmp.items);
}

/// Write packed repeated signed varint field.
pub fn writePackedSignedVarints(writer: anytype, field_number: u32, values: []const i64, allocator: Allocator) !void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);

    for (values) |v| {
        try writeSignedVarint(tmp.writer(allocator), v);
    }

    try writeTag(writer, field_number, .length_delimited);
    try writeVarint(writer, tmp.items.len);
    try writer.writeAll(tmp.items);
}

/// Write an already-encoded submessage as a length-delimited field.
pub fn writeSubmessage(writer: anytype, field_number: u32, data: []const u8) !void {
    try writeLengthDelimited(writer, field_number, data);
}

test "varint encoding - zero" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVarint(fbs.writer(), 0);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, fbs.getWritten());
}

test "varint encoding - single byte" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVarint(fbs.writer(), 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, fbs.getWritten());
}

test "varint encoding - 127" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVarint(fbs.writer(), 127);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7F}, fbs.getWritten());
}

test "varint encoding - 128 requires two bytes" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVarint(fbs.writer(), 128);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, fbs.getWritten());
}

test "varint encoding - 300" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVarint(fbs.writer(), 300);
    // 300 = 0b100101100 -> 0xAC 0x02
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAC, 0x02 }, fbs.getWritten());
}

test "varint encoding - large value" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVarint(fbs.writer(), 0xFFFFFFFFFFFFFFFF);
    const written = fbs.getWritten();
    try std.testing.expectEqual(@as(usize, 10), written.len);
    // All bytes except the last should have the continuation bit set
    for (written[0..9]) |b| {
        try std.testing.expect(b & 0x80 != 0);
    }
    // Last byte should not have the continuation bit
    try std.testing.expect(written[9] & 0x80 == 0);
}

test "signed varint encoding - positive" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeSignedVarint(fbs.writer(), 42);
    const written = fbs.getWritten();
    try std.testing.expectEqualSlices(u8, &[_]u8{42}, written);
}

test "signed varint encoding - negative" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeSignedVarint(fbs.writer(), -1);
    const written = fbs.getWritten();
    // -1 as u64 is 0xFFFFFFFFFFFFFFFF, which encodes as 10 bytes
    try std.testing.expectEqual(@as(usize, 10), written.len);
}

test "signed varint encoding - zero" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeSignedVarint(fbs.writer(), 0);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, fbs.getWritten());
}

test "length-delimited encoding" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeLengthDelimited(fbs.writer(), 1, "hello");
    const written = fbs.getWritten();
    // Tag: field 1, wire type 2 = (1 << 3) | 2 = 0x0A
    // Length: 5
    // Data: "hello"
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x05, 'h', 'e', 'l', 'l', 'o' }, written);
}

test "length-delimited encoding - empty data" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeLengthDelimited(fbs.writer(), 2, "");
    const written = fbs.getWritten();
    // Tag: field 2, wire type 2 = (2 << 3) | 2 = 0x12
    // Length: 0
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x00 }, written);
}

test "tag encoding" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeTag(fbs.writer(), 1, .varint);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x08}, fbs.getWritten());

    fbs = std.io.fixedBufferStream(&buf);
    try writeTag(fbs.writer(), 1, .length_delimited);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x0A}, fbs.getWritten());

    fbs = std.io.fixedBufferStream(&buf);
    try writeTag(fbs.writer(), 2, .varint);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x10}, fbs.getWritten());
}

test "packed varints encoding" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const values = [_]u64{ 1, 2, 3 };
    try writePackedVarints(fbs.writer(), 1, &values, allocator);
    const written = fbs.getWritten();
    // Tag: field 1, wire type 2 = 0x0A
    // Length: 3 (each value is 1 byte)
    // Values: 1, 2, 3
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x03, 0x01, 0x02, 0x03 }, written);
}
