const std = @import("std");
const builtin = @import("builtin");
const atomic_arc = @import("consts.zig").atomic_arc;

/// A single threaded, strong reference to a reference-counted value.
pub fn RcUnmanaged(comptime T: type) type {
    return RcAlignedUnmanaged(T, null);
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn ArcUnmanaged(comptime T: type) type {
    return ArcAlignedUnmanaged(T, null);
}

/// A single threaded, strong reference to a reference-counted value.
pub fn RcAlignedUnmanaged(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |al| {
        if (al == @alignOf(T)) {
            return RcAlignedUnmanaged(T, null);
        }
    }

    return struct {
        value: if (alignment) |a| *align(a) T else *T,

        const Self = @This();
        const Inner = struct {
            strong: usize,
            weak: usize,
            value: T align(if (alignment) |a| a else @alignOf(T)),

            fn innerSize() comptime_int {
                return @sizeOf(@This());
            }

            fn innerAlign() comptime_int {
                return @alignOf(@This());
            }
        };

        /// Creates a new reference-counted value.
        pub fn init(alloc: std.mem.Allocator, t: T) std.mem.Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 1, .weak = 1, .value = t };
            return Self{ .value = &inner.value };
        }

        /// Constructs a new `Rc` while giving you a `Weak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        pub fn initCyclic(alloc: std.mem.Allocator, comptime data_fn: fn (*Weak) T) std.mem.Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 0, .weak = 1, .value = undefined };

            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak = Weak{ .inner = inner };

            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.value = data_fn(&weak);

            std.debug.assert(inner.strong == 0);
            inner.strong = 1;

            return Self{ .value = &inner.value };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: *const Self) usize {
            return self.innerPtr().strong;
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: *const Self) usize {
            return self.innerPtr().weak - 1;
        }

        /// Increments the strong count.
        pub fn retain(self: *Self) Self {
            self.innerPtr().strong += 1;
            return self.*;
        }

        /// Creates a new weak reference to the pointed value
        pub fn downgrade(self: *Self) Weak {
            return Weak.init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn release(self: Self, alloc: std.mem.Allocator) void {
            const ptr = self.innerPtr();

            ptr.strong -= 1;
            if (ptr.strong == 0) {
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    alloc.destroy(ptr);
                }
            }
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn releaseWithFn(self: Self, alloc: std.mem.Allocator, comptime f: fn (T) void) void {
            const ptr = self.innerPtr();

            ptr.strong -= 1;
            if (ptr.strong == 0) {
                f(self.value.*);
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    alloc.destroy(ptr);
                }
            }
        }

        /// Returns the inner value, if the `Rc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self, alloc: std.mem.Allocator) ?T {
            const ptr = self.innerPtr();

            if (ptr.strong == 1) {
                ptr.strong = 0;
                const tmp = self.value.*;
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    alloc.destroy(ptr);
                }

                return tmp;
            }

            return null;
        }

        /// Total size (in bytes) of the reference counted value on the heap.
        /// This value accounts for the extra memory required to count the references.
        pub fn innerSize() comptime_int {
            return Inner.innerSize();
        }

        /// Alignment (in bytes) of the reference counted value on the heap.
        /// This value accounts for the extra memory required to count the references.
        pub fn innerAlign() comptime_int {
            return Inner.innerAlign();
        }

        inline fn innerPtr(self: *const Self) *Inner {
            return @fieldParentPtr(Inner, "value", self.value);
        }

        /// A single threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: ?*Inner = null,

            /// Creates a new weak reference.
            pub fn init(parent: *RcAlignedUnmanaged(T, alignment)) Weak {
                const ptr = parent.innerPtr();
                ptr.weak += 1;
                return Weak{ .inner = ptr };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: *const Weak) usize {
                return (self.innerPtr() orelse return 0).strong;
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: *const Weak) usize {
                const ptr = self.innerPtr() orelse return 1;
                if (ptr.strong == 0) {
                    return ptr.weak;
                } else {
                    return ptr.weak - 1;
                }
            }

            /// Increments the weak count.
            pub fn retain(self: *Weak) Weak {
                if (self.innerPtr()) |ptr| {
                    ptr.weak += 1;
                }
                return self.*;
            }

            /// Attempts to upgrade the weak pointer to an `Rc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak, alloc: std.mem.Allocator) ?RcAlignedUnmanaged(T, alignment) {
                const ptr = self.innerPtr() orelse return null;

                if (ptr.strong == 0) {
                    ptr.weak -= 1;
                    if (ptr.weak == 0) {
                        alloc.destroy(ptr);
                        self.inner = null;
                    }
                    return null;
                }

                ptr.strong += 1;
                return RcAlignedUnmanaged(T, alignment){
                    .value = &ptr.value,
                };
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak, alloc: std.mem.Allocator) void {
                if (self.innerPtr()) |ptr| {
                    ptr.weak -= 1;
                    if (ptr.weak == 0) {
                        alloc.destroy(ptr);
                    }
                }
            }

            /// Total size (in bytes) of the reference counted value on the heap.
            /// This value accounts for the extra memory required to count the references,
            /// and is valid for single and multi-threaded refrence counters.
            pub fn innerSize() comptime_int {
                return Inner.innerSize();
            }

            /// Alignment (in bytes) of the reference counted value on the heap.
            /// This value accounts for the extra memory required to count the references,
            /// and is valid for single and multi-threaded refrence counters.
            pub fn innerAlign() comptime_int {
                return Inner.innerAlign();
            }

            inline fn innerPtr(self: *const Weak) ?*Inner {
                return @ptrCast(?*Inner, self.inner);
            }
        };
    };
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn ArcAlignedUnmanaged(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |al| {
        if (al == @alignOf(T)) {
            return ArcAlignedUnmanaged(T, null);
        }
    } else if (!atomic_arc) {
        return RcAlignedUnmanaged(T);
    }

    return struct {
        value: if (alignment) |a| *align(a) T else *T,

        const Self = @This();
        const Inner = struct {
            strong: usize align(std.atomic.cache_line),
            weak: usize align(std.atomic.cache_line),
            value: T align(if (alignment) |a| a else @alignOf(T)),

            fn innerSize() comptime_int {
                return @sizeOf(@This());
            }

            fn innerAlign() comptime_int {
                return @alignOf(@This());
            }
        };

        /// Creates a new reference-counted value.
        pub fn init(alloc: std.mem.Allocator, t: T) std.mem.Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 1, .weak = 1, .value = t };
            return Self{ .value = &inner.value };
        }

        /// Constructs a new `Arc` while giving you a `Aweak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        pub fn initCyclic(alloc: std.mem.Allocator, comptime data_fn: fn (*Weak) T) std.mem.Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 0, .weak = 1, .value = undefined };

            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak = Weak{ .inner = inner };

            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.value = data_fn(&weak);

            std.debug.assert(@atomicRmw(usize, &inner.strong, .Add, 1, .Release) == 0);
            return Self{ .value = &inner.value };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: *const Self) usize {
            return @atomicLoad(usize, &self.innerPtr().strong, .Acquire);
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: *const Self) usize {
            return @atomicLoad(usize, &self.innerPtr().weak, .Acquire) - 1;
        }

        /// Increments the strong count.
        pub fn retain(self: *Self) Self {
            _ = @atomicRmw(usize, &self.innerPtr().strong, .Add, 1, .AcqRel);
            return self.*;
        }

        /// Creates a new weak reference to the pointed value.
        pub fn downgrade(self: *Self) Weak {
            return Weak.init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn release(self: Self, alloc: std.mem.Allocator) void {
            const ptr = self.innerPtr();

            if (@atomicRmw(usize, &ptr.strong, .Sub, 1, .AcqRel) == 1) {
                if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .AcqRel) == 1) {
                    alloc.destroy(ptr);
                }
            }
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn releaseWithFn(self: Self, alloc: std.mem.Allocator, comptime f: fn (T) void) void {
            const ptr = self.innerPtr();

            if (@atomicRmw(usize, &ptr.strong, .Sub, 1, .AcqRel) == 1) {
                f(self.value.*);
                if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .AcqRel) == 1) {
                    alloc.destroy(ptr);
                }
            }
        }

        /// Returns the inner value, if the `Arc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self, alloc: std.mem.Allocator) ?T {
            const ptr = self.innerPtr();

            if (@cmpxchgStrong(usize, &ptr.strong, 1, 0, .Monotonic, .Monotonic) == null) {
                ptr.strong = 0;
                const tmp = self.value.*;
                if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .AcqRel) == 1) {
                    alloc.destroy(ptr);
                }
                return tmp;
            }

            return null;
        }

        /// Total size (in bytes) of the reference counted value on the heap.
        /// This value accounts for the extra memory required to count the references.
        pub fn innerSize() comptime_int {
            return Inner.innerSize();
        }

        /// Alignment (in bytes) of the reference counted value on the heap.
        /// This value accounts for the extra memory required to count the references.
        pub fn innerAlign() comptime_int {
            return Inner.innerAlign();
        }

        inline fn innerPtr(self: *const Self) *Inner {
            return @fieldParentPtr(Inner, "value", self.value);
        }

        /// A multi-threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: ?*Inner = null,

            /// Creates a new weak reference.
            pub fn init(parent: *ArcAlignedUnmanaged(T, alignment)) Weak {
                const ptr = parent.innerPtr();
                _ = @atomicRmw(usize, &ptr.weak, .Add, 1, .AcqRel);
                return Weak{ .inner = ptr };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: *const Weak) usize {
                const ptr = self.innerPtr() orelse return 0;
                return @atomicLoad(usize, &ptr.strong, .Acquire);
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: *const Weak) usize {
                const ptr = self.innerPtr() orelse return 1;
                const weak = @atomicLoad(usize, &ptr.weak, .Acquire);

                if (@atomicLoad(usize, &ptr.strong, .Acquire) == 0) {
                    return weak;
                } else {
                    return weak - 1;
                }
            }

            /// Increments the weak count.
            pub fn retain(self: *Weak) Weak {
                if (self.innerPtr()) |ptr| {
                    _ = @atomicRmw(usize, &ptr.weak, .Add, 1, .AcqRel);
                }
                return self.*;
            }

            /// Attempts to upgrade the weak pointer to an `Arc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak, alloc: ?std.mem.Allocator) ?ArcAlignedUnmanaged(T, alignment) {
                const ptr = self.innerPtr() orelse return null;

                while (true) {
                    const prev = @atomicLoad(usize, &ptr.strong, .Acquire);

                    if (prev == 0) {
                        if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .AcqRel) == 1) {
                            if (alloc) |allocator| {
                                allocator.destroy(ptr);
                                self.inner = null;
                            }
                        }
                        return null;
                    }

                    if (@cmpxchgStrong(usize, &ptr.strong, prev, prev + 1, .Acquire, .Monotonic) == null) {
                        return ArcAlignedUnmanaged(T){
                            .value = &ptr.value,
                        };
                    }

                    std.atomic.spinLoopHint();
                }
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak, alloc: std.mem.Allocator) void {
                if (self.innerPtr()) |ptr| {
                    if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .AcqRel) == 1) {
                        alloc.destroy(ptr);
                    }
                }
            }

            /// Total size (in bytes) of the reference counted value on the heap.
            /// This value accounts for the extra memory required to count the references.
            pub fn innerSize() comptime_int {
                return Inner.innerSize();
            }

            /// Alignment (in bytes) of the reference counted value on the heap.
            /// This value accounts for the extra memory required to count the references.
            pub fn innerAlign() comptime_int {
                return Inner.innerAlign();
            }

            inline fn innerPtr(self: *const Weak) ?*Inner {
                return @ptrCast(?*Inner, self.inner);
            }
        };
    };
}

/// Creates a new `RcAlignedUnmanaged` inferring the type of `value`
pub fn rcAlignedUnmanaged(comptime alignment: ?u29, alloc: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!RcAlignedUnmanaged(@TypeOf(value), alignment) {
    return RcAlignedUnmanaged(@TypeOf(value)).init(alloc, value);
}

/// Creates a new `RcUnmanaged` inferring the type of `value`
pub fn rcUnmanaged(alloc: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!RcUnmanaged(@TypeOf(value)) {
    return RcUnmanaged(@TypeOf(value)).init(alloc, value);
}

/// Creates a new `ArcAlignedUnmanaged` inferring the type of `value`
pub fn arcAlignedUnmanaged(comptime alignment: ?u29, alloc: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!ArcAlignedUnmanaged(@TypeOf(value), alignment) {
    return ArcAlignedUnmanaged(@TypeOf(value)).init(alloc, value);
}

/// Creates a new `ArcUnmanaged` inferring the type of `value`
pub fn arcUnmanaged(alloc: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!ArcUnmanaged(@TypeOf(value)) {
    return ArcUnmanaged(@TypeOf(value)).init(alloc, value);
}
