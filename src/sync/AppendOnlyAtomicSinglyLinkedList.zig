const std = @import("std");

const Self = @This();

pub const Node = struct {
    next: ?*Node = null,

    // if `null` is returned, the next node has been succesfully set,
    // otherwise, the actual `next` node is returned
    inline fn trySetNext(self: *Node, next: *Node) ??*Node {
        return @cmpxchgWeak(?*Node, &self.next, null, next, .acq_rel, .acquire);
    }
};

first: ?*Node = null,

pub fn getLastFrom(self: *Self, maybe_last_known: ?*Node) ?*Node {
    const last_known = maybe_last_known orelse {
        const maybe_first = @atomicLoad(?*Node, &self.first, .acquire);
        if (maybe_first) |first| {
            return self.getLastFrom(first);
        }

        return null;
    };

    const maybe_next = @atomicLoad(?*Node, &last_known.next, .acquire);
    if (maybe_next) |next| {
        return self.getLastFrom(next);
    }

    return last_known;
}

inline fn trySetFirst(self: *Self, first: *Node) ??*Node {
    return @cmpxchgWeak(?*Node, &self.first, null, first, .acq_rel, .acquire);
}

pub fn append(self: *Self, node: *Node) void {
    var maybe_last_known: ?*Node = null;
    while (true) {
        maybe_last_known = self.getLastFrom(maybe_last_known);

        const last_known = maybe_last_known orelse {
            const maybe_new_first = self.trySetFirst(node);
            if (maybe_new_first) |new_first| {
                maybe_last_known = new_first;
                continue;
            }

            return;
        };

        const maybe_next = last_known.trySetNext(node);
        if (maybe_next) |next| {
            maybe_last_known = next;
            continue;
        }

        break;
    }
}

pub const Iterator = struct {
    curr: ?*Node,

    pub fn next(self: *Iterator) ?*Node {
        const curr = self.curr orelse {
            return null;
        };

        const maybe_next = @atomicLoad(?*Node, &curr.next, .acquire);
        self.curr = maybe_next;

        return curr;
    }
};

pub fn iterateFrom(self: *const Self, from: ?*Node) Iterator {
    _ = self;

    return .{
        .curr = from,
    };
}

pub fn iterate(self: *const Self) Iterator {
    return self.iterateFrom(@atomicLoad(?*Node, &self.first, .acquire));
}

test Self {
    const TestNode = struct {
        list_node: Self.Node = .{},
        value: usize,
    };

    var list: Self = .{};

    const getValues = struct {
        fn aufruf(list_: *Self) ![]usize {
            var arraylist: std.ArrayListUnmanaged(usize) = .{};

            var iterator = list_.iterate();
            while (iterator.next()) |list_node| {
                const node: *TestNode = @fieldParentPtr("list_node", list_node);
                try arraylist.append(std.testing.allocator, node.value);
            }

            return try arraylist.toOwnedSlice(std.testing.allocator);
        }
    }.aufruf;

    const values_0 = try getValues(&list);
    defer std.testing.allocator.free(values_0);
    try std.testing.expectEqualSlices(usize, &.{}, values_0);

    var nodes = [_]TestNode{
        .{ .value = 1 },
        .{ .value = 1 },
        .{ .value = 2 },
        .{ .value = 3 },
        .{ .value = 5 },
    };

    list.append(&nodes[0].list_node);

    const values_1 = try getValues(&list);
    defer std.testing.allocator.free(values_1);
    try std.testing.expectEqualSlices(usize, &.{1}, values_1);

    list.append(&nodes[1].list_node);
    list.append(&nodes[2].list_node);
    list.append(&nodes[3].list_node);
    list.append(&nodes[4].list_node);

    const values_2 = try getValues(&list);
    defer std.testing.allocator.free(values_2);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 2, 3, 5 }, values_2);
}
