const std = @import("std");

const kompot = @import("kompot");

const Self = @This();

const HyperGraph = kompot.HyperGraph;

pub fn init(alloc: std.mem.Allocator, graph: *HyperGraph) !Self {
    var complete_edges = try std.DynamicBitSetUnmanaged.initEmpty(alloc, graph.all_edges.items.len);
    errdefer complete_edges.deinit(alloc);

    var dead_edges = try std.DynamicBitSetUnmanaged.initEmpty(alloc, graph.all_edges.items.len);
    errdefer dead_edges.deinit(alloc);

    var available_vertices = try std.DynamicBitSetUnmanaged.initEmpty(alloc, graph.all_vertices.items.len);
    errdefer available_vertices.deinit(alloc);

    var computed_vertices = try std.DynamicBitSetUnmanaged.initEmpty(alloc, graph.all_vertices.items.len);
    errdefer computed_vertices.deinit(alloc);

    var self: Self = .{
        .alloc = alloc,

        .graph = graph,

        .complete_edges = complete_edges,
        .dead_edges = dead_edges,

        .available_vertices = available_vertices,
        .computed_vertices = computed_vertices,
    };

    self.reset();

    return self;
}

pub fn reset(self: *Self) void {
    self.complete_edges.unsetAll();
    self.dead_edges.unsetAll();
    self.available_vertices.unsetAll();
    self.computed_vertices.unsetAll();

    std.debug.assert(self.edges_ready_to_go.items.len == 0);

    var iter = self.graph.iterateEdges();
    while (iter.next()) |edge_handle| {
        const edge = self.graph.getEdge(edge_handle);

        const is_dead = for (edge.to) |to_vertex_handle| {
            const to_vertex = self.graph.getVertex(to_vertex_handle);
            if (to_vertex.observable) break false;
        } else true; // side effect: if `edge.to` is empty, `is_dead` is true

        if (is_dead) {
            self.graph.setEdgeBit(edge_handle, &self.dead_edges, true);
        }

        const is_free = edge.from.len == 0;

        if (is_free) self.edges_ready_to_go.append(self.alloc, edge_handle) catch @panic("OOM");
    }
}

pub fn deinit(self: *Self) void {
    self.edges_ready_to_go.deinit(self.alloc);

    self.complete_edges.deinit(self.alloc);
    self.dead_edges.deinit(self.alloc);

    self.available_vertices.deinit(self.alloc);
    self.computed_vertices.deinit(self.alloc);
}

pub fn markComplete(self: *Self, edge_handle: HyperGraph.EdgeHandle) void {
    std.debug.assert(!self.graph.getEdgeBit(edge_handle, &self.complete_edges));
    self.graph.setEdgeBit(edge_handle, &self.complete_edges, true);

    const edge = self.graph.getEdge(edge_handle);

    // mark every vertex this edge results in as satisfied.
    for (edge.to) |requirement| {
        self.markComputed(requirement);
    }
}

// if you are marking a vertex as computed because of the result of a
// edge, use `markComplete` instead.
//
// this function is meant for explicitly marking a vertex as computed. one
// such example is when a vertex is an input vertex.
pub fn markComputed(self: *Self, vertex_handle: HyperGraph.VertexHandle) void {
    std.debug.assert(!self.graph.getVertexBit(vertex_handle, &self.computed_vertices));
    self.graph.setVertexBit(vertex_handle, &self.computed_vertices, true);

    self.markAvailable(vertex_handle);

    // if this vertex is the result of a edge and if all of the
    // results of said edge have been computed with this vertex
    // being computed, said edge is considered complete.
    //
    // if this is the case, all of the vertices in the `from` field of the
    // edge are also considered computed.

    const vertex = self.graph.getVertex(vertex_handle);

    const related_edge_handle = vertex.produced_by orelse return;
    if (self.graph.getEdgeBit(related_edge_handle, &self.complete_edges)) {
        return;
    }

    const related_edge = self.graph.getEdge(related_edge_handle);

    const edge_complete = for (related_edge.to) |neighbour| {
        if (self.graph.getVertexBit(neighbour, &self.computed_vertices)) {
            continue;
        }

        break false;
    } else true;

    if (edge_complete) {
        self.markComplete(related_edge_handle);
    }
}

pub fn markAvailable(
    self: *Self,
    vertex_handle: HyperGraph.VertexHandle,
) void {
    if (self.graph.getVertexBit(vertex_handle, &self.available_vertices)) {
        return;
    }

    self.graph.setVertexBit(vertex_handle, &self.available_vertices, true);

    const vertex = self.graph.getVertex(vertex_handle);

    // if this vertex was the last vertex required for a edge, it is
    // now ready. it doesn't matter if that edge was already
    // complete -- when checking for the next ready edge, we will
    // check if it has already been completed.

    for (vertex.needed_by.items) |potentially_unblocked_handle| {
        const potentially_unblocked = self.graph.getEdge(potentially_unblocked_handle);

        const is_unblocked = for (potentially_unblocked.from) |neighbour| {
            if (self.graph.getVertexBit(neighbour, &self.available_vertices)) {
                continue;
            }

            break false;
        } else true;

        if (!is_unblocked) continue;

        self.edges_ready_to_go.append(self.alloc, potentially_unblocked_handle) catch @panic("OOM");
    }
}

pub fn next(self: *Self) ?HyperGraph.EdgeHandle {
    while (true) {
        const candidate = self.edges_ready_to_go.pop() orelse return null;
        if (self.graph.getEdgeBit(candidate, &self.complete_edges)) continue;
        if (self.graph.getEdgeBit(candidate, &self.dead_edges)) continue;

        return candidate;
    }
}

alloc: std.mem.Allocator,

graph: *HyperGraph,

edges_ready_to_go: std.ArrayList(HyperGraph.EdgeHandle) = .empty,

complete_edges: std.DynamicBitSetUnmanaged,
dead_edges: std.DynamicBitSetUnmanaged,

available_vertices: std.DynamicBitSetUnmanaged,
computed_vertices: std.DynamicBitSetUnmanaged,

test "cycle" {
    const alloc = std.testing.allocator;

    const VertexParent = struct {
        vertex: HyperGraph.Vertex = undefined,
    };

    const EdgeParent = struct {
        edge: HyperGraph.Edge = undefined,
    };

    var g: HyperGraph = .init(alloc);
    defer g.deinit();

    const v_0 = try g.addVertexQuick(false, VertexParent, .{});
    const v_1 = try g.addVertexQuick(false, VertexParent, .{});
    const v_2 = try g.addVertexQuick(true, VertexParent, .{});

    const c_0 = try g.addEdgeQuick(&.{v_0}, &.{v_1}, EdgeParent, .{});
    const c_1 = try g.addEdgeQuick(&.{v_1}, &.{v_2}, EdgeParent, .{});
    const c_2 = try g.addEdgeQuick(&.{v_2}, &.{v_0}, EdgeParent, .{});

    try g.finish();

    {
        var s = try Self.init(alloc, &g);
        defer s.deinit();

        s.markAvailable(v_2);

        var got_edges: std.ArrayList(HyperGraph.EdgeHandle) = .empty;
        defer got_edges.deinit(alloc);

        while (s.next()) |c| {
            try got_edges.append(alloc, c);
            s.markComplete(c);
        }

        try std.testing.expectEqualSlices(HyperGraph.EdgeHandle, &.{ c_2, c_0, c_1 }, got_edges.items);
    }
}

test "without satisfied vertices" {
    const alloc = std.testing.allocator;

    const VertexParent = struct {
        vertex: HyperGraph.Vertex = undefined,
    };

    const EdgeParent = struct {
        edge: HyperGraph.Edge = undefined,
    };

    var g: HyperGraph = .init(alloc);
    defer g.deinit();

    const v_0 = try g.addVertexQuick(false, VertexParent, .{});
    const v_1 = try g.addVertexQuick(true, VertexParent, .{});

    const c_0 = try g.addEdgeQuick(&.{}, &.{v_0}, EdgeParent, .{});
    const c_1 = try g.addEdgeQuick(&.{v_0}, &.{v_1}, EdgeParent, .{});

    try g.finish();

    {
        var s = try Self.init(alloc, &g);
        defer s.deinit();

        var got_edges: std.ArrayList(HyperGraph.EdgeHandle) = .empty;
        defer got_edges.deinit(alloc);

        while (s.next()) |c| {
            try got_edges.append(alloc, c);
            s.markComplete(c);
        }

        try std.testing.expectEqualSlices(HyperGraph.EdgeHandle, &.{ c_0, c_1 }, got_edges.items);
    }
}

test "a basic graph" {
    const alloc = std.testing.allocator;

    const VertexParent = struct {
        vertex: HyperGraph.Vertex = undefined,
    };

    const EdgeParent = struct {
        edge: HyperGraph.Edge = undefined,
    };

    var g: HyperGraph = .init(alloc);
    defer g.deinit();

    const v_0 = try g.addVertexQuick(false, VertexParent, .{});
    const v_1 = try g.addVertexQuick(false, VertexParent, .{});
    const v_2 = try g.addVertexQuick(false, VertexParent, .{});
    const v_3 = try g.addVertexQuick(false, VertexParent, .{});
    const v_4 = try g.addVertexQuick(true, VertexParent, .{});

    const c_0 = try g.addEdgeQuick(&.{v_0}, &.{v_1}, EdgeParent, .{});
    const c_1 = try g.addEdgeQuick(&.{v_1}, &.{v_2}, EdgeParent, .{});
    const c_2 = try g.addEdgeQuick(&.{v_2}, &.{v_3}, EdgeParent, .{});
    const c_3 = try g.addEdgeQuick(&.{v_3}, &.{v_4}, EdgeParent, .{});

    try g.finish();

    var s = try Self.init(alloc, &g);
    defer s.deinit();

    s.markAvailable(v_0);

    var got_edges: std.ArrayList(HyperGraph.EdgeHandle) = .empty;
    defer got_edges.deinit(alloc);

    while (s.next()) |c| {
        try got_edges.append(alloc, c);
        s.markComplete(c);
    }

    try std.testing.expectEqualSlices(HyperGraph.EdgeHandle, &.{ c_0, c_1, c_2, c_3 }, got_edges.items);
}

test "an involved graph" {
    // drew this in gimp

    const alloc = std.testing.allocator;

    const VertexParent = struct {
        vertex: HyperGraph.Vertex = undefined,
    };

    const EdgeParent = struct {
        edge: HyperGraph.Edge = undefined,
    };

    var g: HyperGraph = .init(alloc);
    defer g.deinit();

    const v_a = try g.addVertexQuick(false, VertexParent, .{});
    const v_b = try g.addVertexQuick(false, VertexParent, .{});
    const v_c = try g.addVertexQuick(false, VertexParent, .{});
    const v_d = try g.addVertexQuick(false, VertexParent, .{});
    const v_e = try g.addVertexQuick(false, VertexParent, .{});
    const v_f = try g.addVertexQuick(false, VertexParent, .{});
    const v_g = try g.addVertexQuick(false, VertexParent, .{});
    const v_h = try g.addVertexQuick(true, VertexParent, .{});
    const v_i = try g.addVertexQuick(false, VertexParent, .{});
    const v_j = try g.addVertexQuick(false, VertexParent, .{});
    const v_k = try g.addVertexQuick(false, VertexParent, .{});
    const v_l = try g.addVertexQuick(true, VertexParent, .{});
    const v_m = try g.addVertexQuick(false, VertexParent, .{});
    const v_n = try g.addVertexQuick(true, VertexParent, .{});
    const v_o = try g.addVertexQuick(false, VertexParent, .{});

    const c_0 = try g.addEdgeQuick(&.{v_a}, &.{v_b}, EdgeParent, .{});
    const c_1 = try g.addEdgeQuick(&.{ v_b, v_c }, &.{v_d}, EdgeParent, .{});
    const c_2 = try g.addEdgeQuick(&.{v_d}, &.{ v_e, v_f }, EdgeParent, .{});
    const c_3 = try g.addEdgeQuick(&.{ v_e, v_f, v_g }, &.{ v_h, v_i }, EdgeParent, .{});
    const c_4 = try g.addEdgeQuick(&.{ v_j, v_k }, &.{ v_g, v_l }, EdgeParent, .{});
    const c_5 = try g.addEdgeQuick(&.{v_m}, &.{v_n}, EdgeParent, .{});
    const c_6 = try g.addEdgeQuick(&.{ v_i, v_n }, &.{v_o}, EdgeParent, .{});
    _ = c_6;

    try g.finish();

    const asd = &.{ c_0, c_1, c_2, c_3, c_4, c_5 };
    _ = asd;

    {
        var s = try Self.init(alloc, &g);
        defer s.deinit();

        s.markAvailable(v_a);
        s.markAvailable(v_c);
        s.markAvailable(v_j);
        s.markAvailable(v_k);
        s.markAvailable(v_m);

        var got_edges: std.ArrayList(HyperGraph.EdgeHandle) = .empty;
        defer got_edges.deinit(alloc);

        while (s.next()) |c| {
            try got_edges.append(alloc, c);
            s.markComplete(c);
        }

        try std.testing.expectEqualSlices(
            HyperGraph.EdgeHandle,
            &.{ c_5, c_4, c_0, c_1, c_2, c_3 },
            got_edges.items,
        );
    }

    {
        var s = try Self.init(alloc, &g);
        defer s.deinit();

        s.markAvailable(v_d);
        s.markAvailable(v_j);
        s.markAvailable(v_k);
        s.markAvailable(v_m);

        var got_edges: std.ArrayList(HyperGraph.EdgeHandle) = .empty;
        defer got_edges.deinit(alloc);

        while (s.next()) |c| {
            try got_edges.append(alloc, c);
            s.markComplete(c);
        }

        try std.testing.expectEqualSlices(
            HyperGraph.EdgeHandle,
            &.{ c_5, c_4, c_2, c_3 },
            got_edges.items,
        );
    }
}

const arithmetic_stuff = struct {
    const Op = enum {
        add,
        sub,
        div,
        mul,
    };

    const VertexParent = struct {
        vertex: HyperGraph.Vertex = undefined,
        value: u64 = undefined,
    };

    const EdgeParent = struct {
        edge: HyperGraph.Edge = undefined,
        op: Op,
    };

    fn execute(g: *HyperGraph, s: *Self, eh: HyperGraph.EdgeHandle) void {
        const VP = arithmetic_stuff.VertexParent;
        const EP = arithmetic_stuff.EdgeParent;

        const e = g.getEdge(eh);
        const ep: *EP = @alignCast(@fieldParentPtr("edge", e));

        const lhs: *VP = @alignCast(@fieldParentPtr("vertex", g.getVertex(e.from[0])));
        const rhs: *VP = @alignCast(@fieldParentPtr("vertex", g.getVertex(e.from[1])));
        const out: *VP = @alignCast(@fieldParentPtr("vertex", g.getVertex(e.to[0])));

        out.value = switch (ep.op) {
            .add => lhs.value + rhs.value,
            .sub => lhs.value - rhs.value,
            .mul => lhs.value * rhs.value,
            .div => lhs.value / rhs.value,
        };

        s.markComplete(eh);
    }
};

test "basic arithmetic" {
    const alloc = std.testing.allocator;

    var g: HyperGraph = .init(alloc);
    defer g.deinit();

    // i googled math ragebait and picked the second pic
    // and by googled..
    // haha
    // let's just say, ddg.gg?ia=images
    //
    // expression: 6 / 2(1+2)
    //
    // i give precedence to ab over a/b and a*b, fuck you

    const VP = arithmetic_stuff.VertexParent;
    const EP = arithmetic_stuff.EdgeParent;

    const v_0 = try g.addVertexQuick(false, VP, .{ .value = 1 });
    const v_1 = try g.addVertexQuick(false, VP, .{ .value = 2 });
    const v_2 = try g.addVertexQuick(false, VP, .{});

    const c_0 = try g.addEdgeQuick(&.{ v_0, v_1 }, &.{v_2}, EP, .{ .op = .add });
    _ = c_0;

    const v_3 = try g.addVertexQuick(false, VP, .{ .value = 2 });
    const v_4 = try g.addVertexQuick(false, VP, .{});

    const c_1 = try g.addEdgeQuick(&.{ v_2, v_3 }, &.{v_4}, EP, .{ .op = .mul });
    _ = c_1;

    const v_5 = try g.addVertexQuick(false, VP, .{ .value = 6 });
    const v_6 = try g.addVertexQuick(true, VP, .{});

    const c_2 = try g.addEdgeQuick(&.{ v_5, v_4 }, &.{v_6}, EP, .{ .op = .div });
    _ = c_2;

    try g.finish();

    var s = try Self.init(alloc, &g);
    defer s.deinit();

    s.markAvailable(v_0);
    s.markAvailable(v_1);
    s.markAvailable(v_3);
    s.markAvailable(v_5);

    while (s.next()) |eh| {
        arithmetic_stuff.execute(&g, &s, eh);
    }

    const out: *VP = @alignCast(@fieldParentPtr("vertex", g.getVertex(v_6)));
    try std.testing.expectEqual(1, out.value);
}

test "fibonacci" {
    const alloc = std.testing.allocator;

    var g: HyperGraph = .init(alloc);
    defer g.deinit();

    const VP = arithmetic_stuff.VertexParent;
    const EP = arithmetic_stuff.EdgeParent;

    const v_0 = try g.addVertexQuick(true, VP, .{ .value = 0 });
    const v_1 = try g.addVertexQuick(true, VP, .{ .value = 1 });
    const v_2 = try g.addVertexQuick(false, VP, .{});
    const v_3 = try g.addVertexQuick(false, VP, .{});

    // constant
    const v_one = try g.addVertexQuick(false, VP, .{ .value = 1 });

    const c_0 = try g.addEdgeQuick(&.{ v_1, v_one }, &.{v_2}, EP, .{ .op = .mul });
    const c_1 = try g.addEdgeQuick(&.{ v_0, v_1 }, &.{v_3}, EP, .{ .op = .add });

    const c_2 = try g.addEdgeQuick(&.{ v_2, v_one, v_3 }, &.{v_0}, EP, .{ .op = .mul });
    const c_3 = try g.addEdgeQuick(&.{ v_3, v_one, v_2 }, &.{v_1}, EP, .{ .op = .mul });

    _ = .{ c_0, c_1, c_2, c_3 };

    try g.finish();

    var s = try Self.init(alloc, &g);
    defer s.deinit();

    for (0..5) |_| {
        s.reset();

        s.markAvailable(v_0);
        s.markAvailable(v_1);
        s.markAvailable(v_one);

        while (s.next()) |eh| {
            arithmetic_stuff.execute(&g, &s, eh);
        }
    }

    const out: *VP = @alignCast(@fieldParentPtr("vertex", g.getVertex(v_1)));
    try std.testing.expectEqual(8, out.value);
}
