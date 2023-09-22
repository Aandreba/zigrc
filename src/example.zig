const std = @import("std");
const rc = @import("main.zig");

const Thread = std.Thread;
const Mutex = Thread.Mutex;

const ArrayList = std.ArrayList;
const Arc = rc.Arc(Data);

const THREADS = 8;

const Data = struct {
    mutex: Mutex = Mutex{},
    data: ArrayList(u64) = ArrayList(u64).init(std.testing.allocator),

    pub fn deinit(self: Data) void {
        self.data.deinit();
    }
};

test "example" {
    std.debug.print("\n", .{});
    std.debug.print("Data size: {}\n", .{@sizeOf(Data)});
    std.debug.print("Heap size: {}\n\n", .{Arc.innerSize()});

    std.debug.print("Data align: {}\n", .{@alignOf(Data)});
    std.debug.print("Heap align: {}\n\n", .{Arc.innerAlign()});

    var value = try Arc.init(std.testing.allocator, .{});
    errdefer value.releaseWithFn(Data.deinit);

    var handles: [THREADS]Thread = undefined;
    var i: usize = 0;
    while (i < THREADS) {
        const this_value = value.retain();
        errdefer this_value.releaseWithFn(Data.deinit);
        handles[i] = try Thread.spawn(.{}, thread_exec, .{this_value});
        i += 1;
    }

    for (handles) |handle| {
        handle.join();
    }

    const owned_value: Data = value.tryUnwrap().?;
    defer owned_value.deinit();

    std.debug.print("{d}\n", .{owned_value.data.items});
}

fn thread_exec(data: Arc) !void {
    defer data.releaseWithFn(Data.deinit);

    var rng = std.rand.DefaultPrng.init(@as(u64, @bitCast(@as(i64, @truncate(std.time.nanoTimestamp())))));

    data.value.mutex.lock();
    defer data.value.mutex.unlock();

    const value = rng.random().int(u64);
    try data.value.data.append(value);

    std.debug.print("{}: {}\n", .{ std.time.nanoTimestamp(), value });
}
