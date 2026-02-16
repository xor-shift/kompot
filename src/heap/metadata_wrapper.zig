const std = @import("std");

const kompot = @import("../root.zig");

pub fn AllocatorWithHooks(comptime Callbacks: type) type {
    return struct {
        const Self = @This();

        const Slices = struct {
            posterior_padding: []u8,
            posterior_space: []u8,
            memory: []u8,
            anterior_space: []u8,
        };

        const LazySlices = struct {
            ptr: [*]u8,

            conservative_space_before: usize,
            space_after: usize,

            length: usize,
            alignment: std.mem.Alignment,

            fn computePadding(self: LazySlices) usize {
                const ab = self.alignment.toByteUnits();
                const blocks_before = (self.conservative_space_before + ab - 1) / ab;
                const liberal_space_before = blocks_before * ab;
                const padding_before = liberal_space_before - self.conservative_space_before;

                return padding_before;
            }

            fn totalLength(self: LazySlices) usize {
                const liberal_space_before = self.conservative_space_before + self.computePadding();
                return liberal_space_before + self.length + self.space_after;
            }

            fn slices(self: LazySlices) Slices {
                const actual_ptr = self.ptr;

                const padding_before = self.computePadding();
                const total_length = self.totalLength();

                const actual_memory = actual_ptr[0..total_length];

                const posterior_padding = actual_memory[0..padding_before];
                const after_posterior_padding = actual_memory[padding_before..];

                const posterior_space = after_posterior_padding[0..self.conservative_space_before];
                const after_posterior_space = after_posterior_padding[self.conservative_space_before..];

                const memory = after_posterior_space[0..self.length];
                const after_memory = after_posterior_space[self.length..];

                const anterior_space = after_memory[0..self.space_after];
                const after_anterior_space = after_memory[self.space_after..];

                std.debug.assert(after_anterior_space.len == 0);

                return .{
                    .posterior_padding = posterior_padding,
                    .posterior_space = posterior_space,
                    .memory = memory,
                    .anterior_space = anterior_space,
                };
            }
        };

        pub fn init(inner: std.mem.Allocator) Self {
            return .{
                .inner = inner,
            };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            const VTable = struct {
                fn alloc(
                    self_opaque: *anyopaque,
                    length: usize,
                    alignment: std.mem.Alignment,
                    ret_addr: usize,
                ) ?[*]u8 {
                    const self_: *Self = @ptrCast(@alignCast(self_opaque));

                    return self_.vAlloc(length, alignment, ret_addr);
                }

                fn free(
                    self_opaque: *anyopaque,
                    memory: []u8,
                    alignment: std.mem.Alignment,
                    ret_addr: usize,
                ) void {
                    const self_: *Self = @ptrCast(@alignCast(self_opaque));
                    return self_.vFree(memory, alignment, ret_addr);
                }

                fn resize(
                    self_opaque: *anyopaque,
                    memory: []u8,
                    alignment: std.mem.Alignment,
                    new_len: usize,
                    ret_addr: usize,
                ) bool {
                    const self_: *Self = @ptrCast(@alignCast(self_opaque));
                    return self_.vResize(memory, alignment, new_len, ret_addr);
                }
            };

            return .{
                .ptr = @ptrCast(self),
                .vtable = &std.mem.Allocator.VTable{
                    .alloc = &VTable.alloc,
                    .resize = std.mem.Allocator.noResize,
                    .remap = std.mem.Allocator.noRemap,
                    .free = &VTable.free,
                },
            };
        }

        fn vAlloc(
            self: *Self,
            length: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            var alloc_state = Callbacks.AllocState.init(self, length, alignment, ret_addr);
            defer alloc_state.deinit();

            var lazy_slices: LazySlices = .{
                .ptr = undefined,

                .conservative_space_before = alloc_state.additionalSpace()[0],
                .space_after = alloc_state.additionalSpace()[1],

                .length = length,
                .alignment = alignment,
            };

            const actual_ptr = self.inner.rawAlloc(lazy_slices.totalLength(), alignment, ret_addr) orelse {
                alloc_state.onFailure();
                return null;
            };

            lazy_slices.ptr = actual_ptr;
            const slices = lazy_slices.slices();

            alloc_state.postAlloc(slices);

            // std.log.debug("allocated {d} bytes at {*} (returning {*})", .{
            //     lazy_slices.totalLength(),
            //     actual_ptr,
            //     slices.memory.ptr,
            // });

            return slices.memory.ptr;
        }

        fn vFree(
            self: *Self,
            nudged_memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) void {
            var free_state = Callbacks.FreeState.init(self, nudged_memory, alignment, ret_addr);
            defer free_state.deinit();

            var lazy_slices: LazySlices = .{
                .ptr = undefined,

                .conservative_space_before = free_state.additionalSpace()[0],
                .space_after = free_state.additionalSpace()[1],

                .length = nudged_memory.len,
                .alignment = alignment,
            };

            const length = nudged_memory.len;
            const total_length = lazy_slices.totalLength();
            std.debug.assert(total_length >= length);

            const nudged_ptr = nudged_memory.ptr;
            const actual_ptr = nudged_ptr - (lazy_slices.conservative_space_before + lazy_slices.computePadding());
            const actual_memory = actual_ptr[0..total_length];

            lazy_slices.ptr = actual_ptr;
            const slices = lazy_slices.slices();

            free_state.preFree(slices);

            // std.log.debug("freeing {d} bytes at {*} (got given {*})", .{
            //     actual_memory.len,
            //     actual_memory.ptr,
            //     nudged_ptr,
            // });
            self.inner.rawFree(actual_memory, alignment, ret_addr);
        }

        fn vResize(
            self: *Self,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_length: usize,
            ret_addr: usize,
        ) bool {
            _ = self;
            _ = memory;
            _ = alignment;
            _ = new_length;
            _ = ret_addr;

            return false;
        }

        inner: std.mem.Allocator,
    };
}

pub const DummyCallbacks = struct {
    const Wrapper = AllocatorWithHooks(DummyCallbacks);

    pub const AllocState = struct {
        pub fn init(
            self: *Wrapper,
            length: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) AllocState {
            _ = self;
            _ = length;
            _ = alignment;
            _ = ret_addr;

            return .{};
        }

        pub fn deinit(
            self: *AllocState,
        ) void {
            _ = self;
        }

        pub fn onFailure(self: *AllocState) void {
            _ = self;
        }

        pub fn additionalSpace(self: *AllocState) [2]usize {
            _ = self;
            return .{ 0, 0 };
        }

        pub fn postAlloc(
            self: *AllocState,
            slices: Wrapper.Slices,
        ) void {
            _ = self;
            _ = slices;
        }
    };

    pub const FreeState = struct {
        pub fn init(
            self: *Wrapper,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) FreeState {
            _ = self;
            _ = memory;
            _ = alignment;
            _ = ret_addr;

            return .{};
        }

        pub fn deinit(self: *FreeState) void {
            _ = self;
        }

        pub fn additionalSpace(self: *FreeState) [2]usize {
            _ = self;

            return .{ 0, 0 };
        }

        pub fn preFree(
            self: *FreeState,
            slices: Wrapper.Slices,
        ) void {
            _ = self;
            _ = slices;
        }
    };
};

test "AllocatorWithHooks with DummyCallbacks" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var wrapped: AllocatorWithHooks(DummyCallbacks) = .init(gpa.allocator());
    const alloc = wrapped.allocator();

    const context = struct {
        fn checkEmpty(alloc_: std.mem.Allocator) bool {
            const wrapped_: *AllocatorWithHooks(DummyCallbacks) = @ptrCast(@alignCast(alloc_.ptr));
            _ = wrapped_;

            return true;
        }

        fn onFailure(alloc_: std.mem.Allocator) void {
            const wrapped_: *AllocatorWithHooks(DummyCallbacks) = @ptrCast(@alignCast(alloc_.ptr));

            _ = wrapped_;
        }
    };

    const tester = @import("allocator_tester.zig");
    try tester.testAllocator(std.testing.allocator, alloc, context.checkEmpty, context.onFailure);
}

pub const SafetyWrapper = struct {
    const Self = @This();

    const AllocationList = kompot.UnalignedDoublyLinkedList;

    const Canary = [16]u8;

    const constants = struct {
        const posterior_canary: Canary = .{
            0x27, 0x98, 0x99, 0xca,
            0xf9, 0xfd, 0x27, 0x2b,
            0xb9, 0x55, 0xc1, 0x87,
            0x17, 0x91, 0x0e, 0xe7,
        };

        const anterior_canary: Canary = .{
            0xd7, 0x3c, 0xcc, 0x22,
            0x29, 0x8b, 0xf3, 0x39,
            0x19, 0xbf, 0x7f, 0x06,
            0x41, 0x69, 0xb4, 0x88,
        };

        const padding: u8 = 0x44;
        const data_fill: u8 = 0x55;
        const free_fill: u8 = 0x55;
    };

    const Header = struct {
        list_node: AllocationList.Node = .{},

        length: usize,
        alignment: std.mem.Alignment,
        allocated_by: usize,
        deallocated_by: usize,
    };

    const Callbacks = struct {
        const Wrapper = AllocatorWithHooks(Callbacks);

        pub const AllocState = struct {
            self: *Self,
            length: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,

            pub fn init(
                wrapper: *Wrapper,
                length: usize,
                alignment: std.mem.Alignment,
                ret_addr: usize,
            ) AllocState {
                const self: *Self = @fieldParentPtr("inner", wrapper);

                self.criticalStart();

                return .{
                    .self = self,
                    .length = length,
                    .alignment = alignment,
                    .ret_addr = ret_addr,
                };
            }

            pub fn deinit(
                self: *AllocState,
            ) void {
                self.self.criticalEnd();
            }

            pub fn onFailure(self: *AllocState) void {
                _ = self;
            }

            pub fn additionalSpace(self: *AllocState) [2]usize {
                _ = self;
                return .{ @sizeOf(Header) + @sizeOf(Canary), @sizeOf(Canary) };
            }

            pub fn postAlloc(
                self: *AllocState,
                slices: Wrapper.Slices,
            ) void {
                const header_space = slices.posterior_space[0..@sizeOf(Header)];
                const posterior_canary_space = slices.posterior_space[@sizeOf(Header)..];

                @memset(slices.posterior_padding, constants.padding);
                @memcpy(posterior_canary_space, &constants.posterior_canary);
                @memcpy(slices.anterior_space, &constants.anterior_canary);

                const header: *align(1) Header = @ptrCast(header_space.ptr);

                header.* = .{
                    .length = self.length,
                    .alignment = self.alignment,
                    .allocated_by = self.ret_addr,
                    .deallocated_by = 0,
                };

                self.self.allocation_list.append(&header.list_node);
            }
        };

        pub const FreeState = struct {
            self: *Self,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,

            pub fn init(
                wrapper: *Wrapper,
                memory: []u8,
                alignment: std.mem.Alignment,
                ret_addr: usize,
            ) FreeState {
                const self: *Self = @fieldParentPtr("inner", wrapper);

                self.criticalStart();

                return .{
                    .self = self,
                    .memory = memory,
                    .alignment = alignment,
                    .ret_addr = ret_addr,
                };
            }

            pub fn deinit(
                self: *FreeState,
            ) void {
                self.self.criticalEnd();
            }

            pub fn additionalSpace(self: *FreeState) [2]usize {
                _ = self;

                return .{ @sizeOf(Header) + @sizeOf(Canary), @sizeOf(Canary) };
            }

            pub fn preFree(
                self: *FreeState,
                slices: Wrapper.Slices,
            ) void {
                const header_space = slices.posterior_space[0..@sizeOf(Header)];
                const posterior_canary_space = slices.posterior_space[@sizeOf(Header)..];

                if (!std.mem.allEqual(u8, slices.posterior_padding, constants.padding)) {
                    @panic("bad posterior padding");
                }

                if (!std.mem.eql(u8, posterior_canary_space, &constants.posterior_canary)) {
                    @panic("bad posterior canary");
                }

                if (!std.mem.eql(u8, slices.anterior_space, &constants.anterior_canary)) {
                    @panic("bad anterior canary");
                }

                const header: *align(1) Header = @ptrCast(header_space.ptr);

                if (header.length != self.memory.len) {
                    @panic("bad length");
                }

                if (header.alignment != self.alignment) {
                    @panic("bad length");
                }

                header.deallocated_by = self.ret_addr;

                self.self.allocation_list.remove(&header.list_node);
                header.list_node = .{};
            }
        };
    };

    pub fn init(inner: std.mem.Allocator) Self {
        return .{
            .inner = .init(inner),
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.inner.allocator();
    }

    fn criticalStart(self: *Self) void {
        if (self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            @panic("race detected!");
        }
    }

    fn criticalEnd(self: *Self) void {
        self.race_detector.store(false, .release);
    }

    inner: AllocatorWithHooks(Callbacks),

    race_detector: std.atomic.Value(bool) = .init(false),
    allocation_list: AllocationList = .{},
};

test SafetyWrapper {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var wrapper: SafetyWrapper = .init(gpa.allocator());
    const alloc = wrapper.allocator();

    alloc.free(try alloc.alloc(u8, 5));

    const context = struct {
        fn checkEmpty(alloc_: std.mem.Allocator) bool {
            const wrapped_: *AllocatorWithHooks(DummyCallbacks) = @ptrCast(@alignCast(alloc_.ptr));
            _ = wrapped_;

            return true;
        }

        fn onFailure(alloc_: std.mem.Allocator) void {
            const wrapped_: *AllocatorWithHooks(DummyCallbacks) = @ptrCast(@alignCast(alloc_.ptr));

            _ = wrapped_;
        }
    };

    const tester = @import("allocator_tester.zig");
    try tester.testAllocator(std.testing.allocator, alloc, context.checkEmpty, context.onFailure);
}
