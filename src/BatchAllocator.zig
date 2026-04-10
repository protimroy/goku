//! The BatchAllocator provides a simple interface to
//! process batches of workloads that require an allocator,
//! when you don't want to relinquish all of the allocated
//! memory between batches.

const heap = std.heap;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

const BatchAllocator = @This();

const State = union(enum) {
    init: struct {
        arena: heap.ArenaAllocator,
    },
    live: struct {
        arena: heap.ArenaAllocator,
        curr: heap.ArenaAllocator,
    },
    closed: void,
};

state: State,

pub fn init(ally: mem.Allocator) BatchAllocator {
    return .{
        .state = .{
            .init = .{
                .arena = .init(ally),
            },
        },
    };
}

/// Free all allocated memory.
pub fn deinit(self: *BatchAllocator) void {
    switch (self.state) {
        .init => {
            self.state.init.arena.deinit();
            self.state = .closed;
        },
        .live => {
            self.state.live.arena.deinit();
            self.state = .closed;
        },
        .closed => {
            @panic("Attempted double deinit of BatchAllocator.");
        },
    }
}

/// Mark all of the allocated memory for this batch
/// as usable, without freeing it.
pub fn flush(self: *BatchAllocator) void {
    switch (self.state) {
        .init => {},
        .live => |live| {
            var next = live;
            next.curr.deinit();
            self.state = .{
                .init = .{
                    .arena = next.arena,
                },
            };
        },
        .closed => {
            @panic("Attempted flush of BatchAllocator after deinit.");
        },
    }
}

/// Retrieve the arena allocator for the current batch.
pub fn allocator(self: *BatchAllocator) mem.Allocator {
    switch (self.state) {
        .init => |init_state| {
            self.state = .{
                .live = .{
                    .arena = init_state.arena,
                    .curr = undefined,
                },
            };
            self.state.live.curr = .init(self.state.live.arena.allocator());
        },
        .live => {},
        .closed => {
            @panic("Attempted allocator retrieval after deinit.");
        },
    }

    return self.state.live.curr.allocator();
}

test BatchAllocator {
    var batch_allocator = init(testing.allocator);

    const workload_size = 10;

    for (0..workload_size) |i| {
        var buf = std.array_list.Managed(u8).init(batch_allocator.allocator());
        defer buf.deinit();

        var item_buf: [32]u8 = undefined;
        const item = try std.fmt.bufPrint(&item_buf, "Work item {d}", .{i});
        try buf.appendSlice(item);

        batch_allocator.flush();

        try testing.expectEqual(
            .init,
            @as(@typeInfo(State).@"union".tag_type.?, batch_allocator.state),
        );
    }

    batch_allocator.deinit();

    try testing.expectEqual(
        .closed,
        @as(@typeInfo(State).@"union".tag_type.?, batch_allocator.state),
    );
}
