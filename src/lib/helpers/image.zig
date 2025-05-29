pub fn transitionImageLayout(
    gc: *const GraphicsContext,
    command_pool: vk.CommandPool,
    img: vk.Image,
    format: vk.Format,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    mip_levels: u32,
) !void {
    _ = format;

    var cmdbuf_handle: vk.CommandBuffer = undefined;
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle));
    defer gc.dev.freeCommandBuffers(command_pool, 1, &.{cmdbuf_handle});

    const cmdbuf = GraphicsContext.CommandBuffer.init(cmdbuf_handle, gc.dev.wrapper);

    try cmdbuf.beginCommandBuffer(&.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const phase_one: bool = if (old_layout == .undefined and (new_layout == .transfer_dst_optimal or new_layout == .general or new_layout == .present_src_khr)) true else if (old_layout == .transfer_dst_optimal and new_layout == .read_only_optimal) false else return error.UnknownPhase;

    const src_access_mask: vk.AccessFlags = if (phase_one) .{} else .{ .transfer_write_bit = true };
    const dst_access_mask: vk.AccessFlags = if (phase_one) .{ .transfer_write_bit = true } else .{ .shader_read_bit = true };

    const barrier: vk.ImageMemoryBarrier = .{
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = img,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = mip_levels,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_access_mask = src_access_mask,
        .dst_access_mask = dst_access_mask,
    };

    const src_stage_flags: vk.PipelineStageFlags = if (phase_one) .{ .top_of_pipe_bit = true } else .{ .transfer_bit = true };
    const dst_stage_flags: vk.PipelineStageFlags = if (phase_one) .{ .transfer_bit = true } else .{ .fragment_shader_bit = true };

    cmdbuf.pipelineBarrier(
        src_stage_flags,
        dst_stage_flags,
        .{},
        0,
        null,
        0,
        null,
        1,
        &.{barrier},
    );

    try cmdbuf.endCommandBuffer();

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf.handle)[0..1],
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}

pub fn createImageView(gc: *const GraphicsContext, img: vk.Image, format: vk.Format, aspect_mask: vk.ImageAspectFlags, mip_levels: u32) !vk.ImageView {
    const image_view_create_info: vk.ImageViewCreateInfo = .{
        .image = img,
        .view_type = vk.ImageViewType.@"2d",
        .format = format,
        .subresource_range = .{
            .aspect_mask = aspect_mask,
            .base_mip_level = 0,
            .level_count = mip_levels,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{
            .r = .r,
            .g = .g,
            .b = .b,
            .a = .a,
        },
    };
    return try gc.dev.createImageView(&image_view_create_info, null);
}

pub fn generateMipMaps(gc: *const GraphicsContext, command_pool: vk.CommandPool, image: vk.Image, width: u32, height: u32, mip_levels: u32) !void {
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

    var mip_width: i32 = @intCast(width);
    var mip_height: i32 = @intCast(height);

    var barrier = vk.ImageMemoryBarrier{
        .image = image,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .subresource_range = .{
            .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
            .base_array_layer = 0,
            .layer_count = 1,
            .level_count = 1,
            .base_mip_level = 0,
        },
        .old_layout = vk.ImageLayout.transfer_dst_optimal,
        .new_layout = vk.ImageLayout.transfer_src_optimal,
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .transfer_read_bit = true },
    };

    for (1..mip_levels) |level| {
        const l: u32 = @intCast(level);
        barrier.subresource_range.base_mip_level = l - 1;
        barrier.old_layout = vk.ImageLayout.transfer_dst_optimal;
        barrier.new_layout = vk.ImageLayout.transfer_src_optimal;
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .transfer_read_bit = true };

        gc.dev.cmdPipelineBarrier(
            cmdbuf_handle,
            .{ .transfer_bit = true },
            .{ .transfer_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            &.{barrier},
        );

        const blit = vk.ImageBlit{
            .src_offsets = [_]vk.Offset3D{
                vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
                vk.Offset3D{ .x = mip_width, .y = mip_height, .z = 1 },
            },
            .src_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = l - 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .dst_offsets = [_]vk.Offset3D{
                vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
                vk.Offset3D{
                    .x = if (mip_width > 1) try std.math.divFloor(i32, mip_width, 2) else 1,
                    .y = if (mip_height > 1) try std.math.divFloor(i32, mip_height, 2) else 1,
                    .z = 1,
                },
            },
            .dst_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = l,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        gc.dev.cmdBlitImage(
            cmdbuf_handle,
            image,
            .transfer_src_optimal,
            image,
            .transfer_dst_optimal,
            1,
            &.{blit},
            .linear,
        );

        barrier.old_layout = .transfer_src_optimal;
        barrier.new_layout = .shader_read_only_optimal;
        barrier.src_access_mask = .{ .transfer_read_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };

        gc.dev.cmdPipelineBarrier(
            cmdbuf_handle,
            .{ .transfer_bit = true },
            .{ .fragment_shader_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            &.{barrier},
        );

        if (mip_width > 1) mip_width = try std.math.divFloor(i32, mip_width, 2);
        if (mip_height > 1) mip_height = try std.math.divFloor(i32, mip_height, 2);
    }

    barrier.subresource_range.base_mip_level = mip_levels - 1;
    barrier.old_layout = .transfer_dst_optimal;
    barrier.new_layout = .shader_read_only_optimal;
    barrier.src_access_mask = .{ .transfer_write_bit = true };
    barrier.dst_access_mask = .{ .shader_read_bit = true };

    gc.dev.cmdPipelineBarrier(
        cmdbuf_handle,
        .{ .transfer_bit = true },
        .{ .fragment_shader_bit = true },
        .{},
        0,
        null,
        0,
        null,
        1,
        &.{barrier},
    );

    try cmdbuf.endCommandBuffer();

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf.handle)[0..1],
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}

const std = @import("std");
const root = @import("root");
const lib = root.lib;
const vk = lib.vk;

const helpers = lib.helpers;
const buffer_helpers = helpers.buffer_helpers;

const GraphicsContext = lib.GraphicContext;
