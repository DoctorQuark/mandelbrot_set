pub const UniformBuffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
};

pub const UniformBufferObject = struct {
    zoom: f64,
    x_offset: f64,
    y_offset: f64,
    scaled_size_x: f64,
    size_offset_x: f64,
    scaled_size_y: f64,
    size_offset_y: f64,
};

const root = @import("root");
const lib = root.lib;
const vk = lib.vk;
