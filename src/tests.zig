const std = @import("std");
const rc = @import("root.zig");
const expect = std.testing.expect;
const alloc = std.testing.allocator;

// SINGLE THREAD
test "basic" {
    var five = try rc.Rc(i32).init(alloc, 5);
    errdefer five.release();

    five.value.* += 1;
    try expect(five.value.* == 6);

    try expect(five.strongCount() == 1);
    try expect(five.weakCount() == 0);

    var next_five = five.retain();
    try expect(next_five.strongCount() == 2);
    try expect(five.weakCount() == 0);
    next_five.release();

    try expect(five.strongCount() == 1);
    try expect(five.weakCount() == 0);

    try expect(five.tryUnwrap() != null);
}

test "basic slice" {
    var five = try rc.RcSlice(i32).init(alloc, 5);
    five.items[0] = 1;
    errdefer five.release();

    try expect(five.strongCount() == 1);
    var next_five = five.retain();
    try expect(next_five.strongCount() == 2);
    next_five.release();

    try expect(five.strongCount() == 1);
    const maybe_arr = five.tryUnwrap();
    try expect(maybe_arr != null);
    const arr = maybe_arr.?;
    defer arr.deinit();
    std.debug.print("{}\n", .{arr});
    try expect(arr.items.len == 5);
    try expect(arr.items[0] == 1);
}

test "weak" {
    var five = try rc.Rc(i32).init(alloc, 5);
    try expect(five.strongCount() == 1);
    try expect(five.weakCount() == 0);

    // Creates weak reference
    var weak_five = five.downgrade();
    defer weak_five.release();
    try expect(weak_five.strongCount() == 1);
    try expect(weak_five.weakCount() == 1);

    // First upgrade - strong ref still exists
    const first_upgrade = weak_five.upgrade().?;
    try expect(first_upgrade.strongCount() == 2);
    try expect(first_upgrade.weakCount() == 1);

    // Release upgrade
    first_upgrade.release();
    try expect(first_upgrade.strongCount() == 1);
    try expect(first_upgrade.weakCount() == 1);

    // Release strong ref
    five.release();
    try expect(weak_five.strongCount() == 0);
    try expect(weak_five.weakCount() == 1);

    // Second upgrade - strong ref no longer exists
    try expect(weak_five.upgrade() == null);
}

test "cyclic" {
    const Gadget = struct {
        _me: rc.Rc(@This()).Weak,

        const Self = @This();
        const Rc = rc.Rc(@This());
        const Weak = Rc.Weak;

        pub fn init(allocator: std.mem.Allocator) !Rc {
            return Rc.initCyclic(allocator, Self.data_fn, .{});
        }

        pub fn me(self: *Self) Rc {
            return self._me.upgrade().?;
        }

        pub fn deinit(self: Self) void {
            self._me.release();
        }

        fn data_fn(m: *Weak) Self {
            return Self{ ._me = m.retain() };
        }
    };

    var gadget = try Gadget.init(alloc);
    defer if (gadget.releaseUnwrap()) |val| val.deinit();

    try expect(gadget.strongCount() == 1);
    try expect(gadget.weakCount() == 1);
}

// MULTI THREADED
test "basic atomic" {
    var five = try rc.Arc(i32).init(alloc, 5);
    errdefer five.release();

    five.value.* += 1;
    try expect(five.value.* == 6);

    try expect(five.strongCount() == 1);
    try expect(five.weakCount() == 0);

    var next_five = five.retain();
    try expect(next_five.strongCount() == 2);
    try expect(five.weakCount() == 0);
    next_five.release();

    try expect(five.strongCount() == 1);
    try expect(five.weakCount() == 0);

    try expect(five.tryUnwrap() != null);
}

test "weak atomic" {
    var five = try rc.Arc(i32).init(alloc, 5);
    try expect(five.strongCount() == 1);
    try expect(five.weakCount() == 0);

    // Creates weak reference
    var weak_five = five.downgrade();
    defer weak_five.release();
    try expect(weak_five.strongCount() == 1);
    try expect(weak_five.weakCount() == 1);

    // First upgrade - strong ref still exists
    const first_upgrade = weak_five.upgrade().?;
    try expect(first_upgrade.strongCount() == 2);
    try expect(first_upgrade.weakCount() == 1);

    // Release upgrade
    first_upgrade.release();
    try expect(first_upgrade.strongCount() == 1);
    try expect(first_upgrade.weakCount() == 1);

    // Release strong ref
    five.release();
    try expect(weak_five.strongCount() == 0);
    try expect(weak_five.weakCount() == 1);

    // Second upgrade - strong ref no longer exists
    try expect(weak_five.upgrade() == null);
}

test "cyclic atomic" {
    const Gadget = struct {
        _me: rc.Arc(@This()).Weak,

        const Self = @This();
        const Rc = rc.Arc(Self);
        const Weak = Rc.Weak;

        pub fn init(allocator: std.mem.Allocator) !Rc {
            return Rc.initCyclic(allocator, Self.data_fn, .{});
        }

        pub fn me(self: *Self) Rc {
            return self._me.upgrade().?;
        }

        pub fn deinit(self: Self) void {
            self._me.release();
        }

        fn data_fn(m: *Weak) Self {
            return Self{ ._me = m.retain() };
        }
    };

    var gadget = try Gadget.init(alloc);
    defer if (gadget.releaseUnwrap()) |val| val.deinit();

    try expect(gadget.strongCount() == 1);
    try expect(gadget.weakCount() == 1);
}
