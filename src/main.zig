pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw_out = std.io.bufferedWriter(stdout_file);
    const stdout = bw_out.writer();
    errdefer bw_out.flush() catch |err| std.process.fatal("Cannot flush on error, might be caused by stdout error.\nError: {!}\n", .{err});
    _ = stdout;

    const stderr_file = std.io.getStdErr().writer();
    var bw_err = std.io.bufferedWriter(stderr_file);
    const stderr = bw_err.writer();
    errdefer bw_err.flush() catch |err| std.process.fatal("Cannot flush on error, might be caused by stderr error.\nError: {!}\n", .{err});

    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    try stderr.print("debug: connecting to X11\n", .{});
    try bw_err.flush();

    var scr: c_int = undefined;
    const connection = xcb.connect(null, &scr).?;
    defer xcb.disconnect(connection);

    if (xcb.connection_has_error(connection) != 0) {
        try stderr.print("debug: Failed to open connection", .{});
        try bw_err.flush();
        return;
    }

    const setup = xcb.get_setup(connection);
    const root_iter = xcb.setup_roots_iterator(setup);
    const screen = root_iter.data;

    var extent: vk.Extent2D = .{ .width = 800, .height = 600 };

    try stderr.print("debug: opening window\n", .{});
    try bw_err.flush();
    const window = xcb.generate_id(connection);
    const mask = xcb.CW.BACK_PIXEL | xcb.CW.EVENT_MASK;
    const values = [_]u32{
        screen.black_pixel,
        xcb.EVENT_MASK.KEY_RELEASE |
            xcb.EVENT_MASK.KEY_PRESS |
            xcb.EVENT_MASK.EXPOSURE |
            xcb.EVENT_MASK.STRUCTURE_NOTIFY |
            xcb.EVENT_MASK.POINTER_MOTION |
            xcb.EVENT_MASK.BUTTON_PRESS |
            xcb.EVENT_MASK.BUTTON_RELEASE,
    };

    const window_class = @intFromEnum(xcb.window_class_t.INPUT_OUTPUT);
    _ = xcb.create_window(connection, xcb.COPY_FROM_PARENT, window, screen.root, 0, 0, @intCast(extent.width), @intCast(extent.height), 0, window_class, screen.root_visual, mask, &values);

    const atom_wm_protocols = try xorg_helpers.getAtom(connection, "WM_PROTOCOLS");
    const atom_wm_delete_window = try xorg_helpers.getAtom(connection, "WM_DELETE_WINDOW");
    _ = xcb.change_property(
        connection,
        .REPLACE,
        window,
        atom_wm_protocols,
        .ATOM,
        32,
        1,
        &atom_wm_delete_window,
    );

    const title = "Title";
    _ = xcb.change_property(connection, .REPLACE, window, .WM_NAME, .STRING, 8, title.len, title);

    // I HAVE NO IDEA WHAT IT DOES BUT MORE CODE IS TOTALLY BETTER SO I JUST COPIED IT FROM THE TUTORIAL LOL :d
    // Set the WM_CLASS property to display title in dash tooltip and
    // application menu on GNOME and other desktop environments
    var wm_class_buf: [100]u8 = undefined;
    const wm_class = std.fmt.bufPrint(&wm_class_buf, "windowName\x00{s}\x00", .{title}) catch unreachable;
    _ = xcb.change_property(
        connection,
        .REPLACE,
        window,
        .WM_CLASS,
        .STRING,
        8,
        @intCast(wm_class.len),
        wm_class.ptr,
    );

    _ = xcb.map_window(connection, window);

    // Spawn a thread for managing xorg events.
    // Messages will be passed using a queue.
    // Thread is used so it an block on wait_for_event, while the main thread can run without interruption.
    var event_queue = try MessageQueue.init(gpa, 16);
    defer event_queue.deinit();

    //var payload_queue = try PayloadQueue.init(gpa, 1);
    var payload_queue = try PayloadQueue.init(gpa, 8);
    defer payload_queue.deinit();

    std.log.debug("starting event thread", .{});
    const event_thread = try std.Thread.spawn(
        .{},
        processXEvents,
        .{
            gpa,
            &connection,
            window,
            atom_wm_protocols,
            atom_wm_delete_window,
            &extent,
            &event_queue,
            &payload_queue,
            stderr,
        },
    );
    defer event_thread.join();

    // ------------------------- VULKAN -------------------------
    const gc = try GraphicsContext.init(gpa, "Mandelbrot set", connection, window, enable_validation_layers);
    defer gc.deinit();
    //std.log.debug("Graphics queue: {}", .{gc.graphics_queue});
    //std.log.debug("Present queue: {}", .{gc.present_queue});
    //std.log.debug("Compute queue: {}", .{gc.compute_queue});

    try stderr.print("debug: Using device: {s}\n", .{gc.deviceName()});
    try bw_err.flush();

    var swapchain = try Swapchain.init(
        &gc,
        gpa,
        extent,
    );
    defer swapchain.deinit();

    const present_modes = try Swapchain.listPresentModes(&gc, gpa);
    defer gpa.free(present_modes);

    try stderr.print("debug: Available present modes:\n", .{});
    try bw_err.flush();
    for (present_modes) |mode| try stderr.print("  {}\n", .{mode});
    try stderr.print("debug: Selected present mode: {}\n", .{swapchain.present_mode});
    try bw_err.flush();

    const max_frames_in_flight: u32 = @intCast(swapchain.swap_images.len);
    try stderr.print("Buffers: {} (", .{max_frames_in_flight});
    try bw_err.flush();

    switch (max_frames_in_flight) {
        1 => try stderr.print("single ", .{}),
        2 => try stderr.print("double ", .{}),
        3 => try stderr.print("triple ", .{}),
        4 => try stderr.print("quadruple ", .{}),
        5 => try stderr.print("quintuple ", .{}),
        else => try stderr.print("unknown ", .{}),
    }
    try stderr.print("buffering)\n", .{});
    try bw_err.flush();

    while (event_queue.receive()) |event| {
        if (event == .extent_changed) break else try stderr.print("Unexpected event: {}\n", .{event});
        std.atomic.spinLoopHint();
    }

    const descriptor_set_layout_binding = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptor_type = vk.DescriptorType.uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .compute_bit = true },
            .p_immutable_samplers = null,
        },
        .{
            .binding = 1,
            .descriptor_type = vk.DescriptorType.storage_image,
            .descriptor_count = 1,
            .stage_flags = .{ .compute_bit = true },
            .p_immutable_samplers = null,
        },
    };
    const descriptor_set_layout_create_info: vk.DescriptorSetLayoutCreateInfo = .{
        //.s_type = vk.DescriptorSetLayoutCreateInfo,
        .binding_count = descriptor_set_layout_binding.len,
        .p_bindings = @ptrCast(&descriptor_set_layout_binding),
    };
    const descriptor_set_layout = try gc.dev.createDescriptorSetLayout(&descriptor_set_layout_create_info, null);
    defer gc.dev.destroyDescriptorSetLayout(descriptor_set_layout, null);

    const pipeline_layout = try gc.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = &.{descriptor_set_layout},
        .push_constant_range_count = 0,
        .p_push_constant_ranges = &.{},
    }, null);
    defer gc.dev.destroyPipelineLayout(pipeline_layout, null);

    const pipeline = try init_helpers.createPipeline(&gc, pipeline_layout);
    defer gc.dev.destroyPipeline(pipeline, null);

    const command_pool = try gc.dev.createCommandPool(&.{
        .queue_family_index = gc.compute_queue.family,
        .flags = .{},
    }, null);
    defer gc.dev.destroyCommandPool(command_pool, null);

    try stderr.print("config:\n", .{});
    inline for (@typeInfo(build_options).@"struct".decls) |option| try stderr.print("  {s}: {?}\n", .{ option.name, @field(build_options, option.name) }) else try stderr.print("\n", .{});
    try bw_err.flush();

    const storage_images: []StorageImage = try gpa.alloc(StorageImage, max_frames_in_flight);
    defer gpa.free(storage_images);

    std.log.debug("initializing storage images", .{});
    for (storage_images) |*storage_image| storage_image.* = try StorageImage.init(&gc, extent, .r8g8b8a8_unorm);
    defer for (storage_images) |storage_image| storage_image.deinit(&gc);
    for (storage_images) |storage_image| try storage_image.transitionImageLayout(&gc, command_pool);

    std.log.debug("Converting swap images to correct format", .{});
    for (swapchain.swap_images) |swap_image| try image_helpers.transitionImageLayout(&gc, command_pool, swap_image.image, swapchain.surface_format.format, .undefined, .present_src_khr, 1);

    std.log.debug("Creating uniform buffers", .{});
    const uniform_buffers = try buffer_helpers.createUniformBuffers(&gc, gpa, swapchain);
    defer buffer_helpers.destroyUniformBuffers(&gc, gpa, uniform_buffers);
    var ubo = UniformBufferObject{
        .zoom = 1,
        .x_offset = 0,
        .y_offset = 0,
        .scaled_size_x = 0,
        .size_offset_x = 0,
        .scaled_size_y = 0,
        .size_offset_y = 0,
    };

    std.log.debug("Creating descriptor pool", .{});
    const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
        vk.DescriptorPoolSize{
            .type = vk.DescriptorType.storage_image,
            .descriptor_count = max_frames_in_flight,
        },
        vk.DescriptorPoolSize{
            .type = vk.DescriptorType.uniform_buffer,
            .descriptor_count = max_frames_in_flight,
        },
    };
    const descriptor_pool_info: vk.DescriptorPoolCreateInfo = .{
        .pool_size_count = descriptor_pool_sizes.len,
        .p_pool_sizes = &descriptor_pool_sizes,
        .max_sets = max_frames_in_flight,
    };
    const descriptor_pool = try gc.dev.createDescriptorPool(&descriptor_pool_info, null);
    defer gc.dev.destroyDescriptorPool(descriptor_pool, null);

    std.log.debug("Allocating descriptor sets", .{});
    const descriptor_set_layouts = try gpa.alloc(vk.DescriptorSetLayout, max_frames_in_flight);
    for (descriptor_set_layouts) |*dsl| {
        dsl.* = descriptor_set_layout;
    }
    defer gpa.free(descriptor_set_layouts);
    const descriptor_set_allocate_info: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = descriptor_pool,
        .descriptor_set_count = max_frames_in_flight,
        .p_set_layouts = descriptor_set_layouts.ptr,
    };
    const descriptor_sets = try gpa.alloc(vk.DescriptorSet, max_frames_in_flight);
    defer gpa.free(descriptor_sets);
    try gc.dev.allocateDescriptorSets(&descriptor_set_allocate_info, descriptor_sets.ptr);

    const query_pool_create_info: vk.QueryPoolCreateInfo = .{
        .query_type = vk.QueryType.timestamp,
        .query_count = 2,
    };
    const query_pool = try gc.dev.createQueryPool(&query_pool_create_info, null);
    defer gc.dev.destroyQueryPool(query_pool, null);

    std.log.debug("Updating descriptor sets", .{});
    for (descriptor_sets, storage_images, uniform_buffers) |set, image, uniform_buffer| {
        const descriptor_buffer_info: vk.DescriptorBufferInfo = .{
            .buffer = uniform_buffer.buffer,
            .offset = 0,
            .range = @sizeOf(UniformBufferObject),
        };
        const descriptor_image_info: vk.DescriptorImageInfo = .{
            .image_layout = vk.ImageLayout.general,
            .image_view = image.view,
            .sampler = .null_handle,
        };

        const descriptor_writes = [_]vk.WriteDescriptorSet{
            vk.WriteDescriptorSet{
                .dst_set = set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_type = vk.DescriptorType.uniform_buffer,
                .descriptor_count = 1,
                .p_buffer_info = &.{descriptor_buffer_info},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            vk.WriteDescriptorSet{
                .dst_set = set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_type = vk.DescriptorType.storage_image,
                .descriptor_count = 1,
                .p_buffer_info = &.{},
                .p_image_info = &.{descriptor_image_info},
                .p_texel_buffer_view = &.{},
            },
        };

        gc.dev.updateDescriptorSets(descriptor_writes.len, &descriptor_writes, 0, null);
    }

    std.log.debug("Creating command buffers", .{});
    var cmdbufs = try init_helpers.createCommandBuffers(
        &gc,
        command_pool,
        gpa,
        pipeline_layout,
        pipeline,
        swapchain.swap_images,
        storage_images,
        descriptor_sets,
        extent,
        query_pool,
    );
    defer init_helpers.destroyCommandBuffers(&gc, command_pool, gpa, cmdbufs);

    defer {
        swapchain.waitForAllFences() catch {};
        gc.dev.deviceWaitIdle() catch {};
    }

    // ------------------------- INIT -------------------------
    try stderr.print("debug: initializing...\n", .{});
    try bw_err.flush();

    const base_size_x: @Vector(2, f64) = .{ -2.0, 0.47 };
    const base_size_y: @Vector(2, f64) = .{ -1.12, 1.12 };

    var size_x: f64 = @floatFromInt(extent.width);
    var size_y: f64 = @floatFromInt(extent.height);
    var ratio: f64 = size_x / size_y;
    var x_scale: f64 = if (ratio > 1) ratio else 1;
    var y_scale: f64 = if (ratio < 1) (1.0 / ratio) else 1;
    var scaled_base_size_x: @TypeOf(base_size_x) = base_size_x * @as(@TypeOf(base_size_x), @splat(x_scale));
    var scaled_base_size_y: @TypeOf(base_size_y) = base_size_y * @as(@TypeOf(base_size_y), @splat(y_scale));
    var scaled_size_x: f64 = size_x / (scaled_base_size_x[1] - scaled_base_size_x[0]);
    var scaled_size_y: f64 = size_y / (scaled_base_size_y[1] - scaled_base_size_y[0]);

    ubo.scaled_size_x = scaled_size_x;
    ubo.size_offset_x = scaled_base_size_x[0];
    ubo.scaled_size_y = scaled_size_y;
    ubo.size_offset_y = scaled_base_size_y[0];

    for (uniform_buffers) |uniform_buffer| try buffer_helpers.updateUniformBuffer(&gc, uniform_buffer, ubo);

    try stderr.print("debug: initialization done\n", .{});
    try bw_err.flush();

    // ------------------------- MAIN LOOP -------------------------
    var extent_changed = false;
    var auto_zoom = false;
    var uniform_buffer_writes: u32 = 0;
    var last_time_ns: i128 = 0;
    var next_print_time_ns: i128 = 0;
    var rolling_average_index_frame_time: usize = 0;
    var rolling_average_buffer_frame_time_ns: @Vector(128, i128) = undefined;
    var rolling_average_index_compute_time: usize = 0;
    var rolling_average_buffer_compute_time_ns: @Vector(256, f64) = undefined;
    var last_swapchain_frame = swapchain.swap_images.len - 1;
    var last_zoom: f64 = 0;

    while (true) {
        if (swapchain.image_index != (last_swapchain_frame + 1) % swapchain.swap_images.len) {
            std.debug.print("Out of order! {} -> {}\n", .{ last_swapchain_frame, swapchain.image_index });
        }
        last_swapchain_frame = swapchain.image_index;
        while (event_queue.receive()) |event| switch (event) {
            .exit => return quit(stderr),
            .extent_changed => extent_changed = true,
            .drag => {
                var payload = payload_queue.receive().?;
                defer payload.deinit();
                const data_ptr: *Vec2 = payload.get(Vec2);

                const drag: Vec2 = data_ptr.*;
                ubo.x_offset += drag[0] / (ubo.zoom * size_x);
                ubo.y_offset += drag[1] / (ubo.zoom * size_y);

                uniform_buffer_writes = max_frames_in_flight;
            },
            .key_press => {
                var payload = payload_queue.receive().?;
                defer payload.deinit();
                const data_ptr: *u8 = payload.get(u8);
                const data = data_ptr.*;

                const zoom_speed = 1.1;
                if (data == 4) {
                    ubo.zoom *= zoom_speed;
                    uniform_buffer_writes = max_frames_in_flight;
                } else if (data == 5) {
                    ubo.zoom /= zoom_speed;
                    uniform_buffer_writes = max_frames_in_flight;
                }
            },
            .autozoom => auto_zoom = !auto_zoom,
        };

        if (auto_zoom) {
            ubo.zoom *= 1.005;
            uniform_buffer_writes = max_frames_in_flight;
        }

        if (ubo.zoom < last_zoom) {
            std.debug.print("{}: {}\n", .{ swapchain.image_index, ubo });
            last_zoom = ubo.zoom;
        }
        if (uniform_buffer_writes > 0) {
            try buffer_helpers.updateUniformBuffer(&gc, uniform_buffers[swapchain.image_index], ubo);
            //try stderr.print("\x1B[0KUniform buffer write for buffer {} ({d:.3})\n", .{ swapchain.image_index, ubo.zoom });
            if (!auto_zoom) uniform_buffer_writes -= 1;
            //if (uniform_buffer_writes == 0) std.debug.print("\n", .{});
        }

        const cmdbuf = cmdbufs[swapchain.image_index];

        const state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or extent_changed) {
            try swapchain.recreate(extent);

            size_x = @floatFromInt(extent.width);
            size_y = @floatFromInt(extent.height);
            ratio = size_x / size_y;
            x_scale = if (ratio > 1) ratio else 1;
            y_scale = if (ratio < 1) 1 / ratio else 1;
            scaled_base_size_x = base_size_x * @as(@TypeOf(base_size_x), @splat(x_scale));
            scaled_base_size_y = base_size_y * @as(@TypeOf(base_size_y), @splat(y_scale));
            scaled_size_x = size_x / (scaled_base_size_x[1] - scaled_base_size_x[0]);
            scaled_size_y = size_y / (scaled_base_size_y[1] - scaled_base_size_y[0]);
            ubo.scaled_size_x = scaled_size_x;
            ubo.size_offset_x = scaled_base_size_x[0];
            ubo.scaled_size_y = scaled_size_y;
            ubo.size_offset_y = scaled_base_size_y[0];

            for (storage_images) |*storage_image| try storage_image.recreate(&gc, extent);
            for (storage_images) |storage_image| try storage_image.transitionImageLayout(&gc, command_pool);

            for (descriptor_sets, storage_images, uniform_buffers) |set, image, uniform_buffer| {
                const descriptor_buffer_info: vk.DescriptorBufferInfo = .{
                    .buffer = uniform_buffer.buffer,
                    .offset = 0,
                    .range = @sizeOf(UniformBufferObject),
                };
                const descriptor_image_info: vk.DescriptorImageInfo = .{
                    .image_layout = vk.ImageLayout.general,
                    .image_view = image.view,
                    .sampler = .null_handle,
                };

                const descriptor_writes = [_]vk.WriteDescriptorSet{
                    vk.WriteDescriptorSet{
                        .dst_set = set,
                        .dst_binding = 0,
                        .dst_array_element = 0,
                        .descriptor_type = vk.DescriptorType.uniform_buffer,
                        .descriptor_count = 1,
                        .p_buffer_info = &.{descriptor_buffer_info},
                        .p_image_info = &.{},
                        .p_texel_buffer_view = &.{},
                    },
                    vk.WriteDescriptorSet{
                        .dst_set = set,
                        .dst_binding = 1,
                        .dst_array_element = 0,
                        .descriptor_type = vk.DescriptorType.storage_image,
                        .descriptor_count = 1,
                        .p_buffer_info = &.{},
                        .p_image_info = &.{descriptor_image_info},
                        .p_texel_buffer_view = &.{},
                    },
                };

                gc.dev.updateDescriptorSets(descriptor_writes.len, &descriptor_writes, 0, null);
            }

            for (uniform_buffers) |uniform_buffer| try buffer_helpers.updateUniformBuffer(&gc, uniform_buffer, ubo);

            for (swapchain.swap_images) |swap_image| try image_helpers.transitionImageLayout(&gc, command_pool, swap_image.image, swapchain.surface_format.format, .undefined, .present_src_khr, 1);

            init_helpers.destroyCommandBuffers(&gc, command_pool, gpa, cmdbufs);
            cmdbufs = try init_helpers.createCommandBuffers(
                &gc,
                command_pool,
                gpa,
                pipeline_layout,
                pipeline,
                swapchain.swap_images,
                storage_images,
                descriptor_sets,
                extent,
                query_pool,
            );

            extent_changed = false;
        }

        var compute_shader_time_ticks: [2]u64 = undefined;
        _ = try gc.dev.getQueryPoolResults(
            query_pool,
            0,
            2,
            @sizeOf(@TypeOf(compute_shader_time_ticks)),
            &compute_shader_time_ticks,
            @sizeOf(u64),
            .{
                .@"64_bit" = true,
                .wait_bit = true,
            },
        );
        const compute_shader_duration_ns = @as(f64, gc.props.limits.timestamp_period) * @as(f64, @floatFromInt(compute_shader_time_ticks[1])) - @as(f64, @floatFromInt(compute_shader_time_ticks[0]));

        rolling_average_buffer_compute_time_ns[rolling_average_index_compute_time] = compute_shader_duration_ns;
        rolling_average_index_compute_time = (rolling_average_index_compute_time + 1) % 256;

        const time_ns = std.time.nanoTimestamp();
        const frame_time_ns = time_ns - last_time_ns;
        rolling_average_buffer_frame_time_ns[rolling_average_index_frame_time] = frame_time_ns;
        rolling_average_index_frame_time = (rolling_average_index_frame_time + 1) % 128;

        if (next_print_time_ns <= time_ns) {
            const average_compute_time_ns = @reduce(.Add, rolling_average_buffer_compute_time_ns) / 256;
            const average_frame_time_ns = @divFloor(@reduce(.Add, rolling_average_buffer_frame_time_ns), 128);

            try stderr.print("\x1B[0K{d:.2} | {d:.2} | {d:.2} | {:.2}\x1B[0G", .{ @divFloor(std.time.ns_per_s, average_frame_time_ns), @as(f64, @floatFromInt(std.time.ns_per_s)) / average_compute_time_ns, ubo.zoom, ubo.zoom });
            next_print_time_ns = time_ns + std.time.ns_per_s / 2;
            try bw_err.flush();
        }
        last_time_ns = time_ns;
    }
}

pub const StorageImage = struct {
    memory: vk.DeviceMemory,
    image: vk.Image,
    view: vk.ImageView,
    format: vk.Format,

    fn init(gc: *const GraphicsContext, extent: vk.Extent2D, format: vk.Format) !@This() {
        var self: @This() = undefined;

        const storage_image_create_info: vk.ImageCreateInfo = .{
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
                .transfer_src_bit = true,
                .storage_bit = true,
            },
            .sharing_mode = .exclusive,
            .samples = .{ .@"1_bit" = true },
            .flags = .{},
        };
        const storage_image: vk.Image = try gc.dev.createImage(&storage_image_create_info, null);
        errdefer gc.dev.destroyImage(storage_image, null);
        self.image = storage_image;

        const storage_image_mem_reqs = gc.dev.getImageMemoryRequirements(storage_image);
        const storage_image_memory = try gc.allocate(storage_image_mem_reqs, .{ .device_local_bit = true });
        errdefer gc.dev.freeMemory(storage_image_memory, null);
        try gc.dev.bindImageMemory(storage_image, storage_image_memory, 0);
        self.memory = storage_image_memory;

        const storage_image_view = try image_helpers.createImageView(gc, storage_image, format, .{ .color_bit = true }, 1);
        errdefer gc.dev.destroyImageView(storage_image_view, null);
        self.view = storage_image_view;

        self.format = format;
        return self;
    }

    fn deinit(self: @This(), gc: *const GraphicsContext) void {
        gc.dev.destroyImageView(self.view, null);
        gc.dev.destroyImage(self.image, null);
        gc.dev.freeMemory(self.memory, null);
    }

    fn recreate(self: *@This(), gc: *const GraphicsContext, extent: vk.Extent2D) !void {
        self.deinit(gc);
        self.* = try StorageImage.init(gc, extent, self.format);
    }

    fn transitionImageLayout(self: @This(), gc: *const GraphicsContext, command_pool: vk.CommandPool) !void {
        try image_helpers.transitionImageLayout(gc, command_pool, self.image, self.format, .undefined, .general, 1);
    }
};

fn processXEvents(
    alloc: Allocator,
    connection: *const *xcb_connection_t,
    window: xcb_window_t,
    atom_wm_protocols: xcb.atom_t,
    atom_wm_delete_window: xcb.atom_t,
    extent: *vk.Extent2D,
    m_queue: *MessageQueue,
    p_queue: *PayloadQueue,
    stdout: Stderr,
) !void {
    var drag_last_pos: ?Vec2 = null;
    var drag_start: ?Vec2 = null;

    while (true) {
        var opt_event = xcb.wait_for_event(connection.*);
        while (opt_event) |event| : (opt_event = xcb.poll_for_event(connection.*)) {
            defer std.c.free(opt_event);
            switch (event.response_type.op) {
                .CLIENT_MESSAGE => blk: {
                    const client_message: *xcb.client_message_event_t = @ptrCast(event);
                    if (client_message.window != window) break :blk;

                    if (client_message.type == atom_wm_protocols) {
                        const msg_atom: xcb.atom_t = @enumFromInt(client_message.data.data32[0]);
                        if (msg_atom == atom_wm_delete_window) try m_queue.post(.exit);
                    } else if (client_message.type == .NOTICE) {
                        // We repaint every frame regardless.
                    }
                },
                .CONFIGURE_NOTIFY => {
                    const configure: *xcb.configure_notify_event_t = @ptrCast(event);
                    if (extent.width != configure.width or extent.height != configure.height) {
                        extent.width = configure.width;
                        extent.height = configure.height;
                        try m_queue.post(.extent_changed);
                    }
                },
                .EXPOSE => {
                    // We paint everything every frame, so this message is pointless.
                },
                .KEY_PRESS => {
                    const key_press: *xcb.key_press_event_t = @ptrCast(event);
                    if (key_press.detail == 9) {
                        try m_queue.post(.exit);
                        return;
                    } else if (key_press.detail == 65) try m_queue.post(.autozoom);
                },
                .KEY_RELEASE => {
                    // key up
                },
                .MOTION_NOTIFY => {
                    // mouse movement
                    const key_press: *xcb.key_press_event_t = @ptrCast(event);
                    const curr_pos = Vec2{ @floatFromInt(key_press.event_x), @floatFromInt(key_press.event_y) };

                    // Delta
                    if (drag_last_pos) |last_pos| {
                        const drag = -(curr_pos - last_pos);
                        drag_last_pos = curr_pos;

                        if (@reduce(.Or, drag == Vec2{ 0, 0 })) continue;

                        const payload = try Payload.init(alloc, drag);
                        errdefer payload.deinit();

                        try p_queue.post(payload);
                        try m_queue.post(.drag);
                    }
                },
                .BUTTON_PRESS => {
                    // mouse down
                    const key_press: *xcb.key_press_event_t = @ptrCast(event);
                    if (event.pad0 == 1) {
                        drag_start = Vec2{ @floatFromInt(key_press.event_x), @floatFromInt(key_press.event_y) };
                        drag_last_pos = Vec2{ @floatFromInt(key_press.event_x), @floatFromInt(key_press.event_y) };
                    }
                },
                .BUTTON_RELEASE => {
                    const key_press: *xcb.key_press_event_t = @ptrCast(event);
                    const payload = try Payload.init(alloc, key_press.detail);

                    try p_queue.post(payload);
                    try m_queue.post(.key_press);

                    if (event.pad0 == 1) {
                        drag_last_pos = null;
                        drag_start = null;
                    }
                },
                else => |t| {
                    try stdout.print("\x1B[0Kunhandled xcb message: {s}\n", .{@tagName(t)});
                },
            }
        }
    }
}

fn quit(stdout: Stderr) void {
    stdout.print("\x1B[0KQuitting...\n", .{}) catch |err| std.process.fatal("\x1B[0KCannot print final message.\nError: {!}\n", .{err});
    stdout.context.flush() catch |err| std.process.fatal("\x1B[0KCannot flush on quit.\nError: {!}\n", .{err});
    std.process.cleanExit();
}

const std = @import("std");
const builtin = @import("builtin");

pub const lib = @import("mandelbrot_lib");
const Swapchain = lib.Swapchain;
const GraphicsContext = lib.GraphicContext;

const xcb = lib.xcb;

const build_options = lib.build_options;
const enable_validation_layers = build_options.debug;

pub const vk = lib.vk;
pub const xcb_connection_t = xcb.connection_t;
pub const xcb_visualid_t = xcb.visualid_t;
pub const xcb_window_t = xcb.window_t;

const helpers = lib.helpers;
const xorg_helpers = helpers.xorg_helpers;
const init_helpers = helpers.init_helpers;
const image_helpers = helpers.image_helpers;
const buffer_helpers = helpers.buffer_helpers;

const ipc = lib.ipc;
const MessageQueue = ipc.MessageQueue;
const EventMessage = MessageQueue.Message;
const PayloadQueue = ipc.PayloadQueue;
const Payload = PayloadQueue.Payload;

const io = lib.io;
const Stderr = io.Stderr;
const Stdout = io.Stdout;
const Stdin = io.Stdin;

const types = lib.types;
const math_types = types.math;
const Vec2 = math_types.Vec2;
const graphics_types = types.graphics;
const UniformBuffer = graphics_types.UniformBuffer;
const UniformBufferObject = graphics_types.UniformBufferObject;

const Allocator = std.mem.Allocator;
