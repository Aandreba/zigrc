const std = @import("std");
const rc = @import("main.zig");
const expect = std.testing.expect;

threadlocal var gpa = std.heap.GeneralPurposeAllocator(.{}){};

test "basic" {
    var five = try rc.Rc(i32).init(gpa.allocator(), 5);
    defer five.release();

    five.value.* += 1;
    try expect(five.value.* == 6);

    try expect(five.strongCount() == 1);
    try expect(five.weakCount() == 0);

    var next_five = five.retain();
    errdefer next_five.release();
    try expect(next_five.strongCount() == 2);
    try expect(five.weakCount() == 0);
    next_five.release();

    try expect(five.strongCount() == 1);
    try expect(five.weakCount() == 0);
}
