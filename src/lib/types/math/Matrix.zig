const MatrixDimension = u8;

//pub fn Matrix(t: type, comptime size: [2]MatrixDimension) type {
//    return [size[0] * size[1]]t;
//}

//pub fn SquareMatrix(t: type, comptime size: MatrixDimension) type {
//    return Matrix(t, .{ size, size });
//}

pub fn Matrix(T: type, comptime size: MatrixDimension) type {
    //return [size * size]t;
    return @Vector(size * size, T);
}

pub const Mat4 = Matrix(f32, 4);

pub fn identityMatrix(T: type) T {
    const type_info = @typeInfo(T);

    const is_valid_type = type_info != .array or type_info != .vector;
    if (!is_valid_type) {
        @compileError("identityMatrix must be called with an array or vector type.");
    }

    const child_info = if (type_info == .vector) type_info.vector else type_info.array;
    if (@typeInfo(child_info.child) != .float) @compileLog("Matrix elements needs to be type float");

    const N2 = child_info.len; // Total elements in the array
    const N = switch (N2) {
        4 => 2,
        9 => 3,
        16 => 4,
        else => @compileError("Wrong matrix size."),
    };

    var mat: T = std.mem.zeroes(T);
    for (0..N) |i| {
        mat[i * N + i] = 1.0;
    }
    return mat;
}

const std = @import("std");
