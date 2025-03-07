const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// A single threaded, strong reference to a reference-counted value.
pub fn Rc(comptime T: type) type {
    return RcAligned(T, @alignOf(T));
}

/// A single threaded, strong reference to a reference-counted value.
pub fn RcAligned(comptime T: type, comptime alignment: u29) type {
    return struct {
        value: *align(internal_alignment) T,
        alloc: Allocator,

        const Self = @This();
        const Unmanaged = RcAlignedUnmanaged(T, alignment);
        pub const internal_alignment = Unmanaged.internal_alignment;
        pub const total_size = Unmanaged.total_size;

        /// Creates a new reference-counted value.
        pub fn init(alloc: Allocator, t: T) Allocator.Error!Self {
            return Self{
                .value = (try Unmanaged.init(alloc, t)).value,
                .alloc = alloc,
            };
        }

        /// Constructs a new `Rc` while giving you a `Weak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        /// `data_fn` has the signature `fn(*Weak, ...data_args) T`
        pub fn initCyclic(alloc: Allocator, comptime data_fn: anytype, data_args: anytype) Allocator.Error!Self {
            const inner = try Unmanaged.create(alloc);
            Unmanaged.ptrToStrong(inner).* = 0;
            Unmanaged.ptrToWeak(inner).* = 1;
            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak_ptr = Weak{ .inner = Unmanaged.Weak.fromValuePtr(inner), .alloc = alloc };
            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.* = @call(.auto, data_fn, .{&weak_ptr} ++ data_args);
            std.debug.assert(Unmanaged.ptrToStrong(inner).* == 0);
            Unmanaged.ptrToStrong(inner).* = 1;
            return Self{ .value = inner, .alloc = alloc };
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

        /// Decrements the reference count, deallocating if the weak count reaches zero,
        /// and returning the underlying value if the strong count reaches zero.
        /// The continued use of the pointer after calling this method is undefined behaviour.
        pub fn releaseUnwrap(self: Self) ?T {
            return self.asUnmanaged().releaseUnwrap(self.alloc);
        }

        /// Returns the inner value, if the `Rc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self) ?T {
            return self.asUnmanaged().tryUnwrap(self.alloc);
        }

        inline fn asUnmanaged(self: Self) Unmanaged {
            return .{ .value = self.value };
        }

        /// A single threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: WeakUnmanaged = .{},
            alloc: Allocator,

            const WeakUnmanaged = Unmanaged.Weak;

            /// Creates a new weak reference.
            pub fn init(parent: RcAligned(T, alignment)) Weak {
                return Weak{
                    .inner = WeakUnmanaged.init(parent.asUnmanaged()),
                    .alloc = parent.alloc,
                };
            }

            /// Creates a new weak reference object from a pointer to it's underlying value,
            /// without increasing the weak count.
            pub fn fromValuePtr(value: *align(internal_alignment) T) Weak {
                return .{ .inner = @ptrCast(value) };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: Weak) usize {
                return self.inner.strongCount();
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: Weak) usize {
                return self.inner.weakCount();
            }

            /// Increments the weak count.
            pub fn retain(self: Weak) Weak {
                _ = self.inner.retain();
                return self;
            }

            /// Attempts to upgrade the weak pointer to an `Rc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak) ?RcAligned(T, alignment) {
                if (self.inner.upgrade(self.alloc)) |ptr| return RcAligned(T, alignment){
                    .value = ptr.value,
                    .alloc = self.alloc,
                };
                return null;
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak) void {
                return self.inner.release(self.alloc);
            }
        };
    };
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn Arc(comptime T: type) type {
    return ArcAligned(T, @alignOf(T));
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn ArcAligned(comptime T: type, comptime alignment: u29) type {
    if (builtin.single_threaded) return RcAligned(T, alignment);
    return struct {
        value: *align(internal_alignment) T,
        alloc: Allocator,

        const Self = @This();
        const Unmanaged = ArcAlignedUnmanaged(T, alignment);
        pub const internal_alignment = Unmanaged.internal_alignment;
        pub const total_size = Unmanaged.total_size;

        /// Creates a new reference-counted value.
        pub fn init(alloc: Allocator, t: T) Allocator.Error!Self {
            return Self{
                .value = (try Unmanaged.init(alloc, t)).value,
                .alloc = alloc,
            };
        }

        /// Constructs a new `Arc` while giving you a `Aweak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        /// `data_fn` has the signature `fn(*Weak, ...data_args) T`
        pub fn initCyclic(alloc: Allocator, comptime data_fn: anytype, data_args: anytype) Allocator.Error!Self {
            const inner = try Unmanaged.create(alloc);
            Unmanaged.ptrToStrong(inner).* = 0;
            Unmanaged.ptrToWeak(inner).* = 1;

            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak_ptr = Weak{ .inner = Unmanaged.Weak.fromValuePtr(inner), .alloc = alloc };

            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.* = @call(.auto, data_fn, .{&weak_ptr} ++ data_args);

            std.debug.assert(@atomicRmw(usize, Unmanaged.ptrToStrong(inner), .Add, 1, .release) == 0);
            return Self{ .value = inner, .alloc = alloc };
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

        /// Decrements the reference count, deallocating if the weak count reaches zero,
        /// and returning the underlying value if the strong count reaches zero.
        /// The continued use of the pointer after calling this method is undefined behaviour.
        pub fn releaseUnwrap(self: Self) ?T {
            return self.asUnmanaged().releaseUnwrap(self.alloc);
        }

        /// Returns the inner value, if the `Arc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self) ?T {
            return self.asUnmanaged().tryUnwrap(self.alloc);
        }

        inline fn asUnmanaged(self: Self) Unmanaged {
            return .{ .value = self.value };
        }

        /// A multi-threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: UnmanagedWeak = .{},
            alloc: Allocator,

            const UnmanagedWeak = Unmanaged.Weak;

            /// Creates a new weak reference.
            pub fn init(parent: ArcAligned(T, alignment)) Weak {
                return Weak{
                    .inner = UnmanagedWeak.init(parent.asUnmanaged()),
                    .alloc = parent.alloc,
                };
            }

            /// Creates a new weak reference object from a pointer to it's underlying value,
            /// without increasing the weak count.
            pub fn fromValuePtr(value: *align(internal_alignment) T, alloc: Allocator) Weak {
                return .{ .inner = UnmanagedWeak.fromValuePtr(value), .alloc = alloc };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: Weak) usize {
                return self.inner.strongCount();
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: Weak) usize {
                return self.inner.weakCount();
            }

            /// Increments the weak count.
            pub fn retain(self: Weak) Weak {
                _ = self.inner.retain();
                return self;
            }

            /// Attempts to upgrade the weak pointer to an `Arc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak) ?ArcAligned(T, alignment) {
                if (self.inner.upgrade(self.alloc)) |strong_ref| {
                    return ArcAligned(T, alignment){ .value = strong_ref.value, .alloc = self.alloc };
                }
                return null;
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak) void {
                return self.inner.release(self.alloc);
            }
        };
    };
}

/// A single threaded, strong reference to a reference-counted value.
pub fn RcUnmanaged(comptime T: type) type {
    return RcAlignedUnmanaged(T, @alignOf(T));
}

/// A single threaded, strong reference to a reference-counted value.
pub fn RcAlignedUnmanaged(comptime T: type, comptime alignment: u29) type {
    return struct {
        value: *align(internal_alignment) T,

        const Self = @This();
        /// The true alignment of the value stored on the heap. This value will never be lower than the provided 'alignment'.
        pub const internal_alignment = @max(alignment, @alignOf(usize));
        /// Offset from the value to the reference counters.
        const counter_offset = std.mem.alignForward(usize, @sizeOf(T), @alignOf(usize));
        /// Since we'll never put this value into an array, there is no need to add alignment padding at the end.
        pub const total_size = counter_offset + 2 * @sizeOf(usize);

        /// Creates a new reference-counted value.
        pub fn init(alloc: Allocator, t: T) Allocator.Error!Self {
            const inner = try create(alloc);
            inner.* = t;
            ptrToStrong(inner).* = 1;
            ptrToWeak(inner).* = 1;
            return Self{ .value = inner };
        }

        /// Constructs a new `Rc` while giving you a `Weak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        /// `data_fn` has the signature `fn(*Weak, ...data_args) T`
        pub fn initCyclic(alloc: Allocator, comptime data_fn: anytype, data_args: anytype) Allocator.Error!Self {
            const inner = try create(alloc);
            ptrToStrong(inner).* = 0;
            ptrToWeak(inner).* = 1;
            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak_ptr = Weak.fromValuePtr(inner);
            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.value = @call(.auto, data_fn, .{&weak_ptr} ++ data_args);
            std.debug.assert(ptrToStrong(inner).* == 0);
            ptrToStrong(inner).* = 1;
            return Self{ .value = &inner.value, .alloc = alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: Self) usize {
            return self.strong().*;
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: Self) usize {
            return self.weak().* - 1;
        }

        /// Increments the strong count.
        pub fn retain(self: Self) Self {
            self.strong().* += 1;
            return self;
        }

        /// Creates a new weak reference to the pointed value
        pub fn downgrade(self: Self) Weak {
            return Weak.init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn release(self: Self, allocator: Allocator) void {
            self.strong().* -= 1;
            if (self.strong().* == 0) {
                self.weak().* -= 1;
                if (self.weak().* == 0) {
                    destroy(allocator, self.value);
                }
            }
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero,
        /// and returning the underlying value if the strong count reaches zero.
        /// The continued use of the pointer after calling this method is undefined behaviour.
        pub fn releaseUnwrap(self: Self, allocator: Allocator) ?T {
            self.strong().* -= 1;
            if (self.strong().* == 0) {
                const value = self.value.*;
                self.weak().* -= 1;
                if (self.weak().* == 0) {
                    destroy(allocator, self.value);
                }
                return value;
            }
            return null;
        }

        /// Returns the inner value, if the `Rc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self, allocator: Allocator) ?T {
            if (self.strong().* == 1) {
                self.strong().* = 0;
                const tmp = self.value.*;
                self.weak().* -= 1;
                if (self.weak().* == 0) {
                    destroy(allocator, self.value);
                }
                return tmp;
            }
            return null;
        }

        inline fn strong(self: Self) *usize {
            return ptrToStrong(self.value);
        }

        inline fn weak(self: Self) *usize {
            return ptrToWeak(self.value);
        }

        inline fn create(allocator: Allocator) std.mem.Allocator.Error!*align(internal_alignment) T {
            const bytes: []align(internal_alignment) u8 = try allocator.alignedAlloc(u8, internal_alignment, total_size);
            return @ptrCast(bytes.ptr);
        }

        inline fn destroy(allocator: Allocator, ptr: *align(internal_alignment) T) void {
            const bytes: []align(internal_alignment) u8 = @as([*]align(internal_alignment) u8, @ptrCast(ptr))[0..total_size];
            allocator.free(bytes);
        }

        inline fn ptrToStrong(ptr: *align(internal_alignment) T) *usize {
            return @ptrCast(@alignCast(&@as([*]align(internal_alignment) u8, @ptrCast(ptr))[counter_offset]));
        }

        inline fn ptrToWeak(ptr: *align(internal_alignment) T) *usize {
            return @ptrCast(@alignCast(&@as([*]align(internal_alignment) u8, @ptrCast(ptr))[counter_offset + @sizeOf(usize)]));
        }

        /// A single threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: ?*align(internal_alignment) anyopaque = null,

            /// Creates a new weak reference.
            pub fn init(parent: RcAlignedUnmanaged(T, alignment)) Weak {
                parent.weak().* += 1;
                return Weak{ .inner = @ptrCast(parent.value) };
            }

            /// Creates a new weak reference object from a pointer to it's underlying value,
            /// without increasing the weak count.
            pub fn fromValuePtr(value_ptr: *align(internal_alignment) T) Weak {
                return .{ .inner = value_ptr };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: Weak) usize {
                return (self.strong() orelse return 0).*;
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: Weak) usize {
                const ptr = self.value() orelse return 1;
                if (ptrToStrong(ptr).* == 0) {
                    return ptrToWeak(ptr).*;
                } else {
                    return ptrToWeak(ptr).* - 1;
                }
            }

            /// Increments the weak count.
            pub fn retain(self: Weak) Weak {
                if (self.weak()) |ptr| {
                    ptr.* += 1;
                }
                return self;
            }

            /// Attempts to upgrade the weak pointer to an `Rc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak, allocator: Allocator) ?RcAlignedUnmanaged(T, alignment) {
                const ptr = self.value() orelse return null;

                if (ptrToStrong(ptr).* == 0) {
                    ptrToWeak(ptr).* -= 1;
                    if (ptrToWeak(ptr).* == 0) {
                        destroy(allocator, ptr);
                        self.inner = null;
                    }
                    return null;
                }

                ptrToStrong(ptr).* += 1;
                return RcAlignedUnmanaged(T, alignment){
                    .value = ptr,
                };
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak, allocator: Allocator) void {
                if (self.value()) |ptr| {
                    ptrToWeak(ptr).* -= 1;
                    if (ptrToWeak(ptr).* == 0) {
                        destroy(allocator, ptr);
                    }
                }
            }

            inline fn value(self: Weak) ?*align(internal_alignment) T {
                return @ptrCast(self.inner);
            }

            inline fn strong(self: Weak) ?*usize {
                return ptrToStrong(@ptrCast(self.inner orelse return null));
            }

            inline fn weak(self: Weak) ?*usize {
                return ptrToWeak(@ptrCast(self.inner orelse return null));
            }
        };
    };
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn ArcUnmanaged(comptime T: type) type {
    return ArcAlignedUnmanaged(T, @alignOf(T));
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn ArcAlignedUnmanaged(comptime T: type, comptime alignment: u29) type {
    if (builtin.single_threaded) return RcAlignedUnmanaged(T, alignment);
    return struct {
        value: *align(internal_alignment) T,

        const Self = @This();
        /// The true alignment of the value stored on the heap. This value will never be lower than the provided 'alignment'.
        pub const internal_alignment = @max(alignment, @max(@alignOf(usize), std.atomic.cache_line));
        /// Offset from the value to the reference counters.
        const counter_offset = std.mem.alignForward(usize, @sizeOf(T), @max(@alignOf(usize), std.atomic.cache_line));
        /// Since we'll never put this value into an array, there is no need to add alignment padding at the end,
        /// but we **do** add some padding to ensure that no nearby allocations have their caches invalidated by our counters.
        /// If the alignment of 'T' is higher than 'std.atomic.cache_line', the manually added padding will be smaller than the one
        /// added by a regular Zig struct.
        pub const total_size = std.mem.alignForward(usize, counter_offset + 2 * @sizeOf(usize), std.atomic.cache_line);

        /// Creates a new reference-counted value.
        pub fn init(alloc: Allocator, t: T) Allocator.Error!Self {
            const inner = try create(alloc);
            inner.* = t;
            ptrToStrong(inner).* = 1;
            ptrToWeak(inner).* = 1;
            return Self{ .value = inner };
        }

        /// Constructs a new `Arc` while giving you a `Aweak` to the allocation,
        /// to allow you to construct a `T` which holds a weak pointer to itself.
        /// `data_fn` has the signature `fn(*Weak, ...data_args) T`
        pub fn initCyclic(alloc: Allocator, comptime data_fn: anytype, data_args: anytype) Allocator.Error!Self {
            const inner = try create(alloc);
            ptrToStrong(inner).* = 0;
            ptrToWeak(inner).* = 1;

            // Strong references should collectively own a shared weak reference,
            // so don't run the destructor for our old weak reference.
            var weak_ptr = Weak.fromValuePtr(inner);

            // It's important we don't give up ownership of the weak pointer, or
            // else the memory might be freed by the time `data_fn` returns. If
            // we really wanted to pass ownership, we could create an additional
            // weak pointer for ourselves, but this would result in additional
            // updates to the weak reference count which might not be necessary
            // otherwise.
            inner.value = @call(.auto, data_fn, .{&weak_ptr} ++ data_args);

            std.debug.assert(@atomicRmw(usize, ptrToStrong(inner), .Add, 1, .release) == 0);
            return Self{ .value = inner };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: Self) usize {
            return @atomicLoad(usize, self.strong(), .acquire);
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: Self) usize {
            return @atomicLoad(usize, self.weak(), .acquire) - 1;
        }

        /// Increments the strong count.
        pub fn retain(self: Self) Self {
            _ = @atomicRmw(usize, self.strong(), .Add, 1, .acq_rel);
            return self;
        }

        /// Creates a new weak reference to the pointed value.
        pub fn downgrade(self: Self) Weak {
            return Weak.init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        /// The continued use of the pointer after calling `release` is undefined behaviour.
        pub fn release(self: Self, allocator: Allocator) void {
            if (@atomicRmw(usize, self.strong(), .Sub, 1, .acq_rel) == 1) {
                if (@atomicRmw(usize, self.weak(), .Sub, 1, .acq_rel) == 1) {
                    destroy(allocator, self.value);
                }
            }
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero,
        /// and returning the underlying value if the strong count reaches zero.
        /// The continued use of the pointer after calling this method is undefined behaviour.
        pub fn releaseUnwrap(self: Self, allocator: Allocator) ?T {
            if (@atomicRmw(usize, self.strong(), .Sub, 1, .acq_rel) == 1) {
                const value = self.value.*;
                if (@atomicRmw(usize, self.weak(), .Sub, 1, .acq_rel) == 1) {
                    destroy(allocator, self.value);
                }
                return value;
            }
            return null;
        }

        /// Returns the inner value, if the `Arc` has exactly one strong reference.
        /// Otherwise, `null` is returned.
        /// This will succeed even if there are outstanding weak references.
        /// The continued use of the pointer if the method successfully returns `T` is undefined behaviour.
        pub fn tryUnwrap(self: Self, allocator: Allocator) ?T {
            if (@cmpxchgStrong(usize, self.strong(), 1, 0, .monotonic, .monotonic) == null) {
                const tmp = self.value.*;
                if (@atomicRmw(usize, self.weak(), .Sub, 1, .acq_rel) == 1) {
                    destroy(allocator, self.value);
                }
                return tmp;
            }
            return null;
        }

        inline fn strong(self: Self) *align(std.atomic.cache_line) usize {
            return ptrToStrong(self.value);
        }

        inline fn weak(self: Self) *usize {
            return ptrToWeak(self.value);
        }

        /// A multi-threaded, weak reference to a reference-counted value.
        pub const Weak = struct {
            inner: ?*align(internal_alignment) anyopaque = null,

            /// Creates a new weak reference.
            pub fn init(parent: ArcAlignedUnmanaged(T, alignment)) Weak {
                _ = @atomicRmw(usize, parent.weak(), .Add, 1, .acq_rel);
                return Weak{ .inner = @ptrCast(parent.value) };
            }

            /// Creates a new weak reference object from a pointer to it's underlying value,
            /// without increasing the weak count.
            pub fn fromValuePtr(value_ptr: *align(internal_alignment) T) Weak {
                return .{ .inner = @ptrCast(value_ptr) };
            }

            /// Gets the number of strong references to this value.
            pub fn strongCount(self: Weak) usize {
                const ptr = self.strong() orelse return 0;
                return @atomicLoad(usize, ptr, .acquire);
            }

            /// Gets the number of weak references to this value.
            pub fn weakCount(self: Weak) usize {
                const ptr = self.value() orelse return 1;
                const weak_value = @atomicLoad(usize, ptrToWeak(ptr), .acquire);
                if (@atomicLoad(usize, ptrToStrong(ptr), .acquire) == 0) {
                    return weak_value;
                } else {
                    return weak_value - 1;
                }
            }

            /// Increments the weak count.
            pub fn retain(self: Weak) Weak {
                if (self.weak()) |ptr| {
                    _ = @atomicRmw(usize, ptr, .Add, 1, .acq_rel);
                }
                return self;
            }

            /// Attempts to upgrade the weak pointer to an `Arc`, delaying dropping of the inner value if successful.
            ///
            /// Returns `null` if the inner value has since been dropped.
            pub fn upgrade(self: *Weak, allocator: Allocator) ?ArcAlignedUnmanaged(T, alignment) {
                const ptr = self.value() orelse return null;

                while (true) {
                    const prev = @atomicLoad(usize, ptrToStrong(ptr), .acquire);
                    if (prev == 0) {
                        if (@atomicRmw(usize, ptrToWeak(ptr), .Sub, 1, .acq_rel) == 1) {
                            destroy(allocator, ptr);
                            self.inner = null;
                        }
                        return null;
                    }

                    if (@cmpxchgStrong(usize, ptrToStrong(ptr), prev, prev + 1, .acquire, .monotonic) == null) {
                        return ArcAlignedUnmanaged(T, alignment){ .value = ptr };
                    }

                    std.atomic.spinLoopHint();
                }
            }

            /// Decrements the weak reference count, deallocating if it reaches zero.
            /// The continued use of the pointer after calling `release` is undefined behaviour.
            pub fn release(self: Weak, allocator: Allocator) void {
                if (self.value()) |ptr| {
                    if (@atomicRmw(usize, ptrToWeak(ptr), .Sub, 1, .acq_rel) == 1) {
                        destroy(allocator, ptr);
                    }
                }
            }

            inline fn value(self: Weak) ?*align(internal_alignment) T {
                if (self.inner) |inner| return @ptrCast(inner);
                return null;
            }

            inline fn strong(self: Weak) ?*align(std.atomic.cache_line) usize {
                if (self.inner) |inner| return ptrToStrong(@ptrCast(inner));
                return null;
            }

            inline fn weak(self: Weak) ?*usize {
                if (self.inner) |inner| return ptrToWeak(@ptrCast(inner));
                return null;
            }
        };

        inline fn create(allocator: Allocator) std.mem.Allocator.Error!*align(internal_alignment) T {
            const bytes: []align(internal_alignment) u8 = try allocator.alignedAlloc(u8, internal_alignment, total_size);
            return @ptrCast(bytes.ptr);
        }

        inline fn destroy(allocator: Allocator, ptr: *align(internal_alignment) T) void {
            const bytes: []align(internal_alignment) u8 = @as([*]align(internal_alignment) u8, @ptrCast(ptr))[0..total_size];
            allocator.free(bytes);
        }

        inline fn ptrToStrong(ptr: *align(internal_alignment) T) *align(std.atomic.cache_line) usize {
            return @ptrCast(@alignCast(&@as([*]align(internal_alignment) u8, @ptrCast(ptr))[counter_offset]));
        }

        inline fn ptrToWeak(ptr: *align(internal_alignment) T) *usize {
            return @ptrCast(@alignCast(&@as([*]align(internal_alignment) u8, @ptrCast(ptr))[counter_offset + @sizeOf(usize)]));
        }
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
