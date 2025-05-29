const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_3,
    //vk.features.version_1_4, // The versions seemps to be separated so 1_x functions are only included in 1_x version.
    vk.extensions.khr_surface,
    vk.extensions.khr_xcb_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.ext_debug_utils,
    vk.extensions.ext_device_address_binding_report, // Required for ext_debug_utils.
};

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);

pub const CommandBuffer = vk.CommandBufferProxy(apis);

allocator: Allocator,

vkb: BaseDispatch,

instance: Instance,
surface: vk.SurfaceKHR,
pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,

dev: Device,
graphics_queue: Queue,
present_queue: Queue,

enable_validation_layers: bool,
debug_messenger: vk.DebugUtilsMessengerEXT,

const vkGetInstanceProcAddr = @extern(vk.PfnGetInstanceProcAddr, .{
    .name = "vkGetInstanceProcAddr",
    .library_name = "vulkan_zig",
});

pub fn init(allocator: Allocator, app_name: [*:0]const u8, connection: *vk.xcb_connection_t, window: vk.xcb_window_t, enable_validation_layers: bool) !@This() {
    var self: GraphicsContext = undefined;
    self.allocator = allocator;
    self.enable_validation_layers = enable_validation_layers;
    self.vkb = try BaseDispatch.load(vkGetInstanceProcAddr);

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = app_name,
        .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
        .p_engine_name = app_name,
        .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
        .api_version = @bitCast(vk.API_VERSION_1_4),
    };

    var extension_names_buffer: [4][*:0]const u8 = undefined;
    var extension_names: std.ArrayListUnmanaged([*:0]const u8) = .{
        .items = extension_names_buffer[0..0],
        .capacity = extension_names_buffer.len,
    };

    extension_names.appendAssumeCapacity("VK_KHR_surface");
    extension_names.appendAssumeCapacity("VK_KHR_xcb_surface");
    //extension_names.appendAssumeCapacity("VK_KHR_synchronization_2");
    if (enable_validation_layers or true)
        extension_names.appendAssumeCapacity("VK_EXT_debug_utils");

    const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    const enabled_layers: []const [*:0]const u8 = if (enable_validation_layers) &validation_layers else &.{};

    const validation_features = vk.ValidationFeaturesEXT{
        .enabled_validation_feature_count = 1,
        .p_enabled_validation_features = &.{vk.ValidationFeatureEnableEXT.debug_printf_ext},
    };

    const instance_info: vk.InstanceCreateInfo = .{
        .s_type = vk.StructureType.instance_create_info,
        .p_application_info = &app_info,

        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = extension_names.items.ptr,

        .enabled_layer_count = @intCast(enabled_layers.len),
        .pp_enabled_layer_names = enabled_layers.ptr,
        .p_next = &validation_features,
    };
    const instance_handle = try self.vkb.createInstance(&instance_info, null);

    const vki = try allocator.create(InstanceDispatch);
    errdefer allocator.destroy(vki);
    vki.* = try InstanceDispatch.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr);
    self.instance = Instance.init(instance_handle, vki);
    errdefer self.instance.destroyInstance(null);

    if (enable_validation_layers) {
        //std.debug.print("Running\n", .{});
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
            .message_severity = .{
                .error_bit_ext = true,
                .warning_bit_ext = true,
            },
            .message_type = .{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
                //.device_address_binding_bit_ext = true,
            },
            .pfn_user_callback = debugCallback,
        }, null);
    }

    self.surface = try createSurface(self.instance, connection, window);
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    const candidate = try pickPhysicalDevice(self.instance, allocator, self.surface);
    self.pdev = candidate.pdev;
    self.props = candidate.props;

    const dev = try initializeCandidate(self.instance, candidate);

    const vkd = try allocator.create(DeviceDispatch);
    errdefer allocator.destroy(vkd);
    vkd.* = try DeviceDispatch.load(dev, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
    self.dev = Device.init(dev, vkd);
    errdefer self.dev.destroyDevice(null);

    self.graphics_queue = Queue.init(self.dev, candidate.queues.graphics_family);
    self.present_queue = Queue.init(self.dev, candidate.queues.present_family);

    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

    return self;
}

pub fn deinit(self: GraphicsContext) void {
    self.dev.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    if (self.enable_validation_layers) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);

    // Don't forget to free the tables to prevent a memory leak.
    self.allocator.destroy(self.dev.wrapper);
    self.allocator.destroy(self.instance.wrapper);
}

pub fn deviceName(self: *const GraphicsContext) []const u8 {
    return std.mem.sliceTo(&self.props.device_name, 0);
}

pub fn findMemoryTypeIndex(self: GraphicsContext, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
        if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

pub fn allocate(self: GraphicsContext, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    return try self.dev.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
    }, null);
}

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

fn createSurface(instance: Instance, connection: *vk.xcb_connection_t, window: vk.xcb_window_t) !vk.SurfaceKHR {
    var surface_create_info: vk.XcbSurfaceCreateInfoKHR = .{
        .connection = connection,
        .window = window,
    };
    return instance.createXcbSurfaceKHR(&surface_create_info, null);
}

fn initializeCandidate(instance: Instance, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1
    else
        2;

    const device_sync_features: vk.PhysicalDeviceSynchronization2Features = .{ .synchronization_2 = vk.TRUE };

    return try instance.createDevice(candidate.pdev, &.{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .p_enabled_features = &.{ .sampler_anisotropy = vk.TRUE },
        .p_next = &device_sync_features,
    }, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

fn pickPhysicalDevice(
    instance: Instance,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(instance, pdev, allocator, surface)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(pdev);
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}

pub fn getMaxSampling(self: @This()) vk.SampleCountFlags {
    if (!build_options.msaa_enabled) return .{ .@"1_bit" = true };
    const limits = self.props.limits;
    var flags: std.StaticBitSet(32) = @bitCast(limits.framebuffer_color_sample_counts);
    {
        const depth: std.StaticBitSet(32) = @bitCast(limits.framebuffer_depth_sample_counts);
        flags.setIntersection(depth);
    }

    const first_common_bit: u32 = @as(u32, @intCast(1)) << @intCast(flags.findLastSet().?);
    return @bitCast(std.StaticBitSet(32){ .mask = first_common_bit });
}

pub fn findSupportedFormat(self: @This(), candidates: []const vk.Format, tiling: vk.ImageTiling, required_features: vk.FormatFeatureFlags) !vk.Format {
    for (candidates) |format| {
        const format_props = self.instance.getPhysicalDeviceFormatProperties(self.pdev, format);

        var available_features: std.StaticBitSet(32) = @bitCast(switch (tiling) {
            .linear => format_props.linear_tiling_features,
            .optimal => format_props.optimal_tiling_features,
            else => return error.UnsupporedFormat,
        });

        available_features.setIntersection(@bitCast(required_features));
        if (available_features.eql(@bitCast(required_features))) return format;
    }

    return error.NoFormatFound;
}

pub fn findDepthFormat(self: @This()) !vk.Format {
    return try self.findSupportedFormat(
        &.{ .d32_sfloat, .d32_sfloat_s8_uint, .d24_unorm_s8_uint },
        .optimal,
        .{ .depth_stencil_attachment_bit = true },
    );
}

pub fn hasStancilComponent(format: vk.Format) bool {
    return format == .d32_sfloat_s8_uint or format == .d24_unorm_s8_uint;
}

pub fn listLimits(self: @This()) void {
    const limits = self.props.limits;
    const fields = @typeInfo(@TypeOf(limits)).@"struct".fields;

    std.debug.print("Limits:\n", .{});
    inline for (fields) |limit| {
        const name = limit.name;
        const value = @field(limits, name);
        std.debug.print("  {}\t{s}: {any}\n", .{ @TypeOf(value), name, value });
    }
}

pub fn listFormatProps(self: @This()) void {
    const props = self.instance.getPhysicalDeviceFormatProperties(self.pdev, vk.Format.d32_sfloat);
    const fields = @typeInfo(@TypeOf(props)).@"struct".fields;

    std.debug.print("Format props:\n", .{});
    inline for (fields) |limit| {
        const name = limit.name;
        const value = @field(props, name);
        std.debug.print("  {}\t{s}: {any}\n", .{ @TypeOf(value), name, value });
    }
}

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_severity;
    _ = message_types;
    _ = p_user_data;
    b: {
        const msg = (p_callback_data orelse break :b).p_message orelse break :b;
        std.log.scoped(.validation).warn("{s}", .{msg});
        return vk.FALSE;
    }
    std.log.scoped(.validation).warn("unrecognized validation layer debug message", .{});
    return vk.FALSE;
}

const std = @import("std");

const build_options = @import("build_options");

const root = @import("root");
const lib = root.lib;
const xcb = lib.xcb;
const vk = lib.vk;

const GraphicsContext = @This();

const Allocator = std.mem.Allocator;
const Stderr = lib.io.Stdout;
