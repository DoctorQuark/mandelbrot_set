pub fn createCommandBuffers(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    gpa: Allocator,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    swap_images: []SwapImage,
    storage_image_views: []StorageImage,
    descriptor_sets: []vk.DescriptorSet,
    extent: vk.Extent2D,
    query_pool: vk.QueryPool,
) ![]vk.CommandBuffer {
    const cmdbufs = try gpa.alloc(vk.CommandBuffer, swap_images.len);
    errdefer gpa.free(cmdbufs);

    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @intCast(cmdbufs.len),
    }, cmdbufs.ptr);
    errdefer gc.dev.freeCommandBuffers(pool, @intCast(cmdbufs.len), cmdbufs.ptr);

    for (cmdbufs, swap_images, storage_image_views, descriptor_sets) |cmdbuf, swap_image, storage_image, descriptor_set| {
        const copy_src_barrier: vk.ImageMemoryBarrier = .{
            .old_layout = .general,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = storage_image.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
        };

        const copy_revert_barrier: vk.ImageMemoryBarrier = .{
            .old_layout = .transfer_src_optimal,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = storage_image.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{ .transfer_read_bit = true },
            .dst_access_mask = .{ .shader_write_bit = true },
        };

        const present_revert_barrier: vk.ImageMemoryBarrier = .{
            .old_layout = .present_src_khr,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = swap_image.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{ .memory_read_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
        };

        const present_barrier: vk.ImageMemoryBarrier = .{
            .old_layout = .transfer_dst_optimal,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = swap_image.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .memory_read_bit = true },
        };

        try gc.dev.beginCommandBuffer(cmdbuf, &.{});

        gc.dev.cmdResetQueryPool(cmdbuf, query_pool, 0, 2);
        gc.dev.cmdWriteTimestamp(cmdbuf, .{ .compute_shader_bit = true }, query_pool, 0);

        gc.dev.cmdBindPipeline(cmdbuf, .compute, pipeline);
        gc.dev.cmdBindDescriptorSets(
            cmdbuf,
            .compute,
            pipeline_layout,
            0,
            1,
            &.{descriptor_set},
            0,
            null,
        );

        gc.dev.cmdDispatch(cmdbuf, try std.math.divCeil(u32, extent.width + 15, 16), try std.math.divCeil(u32, extent.height + 15, 16), 1);

        gc.dev.cmdPipelineBarrier(
            cmdbuf,
            .{ .compute_shader_bit = true },
            .{ .transfer_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            &.{copy_src_barrier},
        );

        gc.dev.cmdPipelineBarrier(
            cmdbuf,
            .{ .top_of_pipe_bit = true },
            .{ .transfer_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            &.{present_revert_barrier},
        );

        const region = vk.ImageCopy{
            .src_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        };
        gc.dev.cmdCopyImage(cmdbuf, storage_image.image, .transfer_src_optimal, swap_image.image, .transfer_dst_optimal, 1, @ptrCast(&region));

        gc.dev.cmdPipelineBarrier(
            cmdbuf,
            .{ .transfer_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            &.{copy_revert_barrier},
        );

        gc.dev.cmdPipelineBarrier(
            cmdbuf,
            .{ .transfer_bit = true },
            .{ .bottom_of_pipe_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            &.{present_barrier},
        );

        gc.dev.cmdWriteTimestamp(cmdbuf, .{ .compute_shader_bit = true }, query_pool, 1);

        try gc.dev.endCommandBuffer(cmdbuf);
    }

    return cmdbufs;
}

pub fn destroyCommandBuffers(gc: *const GraphicsContext, pool: vk.CommandPool, gpa: Allocator, cmdbufs: []vk.CommandBuffer) void {
    gc.dev.freeCommandBuffers(pool, @truncate(cmdbufs.len), cmdbufs.ptr);
    gpa.free(cmdbufs);
}

pub fn createPipeline(
    gc: *const GraphicsContext,
    layout: vk.PipelineLayout,
) !vk.Pipeline {
    const comp = try gc.dev.createShaderModule(&.{
        .code_size = mandelbrot.len,
        .p_code = @alignCast(@ptrCast(mandelbrot)),
    }, null);
    defer gc.dev.destroyShaderModule(comp, null);

    const pssci = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .compute_bit = true },
        .module = comp,
        .p_name = "main",
    };

    const cpci = vk.ComputePipelineCreateInfo{
        .flags = .{},
        .stage = pssci,
        .layout = layout,
        .base_pipeline_index = 0,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try gc.dev.createComputePipelines(
        .null_handle,
        1,
        @ptrCast(&cpci),
        null,
        @ptrCast(&pipeline),
    );
    return pipeline;
}

const std = @import("std");
const root = @import("root");
const lib = root.lib;
const vk = lib.vk;

const static_data = lib.static_data;

const types = lib.types;
const graphics_types = types.graphics;
const Vertex = graphics_types.Vertex;
const ObjectConstants = graphics_types.ObjectConstants;

const GraphicsContext = lib.GraphicContext;
const Swapchain = lib.Swapchain;
const SwapImage = Swapchain.SwapImage;
const StorageImage = root.StorageImage;

const shaders = @import("shaders");
const mandelbrot = shaders.mandelbrot;

const Allocator = std.mem.Allocator;
