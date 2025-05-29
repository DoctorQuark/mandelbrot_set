/// Submit command buffer to load vertex buffer (from stagin buffer) onto the gpu
/// dst - destination buffer: Buffer not shared with  the host
/// src - staging buffer: Buffer accessible from the CPU (and therefore slower)
pub fn copyBuffer(gc: *const GraphicsContext, command_pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf_handle: vk.CommandBuffer = undefined;
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle));
    defer gc.dev.freeCommandBuffers(command_pool, 1, @ptrCast(&cmdbuf_handle));

    const cmdbuf = GraphicsContext.CommandBuffer.init(cmdbuf_handle, gc.dev.wrapper);

    try cmdbuf.beginCommandBuffer(&.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    cmdbuf.copyBuffer(src, dst, 1, @ptrCast(&region));

    try cmdbuf.endCommandBuffer();

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf.handle)[0..1],
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}

pub fn copyBuffertoImage(gc: *const GraphicsContext, command_pool: vk.CommandPool, buffer: vk.Buffer, img: vk.Image, width: u32, height: u32) !void {
    var cmdbuf_handle: vk.CommandBuffer = undefined;
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle));
    defer gc.dev.freeCommandBuffers(command_pool, 1, @ptrCast(&cmdbuf_handle));

    const cmdbuf = GraphicsContext.CommandBuffer.init(cmdbuf_handle, gc.dev.wrapper);

    try cmdbuf.beginCommandBuffer(&.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,

        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },

        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{
            .width = width,
            .height = height,
            .depth = 1,
        },
    };
    cmdbuf.copyBufferToImage(buffer, img, vk.ImageLayout.transfer_dst_optimal, 1, @ptrCast(&region));

    try cmdbuf.endCommandBuffer();

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf.handle)[0..1],
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}

pub fn uploadData(gc: *const GraphicsContext, command_pool: vk.CommandPool, buffer: vk.Buffer, upload_data: anytype) !void {
    const T = @TypeOf(upload_data);
    const type_info = @typeInfo(T);

    if (!(type_info == .array or type_info == .pointer)) @compileError("Cannot upload data: wrong type:, array required");

    const size = if (type_info == .array) @sizeOf(T) else upload_data.len;

    const staging_buffer = try gc.dev.createBuffer(&.{
        .size = size,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer gc.dev.destroyBuffer(staging_buffer, null);
    const mem_reqs = gc.dev.getBufferMemoryRequirements(staging_buffer);
    const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.dev.freeMemory(staging_memory, null);
    try gc.dev.bindBufferMemory(staging_buffer, staging_memory, 0);

    {
        const data = try gc.dev.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer gc.dev.unmapMemory(staging_memory);

        const child_type: type = switch (type_info) {
            .array => type_info.array.child,
            .pointer => type_info.pointer.child,
            else => return error.idk,
        };
        const gpu_indices: [*]child_type = @ptrCast(@alignCast(data));
        @memcpy(gpu_indices, upload_data[0..upload_data.len]);
    }

    try copyBuffer(gc, command_pool, buffer, staging_buffer, size);
}

/// Copy vertices from global variable to staging_buffer
pub fn uploadVertices(gc: *const GraphicsContext, command_pool: vk.CommandPool, vert_buffer: vk.Buffer) !void {
    // Create staging buffer (Host visible -> with CPU access!)
    // The buffer will be discarded on function return
    const staging_buffer = try gc.dev.createBuffer(&.{
        .size = @sizeOf(@TypeOf(static_data.vertices)),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer gc.dev.destroyBuffer(staging_buffer, null);
    const mem_reqs = gc.dev.getBufferMemoryRequirements(staging_buffer);
    const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.dev.freeMemory(staging_memory, null);
    try gc.dev.bindBufferMemory(staging_buffer, staging_memory, 0);

    {
        // Map staging memory to data (so i can access it from CPU)
        const data = try gc.dev.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer gc.dev.unmapMemory(staging_memory);

        // copy current vertices to data (and therefore into staging buffer -> TO THE GPU MEMORY)
        const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(gpu_vertices, static_data.vertices[0..]);
    }

    try buffer_helpers.copyBuffer(gc, command_pool, vert_buffer, staging_buffer, @sizeOf(@TypeOf(static_data.vertices)));
}

pub fn uploadIndexes(gc: *const GraphicsContext, command_pool: vk.CommandPool, index_buffer: vk.Buffer) !void {
    // Create staging buffer (Host visible -> with CPU access!)
    // The buffer will be discarded on function return
    const staging_buffer = try gc.dev.createBuffer(&.{
        .size = @sizeOf(@TypeOf(static_data.vertices)),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer gc.dev.destroyBuffer(staging_buffer, null);
    const mem_reqs = gc.dev.getBufferMemoryRequirements(staging_buffer);
    const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.dev.freeMemory(staging_memory, null);
    try gc.dev.bindBufferMemory(staging_buffer, staging_memory, 0);

    {
        // Map staging memory to data (so i can access it from CPU)
        const data = try gc.dev.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer gc.dev.unmapMemory(staging_memory);

        // copy current vertices to data (and therefore into staging buffer -> TO THE GPU MEMORY)
        const gpu_indices: [*]u16 = @ptrCast(@alignCast(data));
        @memcpy(gpu_indices, static_data.indices[0..]);
    }

    try buffer_helpers.copyBuffer(gc, command_pool, index_buffer, staging_buffer, @sizeOf(@TypeOf(static_data.indices)));
}

pub fn createUniformBuffers(gc: *const GraphicsContext, gpa: Allocator, swapchain: Swapchain) ![]UniformBuffer {
    const uniform_buffers = try gpa.alloc(UniformBuffer, swapchain.swap_images.len);
    errdefer gpa.free(uniform_buffers);

    var i: usize = 0;
    errdefer for (uniform_buffers[0..i]) |ub| {
        gc.dev.freeMemory(ub.memory, null);
        gc.dev.destroyBuffer(ub.buffer, null);
    };

    for (uniform_buffers) |*uniform_buffer| {
        uniform_buffer.*.buffer = try gc.dev.createBuffer(&.{
            .size = @sizeOf(UniformBufferObject),
            .usage = .{ .uniform_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null);
        const ub_mem_reqs = gc.dev.getBufferMemoryRequirements(uniform_buffer.buffer);
        uniform_buffer.*.memory = try gc.allocate(ub_mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
        try gc.dev.bindBufferMemory(uniform_buffer.buffer, uniform_buffer.memory, 0);

        i += 1;
    }

    return uniform_buffers;
}

pub fn destroyUniformBuffers(gc: *const GraphicsContext, gpa: Allocator, uniform_buffers: []UniformBuffer) void {
    for (uniform_buffers) |uniform_buffer| {
        gc.dev.freeMemory(uniform_buffer.memory, null);
        gc.dev.destroyBuffer(uniform_buffer.buffer, null);
    }
    gpa.free(uniform_buffers);
}

pub fn updateUniformBuffer(gc: *const GraphicsContext, uniform_buffer: UniformBuffer, new_data: UniformBufferObject) !void {
    const data = try gc.dev.mapMemory(uniform_buffer.memory, 0, vk.WHOLE_SIZE, .{});
    defer gc.dev.unmapMemory(uniform_buffer.memory);
    const gpu_data: *UniformBufferObject = @ptrCast(@alignCast(data));
    gpu_data.* = new_data;
}

const std = @import("std");
const root = @import("root");
const lib = root.lib;
const vk = lib.vk;

const static_data = lib.static_data;

const types = lib.types;
const UniformBuffer = types.graphics.UniformBuffer;
const UniformBufferObject = types.graphics.UniformBufferObject;
const Vertex = types.graphics.Vertex;

const helpers = lib.helpers;
const buffer_helpers = helpers.buffer_helpers;

const GraphicsContext = lib.GraphicContext;
const Swapchain = lib.Swapchain;

const Allocator = std.mem.Allocator;
