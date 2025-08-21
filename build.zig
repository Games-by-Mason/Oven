const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shader_compiler = b.dependency("shader_compiler", .{
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(shader_compiler.artifact("shader_compiler"));

    const zex = b.dependency("zex", .{
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zex.artifact("zex"));
}

const Extension = enum {
    @".png",
    @".comp.glsl",
    @".vf.glsl",

    const ignored: []const []const u8 = &.{
        // Skip glsl files, they're imported by the shader programs we're actually compiling.
        "glsl",
    };
};

/// Options to `bake`.
pub const BakeOptions = struct {
    dirname: []const u8,
    shader_compiler: ShaderCompilerOptions,
};

/// Bakes the assets in a given directory.
pub fn bake(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: BakeOptions,
) !*std.Build.Step.WriteFile {
    const write_file = b.addWriteFiles();

    var dir = try std.fs.cwd().openDir(options.dirname, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    w: while (try walker.next()) |entry| {
        // Only process files
        if (entry.kind != .file) continue;

        // Check the extension
        const ext = b: {
            // Get the extension
            const ext = extensions(entry.basename);

            // Break if we found one of the expected extensions
            inline for (@typeInfo(Extension).@"enum".fields) |field| {
                if (std.mem.eql(u8, ext, field.name)) {
                    break :b @field(Extension, field.name);
                }
            }

            // Skip the ZON config files
            {
                const postfix = ".zon";
                if (std.mem.endsWith(u8, ext, postfix)) {
                    const prefix = ext[0 .. ext.len - postfix.len];
                    inline for (@typeInfo(Extension).@"enum".fields) |field| {
                        if (std.mem.eql(u8, prefix, field.name)) {
                            continue :w;
                        }
                    }
                }
            }

            // Skip ignored extensions
            for (Extension.ignored) |ignored| {
                if (std.mem.endsWith(u8, entry.basename, ignored)) {
                    continue :w;
                }
            }

            // The extension is not supported, fail
            std.log.err("{s}: cannot bake unsupported extension \"{s}\"", .{
                entry.path,
                ext,
            });
            return error.UnsupportedExtension;
        };

        // Check that the path only contains valid characters. Since our output paths are based on
        // our input paths, this check is sufficient.
        try checkPath(entry.path);

        // If any path components start with an underscore, skip them. Really we should just avoid
        // traversing into directories that start with "_" to begin with, but this method saves us
        // from having to fork the walker.
        {
            var comps = try std.fs.path.componentIterator(entry.path);
            while (comps.next()) |comp| {
                if (comp.name[0] == '_') continue :w;
            }
        }

        // Find all config files to apply to this asset, sorted from lowest to highest priority
        const config_paths = c: {
            var config_paths: std.ArrayList([]const u8) = .{};

            // Check for config files matching this extension
            {
                const basename_zon = b.fmt("{t}.zon", .{ext});
                for (walker.stack.items) |frame| {
                    frame.iter.dir.access(basename_zon, .{}) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    };
                    const filename_zon = b.pathJoin(&.{
                        walker.name_buffer.items[0..frame.dirname_len],
                        basename_zon,
                    });
                    try config_paths.append(b.allocator, filename_zon);
                }
            }

            // Check if there's a config file matching this file exactly
            b: {
                const frame = walker.stack.items[walker.stack.items.len - 1];
                const basename_zon = b.fmt("{s}.zon", .{entry.basename});
                frame.iter.dir.access(basename_zon, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :b,
                    else => return err,
                };
                const filename_zon = b.pathJoin(&.{
                    walker.name_buffer.items[0..frame.dirname_len],
                    basename_zon,
                });
                try config_paths.append(b.allocator, filename_zon);
            }

            break :c config_paths;
        };

        // Bake the file
        switch (ext) {
            .@".png" => {
                // Install the texture
                _ = try installTexture(b, dep, write_file, .{
                    .dirname = options.dirname,
                    .filename = entry.path,
                    .config = config_paths,
                });
            },
            .@".comp.glsl" => {
                // Install the compute shader
                _ = try installShader(b, dep, write_file, options.shader_compiler, .{
                    .dirname = options.dirname,
                    .filename = entry.path,
                    .config = config_paths,
                    .stage = "comp",
                });
            },
            .@".vf.glsl" => {
                // Install the vertex and fragment shaders
                _ = try installShader(b, dep, write_file, options.shader_compiler, .{
                    .dirname = options.dirname,
                    .filename = entry.path,
                    .config = config_paths,
                    .stage = "vert",
                });
                _ = try installShader(b, dep, write_file, options.shader_compiler, .{
                    .filename = entry.path,
                    .config = config_paths,
                    .stage = "frag",
                    .dirname = options.dirname,
                });
            },
        }
    }

    return write_file;
}

/// Options for `compileTexture`.
pub const TextureOptions = struct {
    config: std.ArrayList([]const u8),
    dirname: []const u8,
    filename: []const u8,
};

/// Converts a texture from PNG to KTX2.
pub fn compileTexture(
    b: *std.Build,
    dep: *std.Build.Dependency,
    texture: TextureOptions,
) !std.Build.LazyPath {
    const oven = b.addRunArtifact(dep.artifact("zex"));

    for (texture.config.items) |path| {
        oven.addArg("--config");
        oven.addFileArg(b.path(b.pathJoin(&.{ texture.dirname, path })));
    }

    oven.addArg("--input");
    oven.addFileArg(b.path(b.pathJoin(&.{ texture.dirname, texture.filename })));

    oven.addArg("--output");
    const stem = stemNoExt(texture.filename);
    const basename = b.fmt("{s}.ktx2", .{stem});
    return oven.addOutputFileArg(basename);
}

/// Converts a texture from PNG to KTX2 and installs it.
pub fn installTexture(
    b: *std.Build,
    dep: *std.Build.Dependency,
    write_file: *std.Build.Step.WriteFile,
    texture: TextureOptions,
) !std.Build.LazyPath {
    const ktx2 = try compileTexture(b, dep, texture);
    const dirname = std.fs.path.dirname(texture.filename) orelse "";
    const filename_no_ext = std.fs.path.fmtJoin(&.{ dirname, stemNoExt(texture.filename) });
    const filename = b.fmt("{f}.ktx2", .{filename_no_ext});
    return write_file.addCopyFile(ktx2, filename);
}

/// Options that tend to be specific to an invocation of the shader compiler.
pub const ShaderProgramOptions = struct {
    config: std.ArrayList([]const u8),
    stage: []const u8,
    dirname: []const u8,
    filename: []const u8,
    define: std.ArrayList([]const u8) = .{},
};

/// Options that tend to be shared by all invocations of the shader compiler.
pub const ShaderCompilerOptions = struct {
    default_version: []const u8,
    target: []const u8,
    debug_info: bool,
    optimize_perf: bool,
    optimize_size: bool,
    define: std.ArrayList([]const u8),
    preamble: std.ArrayList(std.Build.LazyPath),
    include: std.ArrayList(std.Build.LazyPath),

    pub fn init(b: *std.Build, optimize: std.builtin.OptimizeMode) !@This() {
        var result: @This() = .{
            .default_version = "460",
            .target = "Vulkan-1.3",
            // We default to always including debug info for now, it's useful to have when something goes
            // wrong and I don't expect the shaders to be particularly large. I also don't mind sharing the
            // source to them etc, they're easy enough to disassemble regardless.
            .debug_info = true,
            .optimize_perf = optimize != .Debug,
            .optimize_size = optimize == .ReleaseSmall,
            .define = .empty,
            .preamble = .empty,
            .include = .empty,
        };
        switch (optimize) {
            .Debug, .ReleaseSafe => try result.define.append(
                b.allocator,
                "RUNTIME_SAFETY=1",
            ),
            .ReleaseFast, .ReleaseSmall => try result.define.append(
                b.allocator,
                "RUNTIME_SAFETY=0",
            ),
        }
        return result;
    }
};

/// Compiles a SPIRV shader.
pub fn compileShader(
    b: *std.Build,
    dep: *std.Build.Dependency,
    compiler: ShaderCompilerOptions,
    program: ShaderProgramOptions,
) !std.Build.LazyPath {
    if (program.config.items.len > 0) {
        std.log.err("{s}: shaders don't accept zon config", .{program.config.items[0]});
        return error.UnexpectedConfig;
    }

    const compile = b.addRunArtifact(dep.artifact("shader_compiler"));

    for (compiler.preamble.items) |preamble| {
        compile.addArg("--preamble");
        compile.addFileArg(preamble);
    }

    compile.addArg("--scalar-block-layout");

    compile.addArgs(&.{ "--default-version", compiler.default_version });
    compile.addArgs(&.{ "--target", compiler.target });
    compile.addArgs(&.{ "--stage", program.stage });

    if (compiler.optimize_perf) compile.addArg("--optimize-perf");
    if (compiler.optimize_size) compile.addArg("--optimize-size");
    if (compiler.debug_info) compile.addArg("--debug");

    for (compiler.include.items) |include| {
        compile.addArg("--include-path");
        compile.addDirectoryArg(include);
    }

    for (compiler.define.items) |define| {
        compile.addArgs(&.{ "--define", define });
    }
    for (program.define.items) |define| {
        compile.addArgs(&.{ "--define", define });
    }

    compile.addArg("--write-deps");
    _ = compile.addDepFileOutputArg("deps.d");

    compile.addFileArg(b.path(b.pathJoin(&.{ program.dirname, program.filename })));

    const stem = stemNoExt(program.filename);
    const basename = b.fmt("{s}.{s}.spv", .{ stem, program.stage });
    return compile.addOutputFileArg(basename);
}

/// Compiles and installs a SPIRV shader.
pub fn installShader(
    b: *std.Build,
    dep: *std.Build.Dependency,
    write_file: *std.Build.Step.WriteFile,
    compiler: ShaderCompilerOptions,
    program: ShaderProgramOptions,
) !std.Build.LazyPath {
    const spv = try compileShader(b, dep, compiler, program);
    const dirname = std.fs.path.dirname(program.filename) orelse "";
    const filename_no_ext = std.fs.path.fmtJoin(&.{ dirname, stemNoExt(program.filename) });
    const filename = b.fmt("{f}.{s}.spv", .{ filename_no_ext, program.stage });
    return write_file.addCopyFile(spv, filename);
}

/// Similar to `std.fs.path.stem`, but removes all extensions instead of just the last one.
pub fn stemNoExt(path: []const u8) []const u8 {
    const filename = std.fs.path.basename(path);
    const index = std.mem.indexOfScalar(u8, filename, '.') orelse return filename;
    return filename[0..index];
}

/// Similar to `std.fs.path.extension` but returns all extensions.
pub fn extensions(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const index = std.mem.indexOfScalar(u8, basename, '.') orelse return path[path.len..];
    return basename[index..];
}

/// Just say no to uppercase or strange characters in data paths.
///
/// You don't want to allow uppercase characters in your game's data paths. Even if you're Windows
/// only (boo!) people will try to play your game in Proton/Wine, and then if you ever try to load
/// the path with the wrong case--and you will--your game will break for those players only, and you
/// will be sad.
///
/// Then you will fix it. And for a brief moment, you'll be happy. What an easy fix!
///
/// But wait. The players say it's still broken. What gives? Eventually, you'll realize that Steam's
/// updater diffs your files before applying the patch to save bandwidth. And its diff algorithm
/// assumes that all filesystems are case insensitive. So your entire patch is a noop. Everything is
/// still broken. And you're still sad.
///
/// Now you're stuck renaming your whole "data" folder to "data-lc" to force Steam to acknowledge
/// the diff. What a terrible name. What an embarrassing name. What a stupid name. What a
/// humiliating name. Now your game works, but somehow, you're still sad.
///
/// Who the hell thought building case insensitivity into the platform at the file system level was
/// a good idea?
///
/// Just say no.
///
/// (...we also reject spaces and stuff because it makes it easier to escape dep files.)
pub fn checkPath(path: []const u8) !void {
    var lastWasSep = false;
    for (path) |char| {
        switch (char) {
            std.fs.path.sep => if (lastWasSep) {
                std.log.err("{s} contains illegal substring: \"{}{}\"", .{
                    path,
                    std.fs.path.sep,
                    std.fs.path.sep,
                });
                return error.InvalidPath;
            } else {
                lastWasSep = true;
            },
            'a'...'z', '-', '_', '0'...'9', '.' => lastWasSep = false,
            'A'...'Z' => {
                std.log.err("{s}: path contains upper case characters", .{path});
                return error.InvalidPath;
            },
            else => {
                std.log.err("{s}: path contains illegal character: '{c}'", .{ path, char });
                return error.InvalidPath;
            },
        }
    }
}
