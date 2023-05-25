const std = @import("std");

/// This structure is not thread-safe.
pub fn Rc(comptime T: type) type {
    return struct {
        value: *const T,
        alloc: std.mem.Allocator,

        const Self = @This();
        const Inner = RcInner(T);

        pub fn init(alloc: std.mem.Allocator, t: T) Self {
            const inner = alloc.create(Inner);
            inner.* = Inner{ .strong = 1, .weak = 1, .value = t };
        }

        /// Increments the reference count
        pub fn retain(self: *const Self) void {
            self.innerPtr().strong += 1;
        }

        /// Creates a new weak reference to the pointed value
        pub fn downgrade(self: *const Self) Weak(T) {
            _ = self;
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        pub fn deinit(self: *const Self) void {
            const ptr = self.innerPtr();

            ptr.strong -= 1;
            if (ptr.strong == 0) {
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    self.alloc.destroy(ptr);
                }
            }
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero
        pub fn deinitWithFn(self: *const Self, f: fn (T) void) void {
            const ptr = self.innerPtr();

            ptr.strong -= 1;
            if (ptr.strong == 0) {
                f(self.value.*);

                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    self.alloc.destroy(ptr);
                }
            }
        }

        inline fn innerPtr(self: *const Self) *Inner {
            return @fieldParentPtr(Inner, "value", self.value);
        }
    };
}

/// This structure is not thread-safe.
pub fn Weak(comptime T: type) type {
    return struct {
        inner: ?*align(@alignOf(Inner)) anyopaque,
        alloc: std.mem.Allocator,

        pub const SelfRc = Rc(T);
        const Self = @This();
        const Inner = RcInner(T);

        pub fn init(parent: *const SelfRc) Self {
            const ptr = parent.innerPtr();
            ptr.weak += 1;
            return Self{ .inner = ptr, .alloc = parent.alloc };
        }

        pub fn upgrade(self: Self) ?SelfRc {
            const ptr = self.innerPtr() orelse return null;

            if (ptr.strong == 0) {
                self.deinit();
                return null;
            }

            ptr.strong += 1;
            return SelfRc{
                .value = ptr.value,
                .alloc = self.alloc,
            };
        }

        pub fn deinit(self: *const Self) void {
            if (self.innerPtr()) |*ptr| {
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    self.alloc.destroy(*ptr);
                    ptr = null;
                }
            }
        }

        inline fn innerPtr(self: *const Self) ?*Inner {
            return @ptrCast(?*Inner, self.inner);
        }
    };
}

fn RcInner(comptime T: type) type {
    return struct {
        strong: usize,
        weak: usize,
        value: T,
    };
}
