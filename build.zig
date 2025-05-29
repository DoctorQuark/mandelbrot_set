const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const debug_enabled = b.option(bool, "ebug", "Enabled debug functionality") orelse (optimize == .Debug);

    const options = b.addOptions();
    options.addOption(bool, "debug", debug_enabled);

    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = registry,
    }).module("vulkan-zig");

    const shader_compiler = b.dependency("shader_compiler", .{
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseFast,
    }).artifact("shader_compiler");

    // ----- Shaders -----
    const shaders_mod = b.createModule(.{
        .root_source_file = b.path("src/shaders.zig"),
    });
    shaders_mod.addAnonymousImport("shaders.mandelbrot.comp", .{
        .root_source_file = compileShader(b, optimize, shader_compiler, b.path("shaders/mandelbrot.comp"), "mandelbrot.comp.spv"),
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_mod.addOptions("build_options", options);
    lib_mod.addImport("shaders", shaders_mod);
    lib_mod.addImport("vulkan", vulkan);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("mandelbrot_lib", lib_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mandelbrot",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "mandelbrot",
        .root_module = exe_mod,
    });

    exe.linkLibC();
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("vulkan");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn compileShader(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    shader_compiler: *std.Build.Step.Compile,
    src: std.Build.LazyPath,
    out_basename: []const u8,
) std.Build.LazyPath {
    const compile_shader = b.addRunArtifact(shader_compiler);
    compile_shader.addArgs(&.{
        "--target", "Vulkan-1.3",
    });
    switch (optimize) {
        .Debug => compile_shader.addArgs(&.{
            "--robust-access",
        }),
        .ReleaseSafe => compile_shader.addArgs(&.{
            "--optimize-perf",
            "--robust-access",
        }),
        .ReleaseFast => compile_shader.addArgs(&.{
            "--optimize-perf",
        }),
        .ReleaseSmall => compile_shader.addArgs(&.{
            "--optimize-perf",
            "--optimize-small",
        }),
    }
    compile_shader.addFileArg(src);
    return compile_shader.addOutputFileArg(out_basename);
}
