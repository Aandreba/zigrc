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

// SECURE VARIANTS
//
// These tests verify that `SecureRc` / `SecureArc` zero the entire backing
// allocation on final release.  We back them with a `FixedBufferAllocator`
// whose `free` is a no-op, so any memory that the destructor touched remains
// inspectable after release.  A distinctive marker value is planted in the
// payload and we assert that no byte pattern matching the marker survives
// anywhere in the backing buffer.

test "SecureRc zeroes backing allocation on release" {
    var buffer: [4096]u8 align(64) = undefined;
    @memset(&buffer, 0xAA);
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const a = fba.allocator();

    const marker: u64 = 0xDEADBEEFCAFEBABE;
    var secret = try rc.SecureRc(u64).init(a, marker);
    try expect(secret.value.* == marker);
    try expect(secret.strongCount() == 1);
    secret.release();

    // No byte sequence matching the marker should remain in the buffer.
    const marker_bytes = std.mem.asBytes(&marker);
    try expect(std.mem.indexOf(u8, &buffer, marker_bytes) == null);
}

test "SecureArc zeroes backing allocation on release" {
    var buffer: [4096]u8 align(64) = undefined;
    @memset(&buffer, 0xAA);
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const a = fba.allocator();

    const marker: u64 = 0xFEEDFACECAFEBEEF;
    var secret = try rc.SecureArc(u64).init(a, marker);
    try expect(secret.value.* == marker);
    try expect(secret.strongCount() == 1);
    secret.release();

    const marker_bytes = std.mem.asBytes(&marker);
    try expect(std.mem.indexOf(u8, &buffer, marker_bytes) == null);
}

test "SecureRc zeroes backing when dropped via releaseUnwrap last strong" {
    var buffer: [4096]u8 align(64) = undefined;
    @memset(&buffer, 0xAA);
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const a = fba.allocator();

    const marker: u64 = 0xBADF00D1BADF00D2;
    var secret = try rc.SecureRc(u64).init(a, marker);
    const got = secret.releaseUnwrap();
    try expect(got != null);
    try expect(got.? == marker);

    // The copied-out value is on the stack; the heap backing must have been
    // zeroed by destroy().  We can still see what was previously at the
    // allocation site (FBA free is a no-op), so the marker should be gone.
    const marker_bytes = std.mem.asBytes(&marker);
    try expect(std.mem.indexOf(u8, &buffer, marker_bytes) == null);
}

test "SecureArc type aliases RcAligned under single_threaded" {
    // A compile-time sanity check: SecureArc and SecureRc both accept
    // zero_on_destroy = true and expose the same surface.  In single-threaded
    // builds ArcAligned collapses to RcAligned, which must also thread the
    // zero_on_destroy flag through.  This test just exercises the type path.
    const T = rc.SecureArc(u32);
    var v = try T.init(alloc, 42);
    defer v.release();
    try expect(v.value.* == 42);
    try expect(v.strongCount() == 1);
}
