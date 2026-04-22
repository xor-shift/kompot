const std = @import("std");

const Self = @This();

pub const Edge = struct {
    from: []const VertexHandle,
    to: []const VertexHandle,
};

pub const Vertex = struct {
    directly_observable: bool,
    observable: bool = false,

    // redundant field
    needed_by: std.ArrayList(EdgeHandle) = .empty,

    //redundant field
    handle: VertexHandle,

    produced_by: ?EdgeHandle = null,
};

/// wrapped for strong typing
pub const VertexHandle = struct {
    inner: usize,
};

/// wrapped for strong typing
pub const EdgeHandle = struct {
    inner: usize,
};

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        .alloc = alloc,
    };
}

pub fn deinit(self: *Self) void {
    for (self.all_vertices.items) |vertex| {
        vertex.needed_by.deinit(self.alloc);
    }

    for (self.all_edges.items) |edge| {
        self.alloc.free(edge.from);
        self.alloc.free(edge.to);
    }

    self.all_vertices.deinit(self.alloc);
    self.all_edges.deinit(self.alloc);
}

/// no lifetime issues. this works because `inline` is chill like that in Zig.
///
/// from the docs:
///
/// Adding the inline keyword to a function definition makes that function
/// become semantically inlined at the callsite. This is not a hint to be
/// possibly observed by optimization passes, but has implications on the
/// types and values involved in the function call.
pub inline fn addVertexQuick(
    self: *Self,
    observable: bool,
    comptime Parent: type,
    parent: Parent,
) !VertexHandle {
    var copy = parent;
    return try self.addVertex(observable, &copy.vertex);
}

/// see `addVertexQuick` for lifetime concerns.
pub inline fn addEdgeQuick(
    self: *Self,
    from_vertices: []const VertexHandle,
    to_vertices: []const VertexHandle,
    comptime Parent: type,
    parent: Parent,
) !EdgeHandle {
    var copy = parent;
    return try self.addEdge(from_vertices, to_vertices, &copy.edge);
}

/// `vertex` must outlive the graph
pub fn addVertex(
    self: *Self,
    observable: bool,
    vertex: *Vertex,
) !VertexHandle {
    const handle: VertexHandle = .{
        .inner = self.all_vertices.items.len,
    };

    vertex.* = .{
        .directly_observable = observable,
        .handle = handle,
    };

    try self.all_vertices.append(self.alloc, vertex);
    errdefer self.all_vertices.pop().?;

    return handle;
}

/// `from_vertices` and `to_vertices` will be duplicated on `self.alloc`,
/// it doesn't need to have the same lifetime as the graph.
///
/// `edge` has to outlive the graph.
pub fn addEdge(
    self: *Self,
    from_vertices: []const VertexHandle,
    to_vertices: []const VertexHandle,
    edge: *Edge,
) !EdgeHandle {
    try self.all_edges.append(self.alloc, edge);
    errdefer _ = self.all_edges.pop().?;

    const edge_handle: EdgeHandle = .{
        .inner = self.all_edges.items.len - 1,
    };

    const duped_from = try self.alloc.dupe(VertexHandle, from_vertices);
    errdefer self.alloc.free(duped_from);

    const duped_to = try self.alloc.dupe(VertexHandle, to_vertices);
    errdefer self.alloc.free(duped_to);

    // make sure that every vertex in `from_vertices` knows they are
    // required for this `edge_ptr` to execute.
    {
        var num_appended: usize = 0;
        errdefer for (from_vertices[0..num_appended]) |from_vertex_handle| {
            const from_vertex = self.getVertex(from_vertex_handle);
            _ = from_vertex.needed_by.pop().?;
        };

        for (from_vertices) |from_vertex_handle| {
            const from_vertex = self.getVertex(from_vertex_handle);

            try from_vertex.needed_by.append(self.alloc, edge_handle);
            num_appended += 1;
        }
    }
    errdefer for (from_vertices) |from_vertex_handle| {
        const from_vertex = self.getVertex(from_vertex_handle);
        _ = from_vertex.needed_by.pop().?;
    };

    for (to_vertices) |to_vertex_handle| {
        const to_vertex = self.getVertex(to_vertex_handle);
        std.debug.assert(to_vertex.produced_by == null);
        to_vertex.produced_by = edge_handle;
    }
    errdefer for (to_vertices) |to_vertex| {
        to_vertex.produced_by = null;
    };

    edge.* = .{
        .from = duped_from,
        .to = duped_to,
    };

    return edge_handle;
}

fn undoFinishObservability(self: *Self) void {
    for (self.all_vertices.items) |vertex| {
        vertex.observable = false;
    }
}

fn finishObservability(self: *Self) !void {
    errdefer self.undoFinishObservability();

    var iter = self.iterateVertices();
    while (iter.next()) |root_vertex_handle| {
        const root_vertex = self.getVertex(root_vertex_handle);

        if (!root_vertex.directly_observable) continue;

        var stack: std.ArrayList(VertexHandle) = .empty;
        defer stack.deinit(self.alloc);

        try stack.append(self.alloc, root_vertex_handle);
        while (stack.pop()) |vertex_handle| {
            const vertex = self.getVertex(vertex_handle);
            if (vertex.observable) continue;

            vertex.observable = true;

            const edge_handle = vertex.produced_by orelse continue;
            const edge = self.getEdge(edge_handle);
            for (edge.from) |child_vertex_handle| {
                try stack.append(self.alloc, child_vertex_handle);
            }
        }
    }
}

pub fn finish(self: *Self) !void {
    try self.finishObservability();
    errdefer self.undoFinishObservability();
}

// lol
//
// ok so the rationale behind this is that the handle types can get more
// complex in the future. we want to restrict the api upfront.
fn Iterator(comptime Handle: type) type {
    return struct {
        const Iter = @This();

        cur: usize = 0,
        max: usize,

        pub fn next(iter: *Iter) ?Handle {
            if (iter.cur == iter.max) return null;
            std.debug.assert(iter.cur < iter.max);

            const ret: Handle = .{
                .inner = iter.cur,
            };
            iter.cur += 1;

            return ret;
        }
    };
}

const EdgeIterator = Iterator(EdgeHandle);
const VertexIterator = Iterator(VertexHandle);

pub fn iterateVertices(self: *Self) VertexIterator {
    return .{
        .max = self.all_vertices.items.len,
    };
}

pub fn iterateEdges(self: *Self) EdgeIterator {
    return .{
        .max = self.all_edges.items.len,
    };
}

pub fn setVertexBit(
    self: *Self,
    vertex_handle: VertexHandle,
    bit_set: *std.DynamicBitSetUnmanaged,
    value: bool,
) void {
    std.debug.assert(bit_set.bit_length >= self.all_vertices.items.len);

    bit_set.setValue(vertex_handle.inner, value);
}

pub fn getVertex(self: *Self, handle: VertexHandle) *Vertex {
    return self.all_vertices.items[handle.inner];
}

pub fn getVertexBit(
    self: *Self,
    vertex_handle: VertexHandle,
    bit_set: *std.DynamicBitSetUnmanaged,
) bool {
    std.debug.assert(bit_set.bit_length >= self.all_vertices.items.len);

    return bit_set.isSet(vertex_handle.inner);
}

pub fn setEdgeBit(
    self: *Self,
    edge_handle: EdgeHandle,
    bit_set: *std.DynamicBitSetUnmanaged,
    value: bool,
) void {
    std.debug.assert(bit_set.bit_length >= self.all_edges.items.len);

    bit_set.setValue(edge_handle.inner, value);
}

pub fn getEdge(self: *Self, handle: EdgeHandle) *Edge {
    return self.all_edges.items[handle.inner];
}

pub fn getEdgeBit(
    self: *Self,
    edge_handle: EdgeHandle,
    bit_set: *std.DynamicBitSetUnmanaged,
) bool {
    std.debug.assert(bit_set.bit_length >= self.all_edges.items.len);

    return bit_set.isSet(edge_handle.inner);
}

alloc: std.mem.Allocator,

all_vertices: std.ArrayList(*Vertex) = .empty,
all_edges: std.ArrayList(*Edge) = .empty,
