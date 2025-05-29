const VectorDimension = u8;

pub fn Vector(T: type, comptime size: VectorDimension) type {
    //return [size]t;
    return @Vector(size, T);
}

pub const Vec2 = Vector(f64, 2);
pub const Vec3 = Vector(f32, 3);
pub const Vec4 = Vector(f32, 4);
