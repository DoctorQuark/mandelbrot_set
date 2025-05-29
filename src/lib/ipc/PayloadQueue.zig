queue: std.ArrayList(Payload),
mutex: std.Thread.Mutex,

pub fn init(allocator: Allocator, capacity: u32) !@This() {
    const queue = try std.ArrayList(Payload).initCapacity(allocator, capacity);
    const mutex = std.Thread.Mutex{};
    return @This(){ .queue = queue, .mutex = mutex };
}

pub fn deinit(self: @This()) void {
    for (self.queue.items) |item| item.deinit();
    self.queue.deinit();
}

pub fn post(self: *@This(), message: Payload) !void {
    self.lock();
    defer self.unlock();
    try self.queue.append(message);
}

pub fn receive(self: *@This()) ?Payload {
    if (self.queue.items.len == 0) return null;
    self.lock();
    defer self.unlock();
    return self.queue.pop();
}

pub fn lock(self: *@This()) void {
    self.mutex.lock();
}

pub fn unlock(self: *@This()) void {
    self.mutex.unlock();
}

const PayloadType = enum {
    pub fn get(T: type) @This() {
        return switch (T) {
            i8 => .Int8,
            i16 => .Int16,
            i32 => .Int32,
            i64 => .Int64,
            u8 => .Uint8,
            u16 => .Uint16,
            u32 => .Uint32,
            u64 => .Uint64,
            f32 => .Float32,
            f64 => .Float64,
            Vec2 => .Vec2,
            Vec3 => .Vec3,
            Vec4 => .Vec4,
            Mat4 => .Mat4,
            else => @compileError("Unsupported type"),
        };
    }

    pub fn resolve(val: @This()) type {
        return switch (val) {
            .Int8 => i8,
            .Int16 => i16,
            .Int32 => i32,
            .Int64 => i64,
            .Uint8 => u8,
            .Uint16 => u16,
            .Uint32 => u32,
            .Uint64 => u64,
            .Float32 => f32,
            .Float64 => f64,
            .Vec2 => Vec2,
            .Vec3 => Vec3,
            .Vec4 => Vec4,
            .Mat4 => Mat4,
            else => @compileError("Unsupported type"),
        };
    }

    Int8,
    Int16,
    Int32,
    Int64,
    Uint8,
    Uint16,
    Uint32,
    Uint64,
    Float32,
    Float64,
    Vec2,
    Vec3,
    Vec4,
    Mat4,
};

pub const TypeInfo = struct {
    bits: u16,
    arr_size: u16,
    num: enum { int, uint, float },
};

pub const Payload = struct {
    allocator: Allocator,
    data_ptr: *anyopaque,
    //data_type: PayloadType,
    destroy_fn: *const fn (Allocator, *anyopaque) void,

    pub fn init(alloc: Allocator, payload: anytype) !Payload {
        const T = @TypeOf(payload);
        const data = try alloc.create(T);
        data.* = payload;

        return @This(){
            .allocator = alloc,
            .data_ptr = data,
            //.data_type = PayloadType.get(T),
            .destroy_fn = destroyImpl(T),
        };
    }

    pub fn deinit(self: @This()) void {
        self.destroy_fn(self.allocator, self.data_ptr);
    }

    pub fn get(self: *Payload, comptime T: type) *T {
        return @as(*T, @alignCast(@ptrCast(self.data_ptr)));
    }

    fn destroyImpl(comptime T: type) *const fn (Allocator, *anyopaque) void {
        return struct {
            fn destroy(alloc: Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*T, @alignCast(@ptrCast(ptr))));
            }
        }.destroy;
    }
};

const root = @import("root");
const lib = root.lib;

const types = lib.types;
const math_types = types.math;
const Vec2 = math_types.Vec2;
const Vec3 = math_types.Vec3;
const Vec4 = math_types.Vec4;
const Mat4 = math_types.Mat4;

const std = @import("std");
const Allocator = std.mem.Allocator;
