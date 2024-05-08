const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// A single threaded, strong reference to a reference-counted value.
pub fn Rc(comptime T: type) type {
    return struct {
        value: *T,
        alloc: Allocator,

        const Self = @This();
        const Unmanaged = RcUnmanaged(T);
        const Inner = Unmanaged.Inner;

        /// Creates a new reference-counted value.
        pub fn init(alloc: Allocator, t: T) Allocator.Error!Self {
            return Self{
                .value = (try Unmanaged.init(alloc, t)).value,
                .alloc = alloc,
            };
        }

        /// Constructs a new `Rc` while giving you a `Weak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        pub fn initCyclic(alloc: Allocator, comptime data_fn: fn (*Weak) T) Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 0, .weak = 1, .value = undefined };

            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak = Weak{ .inner = inner, .alloc = alloc };

            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.value = data_fn(&weak);

            std.debug.assert(inner.strong == 0);
            inner.strong = 1;

            return Self{ .value = &inner.value, .alloc = alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: Self) usize {
            return self.asUnmanaged().strongCount();
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: Self) usize {
            return self.asUnmanaged().weakCount();
        }

        /// Increments the strong count.
        pub fn retain(self: Self) Self {
            _ = self.asUnmanaged().retain();
            return self;
        }

        /// Creates a new weak reference to the pointed value
        pub fn downgrade(self: Self) Weak {
            return Weak.init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn release(self: Self) void {
            return self.asUnmanaged().release(self.alloc);
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn releaseWithFn(self: Self, comptime f: fn (T) void) void {
            return self.asUnmanaged().releaseWithFn(self.alloc, f);
        }

        /// Returns the inner value, if the `Rc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self) ?T {
            return self.asUnmanaged().tryUnwrap(self.alloc);
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

        inline fn asUnmanaged(self: Self) Unmanaged {
            return .{ .value = self.value };
        }

        inline fn innerPtr(self: Self) *Inner {
            return @alignCast(@fieldParentPtr("value", self.value));
        }

        /// A single threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: ?*Inner = null,
            alloc: Allocator,

            const WeakUnmanaged = Unmanaged.Weak;

            /// Creates a new weak reference.
            pub fn init(parent: Rc(T)) Weak {
                return Weak{
                    .inner = WeakUnmanaged.init(parent.asUnmanaged()).inner,
                    .alloc = parent.alloc,
                };
            }

            /// Creates a new weak reference object from a pointer to it's underlying value,
            /// without increasing the weak count.
            pub fn fromValuePtr(value: *T) Weak {
                return .{ .inner = @fieldParentPtr("value", value) };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: Weak) usize {
                return self.asUnmanaged().strongCount();
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: Weak) usize {
                return self.asUnmanaged().weakCount();
            }

            /// Increments the weak count.
            pub fn retain(self: Weak) Weak {
                _ = self.asUnmanaged().retain();
                return self;
            }

            /// Attempts to upgrade the weak pointer to an `Rc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak) ?Rc(T) {
                const ptr = self.innerPtr() orelse return null;

                if (ptr.strong == 0) {
                    ptr.weak -= 1;
                    if (ptr.weak == 0) {
                        self.alloc.destroy(ptr);
                        self.inner = null;
                    }
                    return null;
                }

                ptr.strong += 1;
                return .{
                    .value = &ptr.value,
                    .alloc = self.alloc,
                };
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak) void {
                return self.asUnmanaged().release(self.alloc);
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

            inline fn asUnmanaged(self: Weak) WeakUnmanaged {
                return .{ .inner = self.inner };
            }

            inline fn innerPtr(self: Weak) ?*Inner {
                return @as(?*Inner, @ptrCast(self.inner));
            }
        };
    };
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn Arc(comptime T: type) type {
    if (builtin.single_threaded) return Rc(T);

    return struct {
        value: *T,
        alloc: Allocator,

        const Self = @This();
        const Unmanaged = ArcUnmanaged(T);
        const Inner = Unmanaged.Inner;

        /// Creates a new reference-counted value.
        pub fn init(alloc: Allocator, t: T) Allocator.Error!Self {
            return Self{
                .value = (try Unmanaged.init(alloc, t)).value,
                .alloc = alloc,
            };
        }

        /// Constructs a new `Arc` while giving you a `Aweak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        pub fn initCyclic(alloc: Allocator, comptime data_fn: fn (*Weak) T) Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 0, .weak = 1, .value = undefined };

            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak = Weak{ .inner = inner, .alloc = alloc };

            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.value = data_fn(&weak);

            std.debug.assert(@atomicRmw(usize, &inner.strong, .Add, 1, .release) == 0);
            return Self{ .value = &inner.value, .alloc = alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: Self) usize {
            return self.asUnmanaged().strongCount();
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: Self) usize {
            return self.asUnmanaged().weakCount();
        }

        /// Increments the strong count.
        pub fn retain(self: Self) Self {
            _ = self.asUnmanaged().retain();
            return self;
        }

        /// Creates a new weak reference to the pointed value.
        pub fn downgrade(self: Self) Weak {
            return Weak.init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn release(self: Self) void {
            return self.asUnmanaged().release(self.alloc);
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn releaseWithFn(self: Self, comptime f: fn (T) void) void {
            return self.asUnmanaged().releaseWithFn(self.alloc, f);
        }

        /// Returns the inner value, if the `Arc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self) ?T {
            return self.asUnmanaged().tryUnwrap(self.alloc);
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

        inline fn asUnmanaged(self: Self) Unmanaged {
            return .{ .value = self.value };
        }

        inline fn innerPtr(self: Self) *Inner {
            return @alignCast(@fieldParentPtr("value", self.value));
        }

        /// A multi-threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: ?*Inner = null,
            alloc: Allocator,

            const UnmanagedWeak = Unmanaged.Weak;

            /// Creates a new weak reference.
            pub fn init(parent: Arc(T)) Weak {
                return Weak{
                    .inner = UnmanagedWeak.init(parent.asUnmanaged()).inner,
                    .alloc = parent.alloc,
                };
            }

            /// Creates a new weak reference object from a pointer to it's underlying value,
            /// without increasing the weak count.
            pub fn fromValuePtr(value: *T, alloc: Allocator) Weak {
                return .{ .inner = @fieldParentPtr("value", value), .alloc = alloc };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: Weak) usize {
                return self.asUnmanaged().strongCount();
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: Weak) usize {
                return self.asUnmanaged().weakCount();
            }

            /// Increments the weak count.
            pub fn retain(self: Weak) Weak {
                _ = self.asUnmanaged().retain();
                return self;
            }

            /// Attempts to upgrade the weak pointer to an `Arc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak) ?Arc(T) {
                const ptr = self.innerPtr() orelse return null;

                while (true) {
                    const prev = @atomicLoad(usize, &ptr.strong, .acquire);

                    if (prev == 0) {
                        if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .acq_rel) == 1) {
                            self.alloc.destroy(ptr);
                            self.inner = null;
                        }
                        return null;
                    }

                    if (@cmpxchgStrong(usize, &ptr.strong, prev, prev + 1, .acquire, .monotonic) == null) {
                        return .{
                            .value = &ptr.value,
                            .alloc = self.alloc,
                        };
                    }

                    std.atomic.spinLoopHint();
                }
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak) void {
                return self.asUnmanaged().release(self.alloc);
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

            inline fn asUnmanaged(self: Weak) UnmanagedWeak {
                return .{ .inner = self.inner };
            }

            inline fn innerPtr(self: Weak) ?*Inner {
                return @as(?*Inner, @ptrCast(self.inner));
            }
        };
    };
}

/// A single threaded, strong reference to a reference-counted value.
pub fn RcUnmanaged(comptime T: type) type {
    return RcAlignedUnmanaged(T, null);
}

/// A single threaded, strong reference to a reference-counted value.
pub fn RcAlignedUnmanaged(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return RcAlignedUnmanaged(T, null);
        }
    }

    return struct {
        value: if (alignment) |a| *align(a) T else *T,

        const Self = @This();
        const Inner = struct {
            strong: usize,
            weak: usize,
            value: T align(alignment orelse @alignOf(T)),

            fn innerSize() comptime_int {
                return @sizeOf(@This());
            }

            fn innerAlign() comptime_int {
                return @alignOf(@This());
            }
        };

        /// Creates a new reference-counted value.
        pub fn init(alloc: Allocator, t: T) Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 1, .weak = 1, .value = t };
            return Self{ .value = &inner.value };
        }

        /// Constructs a new `Rc` while giving you a `Weak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        pub fn initCyclic(alloc: Allocator, comptime data_fn: fn (*Weak) T) Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 0, .weak = 1, .value = undefined };

            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak = Weak{ .inner = inner, .alloc = alloc };

            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.value = data_fn(&weak);

            std.debug.assert(inner.strong == 0);
            inner.strong = 1;

            return Self{ .value = &inner.value, .alloc = alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: Self) usize {
            return self.innerPtr().strong;
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: Self) usize {
            return self.innerPtr().weak - 1;
        }

        /// Increments the strong count.
        pub fn retain(self: Self) Self {
            self.innerPtr().strong += 1;
            return self;
        }

        /// Creates a new weak reference to the pointed value
        pub fn downgrade(self: Self) Weak {
            return Weak.init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn release(self: Self, allocator: Allocator) void {
            const ptr = self.innerPtr();

            ptr.strong -= 1;
            if (ptr.strong == 0) {
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    allocator.destroy(ptr);
                }
            }
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn releaseWithFn(self: Self, allocator: Allocator, comptime f: fn (T) void) void {
            const ptr = self.innerPtr();

            ptr.strong -= 1;
            if (ptr.strong == 0) {
                f(self.value.*);

                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    allocator.destroy(ptr);
                }
            }
        }

        /// Returns the inner value, if the `Rc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self, allocator: Allocator) ?T {
            const ptr = self.innerPtr();

            if (ptr.strong == 1) {
                ptr.strong = 0;
                const tmp = self.value.*;

                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    allocator.destroy(ptr);
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

        inline fn innerPtr(self: Self) *Inner {
            return @alignCast(@fieldParentPtr("value", self.value));
        }

        /// A single threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: ?*Inner = null,

            /// Creates a new weak reference.
            pub fn init(parent: RcAlignedUnmanaged(T, alignment)) Weak {
                const ptr = parent.innerPtr();
                ptr.weak += 1;
                return Weak{ .inner = ptr };
            }

            /// Creates a new weak reference object from a pointer to it's underlying value,
            /// without increasing the weak count.
            pub fn fromValuePtr(value: *T) Weak {
                return .{ .inner = @fieldParentPtr("value", value) };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: Weak) usize {
                return (self.innerPtr() orelse return 0).strong;
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: Weak) usize {
                const ptr = self.innerPtr() orelse return 1;
                if (ptr.strong == 0) {
                    return ptr.weak;
                } else {
                    return ptr.weak - 1;
                }
            }

            /// Increments the weak count.
            pub fn retain(self: Weak) Weak {
                if (self.innerPtr()) |ptr| {
                    ptr.weak += 1;
                }
                return self;
            }

            /// Attempts to upgrade the weak pointer to an `Rc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak, allocator: Allocator) ?RcAlignedUnmanaged(T, alignment) {
                const ptr = self.innerPtr() orelse return null;

                if (ptr.strong == 0) {
                    ptr.weak -= 1;
                    if (ptr.weak == 0) {
                        allocator.destroy(ptr);
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
            pub fn release(self: Weak, allocator: Allocator) void {
                if (self.innerPtr()) |ptr| {
                    ptr.weak -= 1;
                    if (ptr.weak == 0) {
                        allocator.destroy(ptr);
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

            inline fn innerPtr(self: Weak) ?*Inner {
                return @as(?*Inner, @ptrCast(self.inner));
            }
        };
    };
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn ArcUnmanaged(comptime T: type) type {
    return ArcAlignedUnmanaged(T, null);
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn ArcAlignedUnmanaged(comptime T: type, comptime alignment: ?u29) type {
    if (builtin.single_threaded) return RcAlignedUnmanaged(T, alignment);
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return ArcAlignedUnmanaged(T, null);
        }
    }

    return struct {
        value: if (alignment) |a| *align(a) T else *T,

        const Self = @This();
        const Inner = struct {
            strong: usize align(std.atomic.cache_line),
            weak: usize align(std.atomic.cache_line),
            value: T align(alignment orelse @alignOf(T)),

            fn innerSize() comptime_int {
                return @sizeOf(@This());
            }

            fn innerAlign() comptime_int {
                return @alignOf(@This());
            }
        };

        /// Creates a new reference-counted value.
        pub fn init(alloc: Allocator, t: T) Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 1, .weak = 1, .value = t };
            return Self{ .value = &inner.value };
        }

        /// Constructs a new `Arc` while giving you a `Aweak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        pub fn initCyclic(alloc: Allocator, comptime data_fn: fn (*Weak) T) Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 0, .weak = 1, .value = undefined };

            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak = Weak{ .inner = inner, .alloc = alloc };

            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.value = data_fn(&weak);

            std.debug.assert(@atomicRmw(usize, &inner.strong, .Add, 1, .release) == 0);
            return Self{ .value = &inner.value, .alloc = alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: Self) usize {
            return @atomicLoad(usize, &self.innerPtr().strong, .acquire);
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: Self) usize {
            return @atomicLoad(usize, &self.innerPtr().weak, .acquire) - 1;
        }

        /// Increments the strong count.
        pub fn retain(self: Self) Self {
            _ = @atomicRmw(usize, &self.innerPtr().strong, .Add, 1, .acq_rel);
            return self;
        }

        /// Creates a new weak reference to the pointed value.
        pub fn downgrade(self: Self) Weak {
            return Weak.init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn release(self: Self, allocator: Allocator) void {
            const ptr = self.innerPtr();

            if (@atomicRmw(usize, &ptr.strong, .Sub, 1, .acq_rel) == 1) {
                if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .acq_rel) == 1) {
                    allocator.destroy(ptr);
                }
            }
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn releaseWithFn(self: Self, allocator: Allocator, comptime f: fn (T) void) void {
            const ptr = self.innerPtr();

            if (@atomicRmw(usize, &ptr.strong, .Sub, 1, .acq_rel) == 1) {
                f(self.value.*);
                if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .acq_rel) == 1) {
                    allocator.destroy(ptr);
                }
            }
        }

        /// Returns the inner value, if the `Arc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self, allocator: Allocator) ?T {
            const ptr = self.innerPtr();

            if (@cmpxchgStrong(usize, &ptr.strong, 1, 0, .monotonic, .monotonic) == null) {
                ptr.strong = 0;
                const tmp = self.value.*;
                if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .acq_rel) == 1) {
                    allocator.destroy(ptr);
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

        inline fn innerPtr(self: Self) *Inner {
            return @alignCast(@fieldParentPtr("value", self.value));
        }

        /// A multi-threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: ?*Inner = null,

            /// Creates a new weak reference.
            pub fn init(parent: ArcAlignedUnmanaged(T, alignment)) Weak {
                const ptr = parent.innerPtr();
                _ = @atomicRmw(usize, &ptr.weak, .Add, 1, .acq_rel);
                return Weak{ .inner = ptr };
            }

            /// Creates a new weak reference object from a pointer to it's underlying value,
            /// without increasing the weak count.
            pub fn fromValuePtr(value: *T) Weak {
                return .{ .inner = @fieldParentPtr("value", value) };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: Weak) usize {
                const ptr = self.innerPtr() orelse return 0;
                return @atomicLoad(usize, &ptr.strong, .acquire);
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: Weak) usize {
                const ptr = self.innerPtr() orelse return 1;
                const weak = @atomicLoad(usize, &ptr.weak, .acquire);

                if (@atomicLoad(usize, &ptr.strong, .acquire) == 0) {
                    return weak;
                } else {
                    return weak - 1;
                }
            }

            /// Increments the weak count.
            pub fn retain(self: Weak) Weak {
                if (self.innerPtr()) |ptr| {
                    _ = @atomicRmw(usize, &ptr.weak, .Add, 1, .acq_rel);
                }
                return self;
            }

            /// Attempts to upgrade the weak pointer to an `Arc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak, allocator: Allocator) ?ArcAlignedUnmanaged(T, alignment) {
                const ptr = self.innerPtr() orelse return null;

                while (true) {
                    const prev = @atomicLoad(usize, &ptr.strong, .acquire);

                    if (prev == 0) {
                        if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .acq_rel) == 1) {
                            allocator.destroy(ptr);
                            self.inner = null;
                        }
                        return null;
                    }

                    if (@cmpxchgStrong(usize, &ptr.strong, prev, prev + 1, .acquire, .monotonic) == null) {
                        return ArcAlignedUnmanaged(T, alignment){
                            .value = &ptr.value,
                        };
                    }

                    std.atomic.spinLoopHint();
                }
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak, allocator: Allocator) void {
                if (self.innerPtr()) |ptr| {
                    if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .acq_rel) == 1) {
                        allocator.destroy(ptr);
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

            inline fn innerPtr(self: Weak) ?*Inner {
                return @as(?*Inner, @ptrCast(self.inner));
            }
        };
    };
}

/// Creates a new `Rc` inferring the type of `value`
pub fn rc(alloc: Allocator, value: anytype) Allocator.Error!Rc(@TypeOf(value)) {
    return Rc(@TypeOf(value)).init(alloc, value);
}

/// Creates a new `Arc` inferring the type of `value`
pub fn arc(alloc: Allocator, value: anytype) Allocator.Error!Arc(@TypeOf(value)) {
    return Arc(@TypeOf(value)).init(alloc, value);
}

/// Creates a new `Rc` inferring the type of `value`
pub fn unmanagedRc(alloc: Allocator, value: anytype) Allocator.Error!RcUnmanaged(@TypeOf(value)) {
    return RcUnmanaged(@TypeOf(value)).init(alloc, value);
}

/// Creates a new `Arc` inferring the type of `value`
pub fn unmanagedArc(alloc: Allocator, value: anytype) Allocator.Error!ArcUnmanaged(@TypeOf(value)) {
    return ArcUnmanaged(@TypeOf(value)).init(alloc, value);
}
