const std = @import("std");

/// A single threaded, strong reference to a reference-counted value.
pub fn Rc(comptime T: type) type {
    return struct {
        value: *T,
        alloc: std.mem.Allocator,

        const Self = @This();
        const Inner = RcInner(T);

        /// Creates a new reference-counted value.
        pub fn init(alloc: std.mem.Allocator, t: T) !Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 1, .weak = 1, .value = t };
            return Self{ .value = &inner.value, .alloc = alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: *const Self) usize {
            return self.innerPtr().strong;
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: *const Self) usize {
            return self.innerPtr().weak - 1;
        }

        /// Increments the strong count
        pub fn retain(self: *const Self) Self {
            self.innerPtr().strong += 1;
            return self.*;
        }

        /// Creates a new weak reference to the pointed value
        pub fn downgrade(self: *const Self) Weak(T) {
            return Weak(T).init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        pub fn release(self: *const Self) void {
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

/// A single threaded, weak reference to a reference-counted value.
pub fn Weak(comptime T: type) type {
    return struct {
        inner: ?*align(@alignOf(Inner)) anyopaque = null,
        alloc: std.mem.Allocator,

        const Self = @This();
        const Inner = RcInner(T);

        /// Creates a new weak reference
        pub fn init(parent: *const Rc(T)) Self {
            const ptr = parent.innerPtr();
            ptr.weak += 1;
            return Self{ .inner = ptr, .alloc = parent.alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: *const Self) usize {
            return (self.innerPtr() orelse return 0).strong;
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: *const Self) usize {
            return (self.innerPtr() orelse return 0).weak - 1;
        }

        /// Attempts to upgrade the weak pointer to an `Rc`, delaying dropping of the inner value if successful.
        ///
        /// Returns `null` if the inner value has since been dropped.
        pub fn upgrade(self: Self) ?Rc(T) {
            const ptr = self.innerPtr() orelse return null;

            if (ptr.strong == 0) {
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    self.alloc.destroy(*ptr);
                    ptr = null;
                }
                return null;
            }

            ptr.strong += 1;
            return Rc(T){
                .value = ptr.value,
                .alloc = self.alloc,
            };
        }

        /// Decrements the weak reference count, deallocating if it reaches zero.
        pub fn release(self: *const Self) void {
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
