gc: *const GraphicsContext,
allocator: Allocator,

surface_format: vk.SurfaceFormatKHR,
present_mode: vk.PresentModeKHR,
extent: vk.Extent2D,
handle: vk.SwapchainKHR,

swap_images: []SwapImage,
image_index: u32,
next_image_acquired: vk.Semaphore,

render_area: vk.Rect2D,
clear: [2]vk.ClearValue,
render_pass: vk.RenderPass,
pipeline_layout: vk.PipelineLayout,

static_pool: vk.CommandPool,
static_buffers: []vk.CommandBuffer,

pub fn init(gc: *const GraphicsContext, allocator: Allocator, extent: vk.Extent2D, clear: [2]vk.ClearValue) !Swapchain {
    return try initRecycle(gc, allocator, extent, clear, .null_handle);
}

pub fn initRecycle(gc: *const GraphicsContext, allocator: Allocator, extent: vk.Extent2D, clear: [2]vk.ClearValue, old_handle: vk.SwapchainKHR) !Swapchain {
    const caps = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
    const actual_extent = findActualExtent(caps, extent);
    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const surface_format = try findSurfaceFormat(gc, allocator);
    const present_mode = try findPresentMode(gc, allocator);

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) {
        image_count = @min(image_count, caps.max_image_count);
    }

    const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family };
    const sharing_mode: vk.SharingMode = if (gc.graphics_queue.family != gc.present_queue.family)
        .concurrent
    else
        .exclusive;

    const pool = try gc.dev.createCommandPool(&.{
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    errdefer gc.dev.destroyCommandPool(pool, null);

    const cmdbufs = try allocator.alloc(vk.CommandBuffer, 1);
    errdefer allocator.free(cmdbufs);

    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .secondary,
        .command_buffer_count = @intCast(cmdbufs.len),
    }, cmdbufs.ptr);
    errdefer gc.dev.freeCommandBuffers(pool, @intCast(cmdbufs.len), cmdbufs.ptr);

    const render_area: vk.Rect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    const handle = try gc.dev.createSwapchainKHR(&.{
        .surface = gc.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .queue_family_index_count = qfi.len,
        .p_queue_family_indices = &qfi,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = old_handle,
    }, null);
    errdefer gc.dev.destroySwapchainKHR(handle, null);

    if (old_handle != .null_handle) {
        // Apparently, the old swapchain handle still needs to be destroyed after recreating.
        gc.dev.destroySwapchainKHR(old_handle, null);
    }

    const swap_images = try initSwapchainImages(gc, handle, extent, surface_format.format, allocator);
    errdefer {
        for (swap_images) |si| si.deinit(gc);
        allocator.free(swap_images);
    }

    var next_image_acquired = try gc.dev.createSemaphore(&.{}, null);
    errdefer gc.dev.destroySemaphore(next_image_acquired, null);

    const result = try gc.dev.acquireNextImageKHR(handle, std.math.maxInt(u64), next_image_acquired, .null_handle);
    if (result.result != .success) {
        return error.ImageAcquireFailed;
    }

    std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);
    return Swapchain{
        .gc = gc,
        .allocator = allocator,
        .surface_format = surface_format,
        .present_mode = present_mode,
        .extent = actual_extent,
        .handle = handle,
        .swap_images = swap_images,
        .image_index = result.image_index,
        .next_image_acquired = next_image_acquired,
        .render_area = render_area,
        .clear = clear,
        .render_pass = undefined,
        .pipeline_layout = undefined,
        .static_pool = pool,
        .static_buffers = cmdbufs,
    };
}

fn deinitExceptSwapchain(self: Swapchain) void {
    for (self.swap_images) |si| si.deinit(self.gc);
    self.gc.dev.freeCommandBuffers(self.static_pool, @intCast(self.static_buffers.len), self.static_buffers.ptr);
    self.gc.allocator.free(self.static_buffers);
    self.gc.dev.destroyCommandPool(self.static_pool, null);
    self.allocator.free(self.swap_images);
    self.gc.dev.destroySemaphore(self.next_image_acquired, null);
}

pub fn waitForAllFences(self: Swapchain) !void {
    for (self.swap_images) |si| si.waitForFence(self.gc) catch {};
}

pub fn deinit(self: Swapchain) void {
    self.deinitExceptSwapchain();
    self.gc.dev.destroySwapchainKHR(self.handle, null);
}

pub fn recreate(self: *Swapchain, new_extent: vk.Extent2D) !void {
    const gc = self.gc;
    const allocator = self.allocator;
    const old_handle = self.handle;
    self.deinitExceptSwapchain();
    self.* = try initRecycle(gc, allocator, new_extent, self.clear, old_handle);
}

pub fn currentImage(self: Swapchain) vk.Image {
    return self.swap_images[self.image_index].image;
}

pub fn currentSwapImage(self: Swapchain) *const SwapImage {
    return &self.swap_images[self.image_index];
}

pub fn present(self: *Swapchain, object_constants: *ObjectConstants, framebuffer: vk.Framebuffer) !PresentState {
    // Simple method:
    // 1) Acquire next image
    // 2) Wait for and reset fence of the acquired image
    // 3) Submit command buffer with fence of acquired image,
    //    dependendent on the semaphore signalled by the first step.
    // 4) Present current frame, dependent on semaphore signalled by previous step
    // Problem: This way we can't reference the current image while rendering.
    // Better method: Shuffle the steps around such that acquire next image is the last step,
    // leaving the swapchain in a state with the current image.
    // 1) Wait for and reset fence of current image
    // 2) Submit command buffer, signalling fence of current image and dependent on
    //    the semaphore signalled by step 4.
    // 3) Present current frame, dependent on semaphore signalled by the submit
    // 4) Acquire next image, signalling its semaphore
    // One problem that arises is that we can't know beforehand which semaphore to signal,
    // so we keep an extra auxilery semaphore that is swapped around

    // Step 1: Make sure the current frame has finished rendering
    const current = self.currentSwapImage();
    try current.waitForFence(self.gc);
    try self.gc.dev.resetFences(1, @ptrCast(&current.frame_fence));

    const cmdbuf = current.cmdbufs[0];
    try init_helpers.recordDynBuffer(
        self.gc,
        cmdbuf,
        self.static_buffers,
        self.render_area,
        self.clear,
        self.render_pass,
        self.pipeline_layout,
        framebuffer,
        object_constants,
    );

    // Step 2: Submit the command buffer
    const wait_stage = [_]vk.PipelineStageFlags{.{ .top_of_pipe_bit = true }};
    try self.gc.dev.queueSubmit(self.gc.graphics_queue.handle, 1, &[_]vk.SubmitInfo{.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&current.image_acquired),
        .p_wait_dst_stage_mask = &wait_stage,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&current.render_finished),
    }}, current.frame_fence);

    // Step 3: Present the current frame
    _ = try self.gc.dev.queuePresentKHR(self.gc.present_queue.handle, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&current.render_finished),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.handle),
        .p_image_indices = @ptrCast(&self.image_index),
    });

    // Step 4: Acquire next frame
    const result = try self.gc.dev.acquireNextImageKHR(
        self.handle,
        std.math.maxInt(u64),
        self.next_image_acquired,
        .null_handle,
    );

    std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
    self.image_index = result.image_index;

    return switch (result.result) {
        .success => .optimal,
        .suboptimal_khr => .suboptimal,
        else => unreachable,
    };
}

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    depth: vk.Image,
    depth_image_memory: vk.DeviceMemory,
    depth_view: vk.ImageView,
    multisampling_image: vk.Image,
    multisampling_image_memory: vk.DeviceMemory,
    multisampling_view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,
    command_pool: vk.CommandPool,
    cmdbufs: []vk.CommandBuffer,

    fn init(gc: *const GraphicsContext, allocator: Allocator, image: vk.Image, format: vk.Format, extent: vk.Extent2D) !SwapImage {
        const view = try gc.dev.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer gc.dev.destroyImageView(view, null);

        const depth_image_format = try gc.findDepthFormat();
        const sample_count = gc.getMaxSampling();

        const depth_image_create_info: vk.ImageCreateInfo = .{
            .image_type = .@"2d",
            .extent = .{
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .format = depth_image_format,
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{
                .depth_stencil_attachment_bit = true,
            },
            .sharing_mode = .exclusive,
            .samples = sample_count,
            .flags = .{},
        };

        const depth_image: vk.Image = try gc.dev.createImage(&depth_image_create_info, null);
        errdefer gc.dev.destroyImage(depth_image, null);

        const depth_image_mem_reqs = gc.dev.getImageMemoryRequirements(depth_image);
        const depth_image_memory = try gc.allocate(depth_image_mem_reqs, .{ .device_local_bit = true });
        errdefer gc.dev.freeMemory(depth_image_memory, null);

        try gc.dev.bindImageMemory(depth_image, depth_image_memory, 0);

        const depth_image_view = try image_helpers.createImageView(gc, depth_image, depth_image_format, .{ .depth_bit = true }, 1);
        errdefer gc.dev.destroyImageView(depth_image_view, null);

        const sampling_image_create_info: vk.ImageCreateInfo = .{
            .image_type = .@"2d",
            .extent = .{
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .format = format,
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{
                .color_attachment_bit = true,
            },
            .sharing_mode = .exclusive,
            .samples = sample_count,
            .flags = .{},
        };

        const sampling_image: vk.Image = try gc.dev.createImage(&sampling_image_create_info, null);
        errdefer gc.dev.destroyImage(sampling_image, null);

        const sampling_image_mem_reqs = gc.dev.getImageMemoryRequirements(sampling_image);
        const sampling_image_memory = try gc.allocate(sampling_image_mem_reqs, .{ .device_local_bit = true });
        errdefer gc.dev.freeMemory(sampling_image_memory, null);

        try gc.dev.bindImageMemory(sampling_image, sampling_image_memory, 0);

        const sampling_image_view = try image_helpers.createImageView(gc, sampling_image, format, .{ .color_bit = true }, 1);
        errdefer gc.dev.destroyImageView(sampling_image_view, null);

        const image_acquired = try gc.dev.createSemaphore(&.{}, null);
        errdefer gc.dev.destroySemaphore(image_acquired, null);

        const render_finished = try gc.dev.createSemaphore(&.{}, null);
        errdefer gc.dev.destroySemaphore(render_finished, null);

        const frame_fence = try gc.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer gc.dev.destroyFence(frame_fence, null);

        const pool = try gc.dev.createCommandPool(&.{
            .queue_family_index = gc.graphics_queue.family,
            .flags = .{
                .reset_command_buffer_bit = true,
            },
        }, null);
        errdefer gc.dev.destroyCommandPool(pool, null);

        const buffers = try allocator.alloc(vk.CommandBuffer, 1);
        errdefer allocator.free(buffers);

        try gc.dev.allocateCommandBuffers(&.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = @intCast(buffers.len),
        }, buffers.ptr);
        errdefer gc.dev.freeCommandBuffers(pool, @intCast(buffers.len), buffers.ptr);

        return SwapImage{
            .image = image,
            .view = view,
            .depth = depth_image,
            .depth_image_memory = depth_image_memory,
            .depth_view = depth_image_view,
            .multisampling_image = sampling_image,
            .multisampling_image_memory = sampling_image_memory,
            .multisampling_view = sampling_image_view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
            .command_pool = pool,
            .cmdbufs = buffers,
        };
    }

    fn deinit(self: SwapImage, gc: *const GraphicsContext) void {
        gc.dev.queueWaitIdle(gc.present_queue.handle) catch return;
        self.waitForFence(gc) catch return;
        gc.dev.destroyImageView(self.view, null);
        gc.dev.destroyImageView(self.depth_view, null);
        gc.dev.destroyImage(self.depth, null);
        gc.dev.freeMemory(self.depth_image_memory, null);
        gc.dev.destroyImageView(self.multisampling_view, null);
        gc.dev.destroyImage(self.multisampling_image, null);
        gc.dev.freeMemory(self.multisampling_image_memory, null);
        gc.dev.destroySemaphore(self.image_acquired, null);
        gc.dev.destroySemaphore(self.render_finished, null);
        gc.dev.destroyFence(self.frame_fence, null);
        gc.dev.freeCommandBuffers(self.command_pool, @intCast(self.cmdbufs.len), self.cmdbufs.ptr);
        gc.allocator.free(self.cmdbufs);
        gc.dev.destroyCommandPool(self.command_pool, null);
    }

    pub fn waitForFence(self: SwapImage, gc: *const GraphicsContext) !void {
        _ = try gc.dev.waitForFences(1, @ptrCast(&self.frame_fence), vk.TRUE, std.math.maxInt(u64));
    }
};

fn initSwapchainImages(
    gc: *const GraphicsContext,
    swapchain: vk.SwapchainKHR,
    extent: vk.Extent2D,
    format: vk.Format,
    allocator: Allocator,
) ![]SwapImage {
    const images = try gc.dev.getSwapchainImagesAllocKHR(swapchain, allocator);
    defer allocator.free(images);

    const swap_images = try allocator.alloc(SwapImage, images.len);
    errdefer allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(gc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(gc, allocator, image, format, extent);
        i += 1;
    }

    return swap_images;
}

fn findSurfaceFormat(gc: *const GraphicsContext, allocator: Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    const surface_formats = try gc.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(gc.pdev, gc.surface, allocator);
    defer allocator.free(surface_formats);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

/// Caller owns the memory
pub fn listPresentModes(gc: *const GraphicsContext, allocator: Allocator) ![]vk.PresentModeKHR {
    return try gc.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(gc.pdev, gc.surface, allocator);
}

fn findPresentMode(gc: *const GraphicsContext, allocator: Allocator) !vk.PresentModeKHR {
    const present_modes = try listPresentModes(gc, allocator);
    defer allocator.free(present_modes);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .fifo_relaxed_khr,
        .fifo_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .immediate_khr;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}

pub const PresentState = enum {
    optimal,
    suboptimal,
};

const std = @import("std");

const root = @import("root");
const lib = root.lib;

const vk = lib.vk;
const GraphicsContext = lib.GraphicContext;

const types = lib.types;
const graphics_types = types.graphics;
const ObjectConstants = graphics_types.ObjectConstants;

const helpers = lib.helpers;
const image_helpers = helpers.image_helpers;
const init_helpers = helpers.init_helpers;

const Swapchain = @This();

const Allocator = std.mem.Allocator;
