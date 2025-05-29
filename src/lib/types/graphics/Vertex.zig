pos: Vec3,
color: Vec3,
tex_coords: Vec2,

pub const binding_description = vk.VertexInputBindingDescription{
    .binding = 0,
    .stride = @sizeOf(Vertex),
    .input_rate = .vertex,
};
pub const attribute_description = [_]vk.VertexInputAttributeDescription{ .{
    .binding = 0,
    .location = 0,
    .format = .r32g32b32_sfloat,
    .offset = @offsetOf(Vertex, "pos"),
}, .{
    .binding = 0,
    .location = 1,
    .format = .r32g32b32_sfloat,
    .offset = @offsetOf(Vertex, "color"),
}, .{
    .binding = 0,
    .location = 2,
    .format = .r32g32_sfloat,
    .offset = @offsetOf(Vertex, "tex_coords"),
} };

const Vertex = @This();

const root = @import("root");
const lib = root.lib;

const vk = lib.vk;

const types = lib.types;
const Vec2 = types.math.Vec2;
const Vec3 = types.math.Vec3;
